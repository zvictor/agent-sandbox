#!/usr/bin/env python3
"""Offline tests for the host-side GitHub App token broker."""
import base64
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
BROKER = ROOT / "bin" / "agent-github-app-broker"
loader = importlib.machinery.SourceFileLoader("github_app_broker", str(BROKER))
spec = importlib.util.spec_from_loader(loader.name, loader)
broker = importlib.util.module_from_spec(spec)
loader.exec_module(broker)


def fake_api_response(token, expires):
    payload = json.dumps({"token": token, "expires_at": expires}).encode()
    return io.BytesIO(payload)


class TokenIssuerTests(unittest.TestCase):
    def test_discovers_identity_from_authenticated_app_and_bot_user(self):
        expiry = dt.datetime.fromtimestamp(time.time() + 3600, dt.timezone.utc).isoformat()
        responses = [
            io.BytesIO(b'{"id":42,"slug":"example"}'),
            fake_api_response("installation-token", expiry),
            io.BytesIO(b'{"id":98765,"login":"example[bot]","type":"Bot"}'),
        ]
        with mock.patch.object(broker, "app_jwt", return_value="signed-jwt"), \
             mock.patch.object(broker.urllib.request, "urlopen", side_effect=responses) as opened:
            issuer = broker.TokenIssuer("42", "123", "/host/key.pem", ["example-repo"])
            self.assertEqual(issuer.get_identity(), (
                "example[bot]", "98765+example[bot]@users.noreply.github.com"
            ))
            requests = [call.args[0] for call in opened.call_args_list]
            self.assertEqual([request.full_url for request in requests], [
                "https://api.github.com/app",
                "https://api.github.com/app/installations/123/access_tokens",
                "https://api.github.com/users/example%5Bbot%5D",
            ])
            self.assertEqual(requests[0].get_method(), "GET")
            self.assertEqual(requests[0].get_header("Authorization"), "Bearer signed-jwt")
            self.assertEqual(requests[2].get_header("Authorization"), "Bearer installation-token")
            self.assertEqual(json.loads(requests[1].data), {"repositories": ["example-repo"]})

    def test_identity_discovery_rejects_invalid_app_slugs(self):
        for slug in (None, "", "wrong/path", "example\nother"):
            with self.subTest(slug=slug), \
                 mock.patch.object(broker, "app_jwt", return_value="jwt"):
                issuer = broker.TokenIssuer("42", "123", "/host/key.pem")
                with mock.patch.object(issuer, "request_json", return_value={"slug": slug}):
                    with self.assertRaises(ValueError):
                        issuer.get_identity()

    def test_identity_discovery_rejects_invalid_bot_users(self):
        valid = {"id": 98765, "login": "example[bot]", "type": "Bot"}
        invalid = [dict(valid, id=value) for value in (0, -1, True, "98765", None)]
        invalid += [dict(valid, login="another[bot]"), dict(valid, type="User")]
        for user in invalid:
            with self.subTest(user=user), \
                 mock.patch.object(broker, "app_jwt", return_value="jwt"):
                issuer = broker.TokenIssuer("42", "123", "/host/key.pem")
                with mock.patch.object(issuer, "request_json", side_effect=[{"slug": "example"}, user]), \
                     mock.patch.object(issuer, "get_token", return_value="installation-token"):
                    with self.assertRaises(ValueError):
                        issuer.get_identity()

    def test_identity_discovery_propagates_network_failure(self):
        with mock.patch.object(broker, "app_jwt", return_value="jwt"), \
             mock.patch.object(broker.urllib.request, "urlopen", side_effect=broker.urllib.error.URLError("offline")):
            with self.assertRaises(broker.urllib.error.URLError):
                broker.TokenIssuer("42", "123", "/host/key.pem").get_identity()

    def test_installation_token_cache_and_refresh(self):
        now = time.time()
        expiry = dt.datetime.fromtimestamp(now + 3600, dt.timezone.utc).isoformat()
        responses = [fake_api_response("first", expiry), fake_api_response("second", expiry)]
        with mock.patch.object(broker, "app_jwt", return_value="signed-jwt"), \
             mock.patch.object(broker.urllib.request, "urlopen", side_effect=responses) as opened, \
             mock.patch.object(broker.time, "time", return_value=now):
            issuer = broker.TokenIssuer("42", "123", "/host/key.pem", ["example-repo"])
            self.assertEqual(issuer.get_token(), "first")
            self.assertEqual(issuer.get_token(), "first")
            self.assertEqual(opened.call_count, 1)
            request = opened.call_args.args[0]
            self.assertEqual(request.get_method(), "POST")
            self.assertEqual(request.get_header("Authorization"), "Bearer signed-jwt")
            self.assertEqual(json.loads(request.data), {"repositories": ["example-repo"]})
            issuer.expires_at = now + 100
            self.assertEqual(issuer.get_token(), "second")
            self.assertEqual(opened.call_count, 2)

    def test_refuses_expired_or_empty_token(self):
        now = time.time()
        expiry = dt.datetime.fromtimestamp(now + 5, dt.timezone.utc).isoformat()
        for token in ("", "bad"):
            with self.subTest(token=token), \
                 mock.patch.object(broker, "app_jwt", return_value="jwt"), \
                 mock.patch.object(broker.urllib.request, "urlopen",
                                   return_value=fake_api_response(token, expiry)):
                with self.assertRaises(ValueError):
                    broker.TokenIssuer("42", "123", "/host/key.pem").get_token()

    @unittest.skipUnless(shutil.which("openssl"), "openssl is required")
    def test_signed_jwt_contains_short_lived_app_claims(self):
        with tempfile.TemporaryDirectory() as d:
            key = Path(d) / "key.pem"
            pub = Path(d) / "pub.pem"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
                 "-out", str(key)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True,
            )
            subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(pub)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            jwt = broker.app_jwt("987", key, now=2000000000)
            header, claims, sig = jwt.split(".")
            decoded = json.loads(base64.urlsafe_b64decode(claims + "==="))
            self.assertEqual(decoded, {"iat": 1999999940, "exp": 2000000540, "iss": "987"})
            self.assertEqual(json.loads(base64.urlsafe_b64decode(header + "==="))["alg"], "RS256")
            signed = (header + "." + claims).encode()
            with tempfile.TemporaryDirectory() as verify_dir:
                data = Path(verify_dir) / "message"
                signature = Path(verify_dir) / "signature"
                data.write_bytes(signed)
                signature.write_bytes(base64.urlsafe_b64decode(sig + "==="))
                subprocess.run(
                    ["openssl", "dgst", "-sha256", "-verify", str(pub),
                     "-signature", str(signature), str(data)],
                    stdout=subprocess.DEVNULL, check=True,
                )


class BrokerSocketTests(unittest.TestCase):
    def test_unix_socket_exposes_token_and_only_documented_routes(self):
        class FakeIssuer:
            def get_token(self):
                return "short-lived-test-token"

        with tempfile.TemporaryDirectory() as d:
            socket_path = str(Path(d) / "token.sock")
            handler = type("TestHandler", (broker.TokenHandler,), {"issuer": FakeIssuer()})
            server = broker.Broker(socket_path, handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                for path, expected in (("/health", b"ok"), ("/token", b"short-lived-test-token"),
                                       ("/unknown", b"not found")):
                    with self.subTest(path=path), socket.socket(socket.AF_UNIX) as conn:
                        conn.connect(socket_path)
                        conn.sendall(("GET " + path + " HTTP/1.1\r\nHost: localhost\r\n\r\n").encode())
                        chunks = []
                        while True:
                            chunk = conn.recv(8192)
                            if not chunk:
                                break
                            chunks.append(chunk)
                        response = b"".join(chunks)
                        self.assertIn(expected, response)
                        self.assertIn(b"Cache-Control: no-store", response)
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
