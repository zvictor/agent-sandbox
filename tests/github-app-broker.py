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


class TokenRouterTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.minted = {}

        def request(issuer, path, bearer, data=None):
            self.requests.append((path, bearer, data))
            if path == "/app/installations/123":
                return {"id": 123, "account": {"login": "personal"}}
            if path == "/app/installations/456":
                return {"id": 456, "account": {"login": "org"}}
            if path.endswith("/access_tokens"):
                installation = path.split("/")[3]
                self.minted[installation] = self.minted.get(installation, 0) + 1
                expiry = dt.datetime.fromtimestamp(time.time() + 3600, dt.timezone.utc).isoformat()
                return {"token": f"token-{installation}-{self.minted[installation]}", "expires_at": expiry}
            raise AssertionError("unexpected API request: " + path)

        patcher = mock.patch.object(broker.TokenIssuer, "request_json", new=request)
        patcher.start()
        self.addCleanup(patcher.stop)
        jwt = mock.patch.object(broker, "app_jwt", return_value="signed-jwt")
        jwt.start()
        self.addCleanup(jwt.stop)

    def test_routes_and_refreshes_each_installation_independently(self):
        router = broker.TokenRouter("42", ["123", "456"], "/host/key.pem")
        self.assertEqual(router.get_token("personal/project"), "token-123-1")
        self.assertEqual(router.get_token("org/project"), "token-456-1")
        self.assertEqual(router.get_token("PERSONAL/another-project"), "token-123-1")
        router.issuers["123"].expires_at = time.time() + 30
        self.assertEqual(router.get_token("org/project"), "token-456-1")
        self.assertEqual(router.get_token("personal/project"), "token-123-2")
        self.assertEqual(self.minted, {"123": 2, "456": 1})

    def test_denies_ambiguous_and_unconfigured_repository_context(self):
        router = broker.TokenRouter("42", ["123", "456"], "/host/key.pem")
        with self.assertRaises(broker.RepositoryContextError):
            router.get_token()
        with self.assertRaises(broker.RepositoryAccessError):
            router.get_token("unconfigured/project")
        for repository in ("project", "org/project/extra", "org/project\n"):
            with self.subTest(repository=repository), self.assertRaises(broker.RepositoryContextError):
                router.get_token(repository)
        self.assertEqual(self.minted, {})

    def test_scopes_repository_names_to_each_installation_owner(self):
        router = broker.TokenRouter("42", ["123", "456"], "/host/key.pem", ["personal/one", "org/two"])
        router.get_token("personal/one")
        router.get_token("org/two")
        payloads = {path: data for path, _, data in self.requests if data is not None}
        self.assertEqual(payloads, {
            "/app/installations/123/access_tokens": {"repositories": ["one"]},
            "/app/installations/456/access_tokens": {"repositories": ["two"]},
        })
        with self.assertRaises(broker.RepositoryAccessError):
            router.get_token("org/one")
        with self.assertRaises(ValueError):
            broker.TokenRouter("42", ["123", "456"], "/host/key.pem", ["one"])

    def test_single_installation_accepts_unscoped_requests_and_bare_names(self):
        router = broker.TokenRouter("42", ["123"], "/host/key.pem", ["project"])
        self.assertEqual(router.get_token(), "token-123-1")
        self.assertEqual(router.get_token("personal/project"), "token-123-1")
        self.assertEqual(self.requests[-1][2], {"repositories": ["project"]})
        with self.assertRaises(broker.RepositoryAccessError):
            router.get_token("org/project")

    def test_rejects_incomplete_scope_instead_of_broadening_access(self):
        router = broker.TokenRouter("42", ["123", "456"], "/host/key.pem", ["personal/one"])
        with self.assertRaises(ValueError):
            router.get_token("personal/one")
        self.assertEqual(self.minted, {})

    def test_installation_id_configuration(self):
        self.assertEqual(broker.parse_installation_ids("123,456"), ["123", "456"])
        self.assertEqual(broker.parse_installation_ids("123"), ["123"])
        for value in ("", "0", "123,123", "123,0123", ",123", "123,", "123,,456", "123, 456", "123,no"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                broker.parse_installation_ids(value)

    def test_broker_fingerprint_changes_when_access_configuration_changes(self):
        original = broker.configuration_fingerprint("42", ["123"], "/host/key.pem", ["one"])
        self.assertEqual(original, broker.configuration_fingerprint("42", ["123"], "/host/key.pem", ["one"]))
        for app, ids, key, repos in (
            ("43", ["123"], "/host/key.pem", ["one"]),
            ("42", ["123", "456"], "/host/key.pem", ["one"]),
            ("42", ["123"], "/host/another-key.pem", ["one"]),
            ("42", ["123"], "/host/key.pem", ["two"]),
        ):
            self.assertNotEqual(original, broker.configuration_fingerprint(app, ids, key, repos))

    @unittest.skipUnless(Path("/bin/curl").exists() and shutil.which("git"), "curl and git are required")
    def test_generated_git_and_gh_helpers_route_through_the_real_socket(self):
        router = broker.TokenRouter("42", ["123", "456"], "/host/key.pem")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            socket_path = str(path / "token.sock")
            handler = type("TestHandler", (broker.TokenHandler,), {"issuer": router})
            server = broker.Broker(socket_path, handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                subprocess.run([
                    "bash", "-ec",
                    'source "$1/bin/lib/github_app.sh"; AGENT_BIN_DIR="$1/bin"; '
                    'PATH_GUARD_HOST_DIR="$2"; GITHUB_APP_AUTH_MODE=app; prepare_github_app_commands',
                    "fixture", str(ROOT), str(path),
                ], check=True)
                helper = path / "github-app-token"
                helper.write_text(helper.read_text().replace("/run/agent-github-app/token.sock", socket_path))
                env = dict(os.environ, GIT_CONFIG_COUNT="3",
                           GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="",
                           GIT_CONFIG_KEY_1="credential.helper",
                           GIT_CONFIG_VALUE_1="!" + str(path / "github-app-git-credential"),
                           GIT_CONFIG_KEY_2="credential.https://github.com.useHttpPath", GIT_CONFIG_VALUE_2="true")
                for repository, token in (("personal/project", "token-123-1"), ("org/project", "token-456-1")):
                    result = subprocess.run(
                        ["git", "credential", "fill"], input=f"url=https://github.com/{repository}.git\n\n",
                        text=True, capture_output=True, check=True, env=env,
                    )
                    self.assertIn("password=" + token, result.stdout)
                fake_gh = path / "real-gh"
                fake_gh.write_text('#!/bin/sh\nprintf "%s\\n" "$GH_TOKEN"\n')
                fake_gh.chmod(0o755)
                gh = path / "gh"
                gh.write_text(gh.read_text().replace("/bin/gh", str(fake_gh)).replace(
                    "GH_CONFIG_DIR=/cache/agent-github-app/gh", "GH_CONFIG_DIR=" + str(path / "gh-config")
                ))
                for owner, token in (("personal", "token-123-1"), ("org", "token-456-1")):
                    result = subprocess.run([str(gh), "pr", "view", "--repo", owner + "/project"],
                                            text=True, capture_output=True, check=True)
                    self.assertEqual(result.stdout.strip(), token)
                result = subprocess.run([str(helper)], text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("repository context", result.stdout)
                self.assertEqual(self.minted, {"123": 1, "456": 1})
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=3)


class BrokerSocketTests(unittest.TestCase):
    def check_socket(self, issuer, cases):
        with tempfile.TemporaryDirectory() as d:
            socket_path = str(Path(d) / "token.sock")
            handler = type("TestHandler", (broker.TokenHandler,), {"issuer": issuer})
            server = broker.Broker(socket_path, handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                for path, status, expected in cases:
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
                        self.assertIn(b" " + str(status).encode() + b" ", response.split(b"\r\n")[0])
                        self.assertIn(expected, response)
                        self.assertIn(b"Cache-Control: no-store", response)
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=3)

    def test_unix_socket_exposes_token_and_only_documented_routes(self):
        class FakeIssuer:
            def get_token(self, repository=None):
                return "short-lived-test-token"

        self.check_socket(FakeIssuer(), [
            ("/health", 200, b"ok"),
            ("/token", 200, b"short-lived-test-token"),
            ("/unknown", 404, b"not found"),
        ])

    def test_socket_routes_repository_context_and_reports_selection_errors(self):
        class FakeRouter:
            def get_token(self, repository=None):
                if repository is None:
                    raise broker.RepositoryContextError("repository context required")
                if repository in ("personal/project", "org/project"):
                    return "token-for-" + repository
                raise broker.RepositoryAccessError("repository denied")

        self.check_socket(FakeRouter(), [
            ("/token?repository=personal%2Fproject", 200, b"token-for-personal/project"),
            ("/token?repository=org%2Fproject", 200, b"token-for-org/project"),
            ("/token", 400, b"repository context required"),
            ("/token?repository=unconfigured%2Fproject", 403, b"repository denied"),
            ("/token?repository=", 400, b"single repository"),
            ("/token?repository=org/a&repository=org/b", 400, b"single repository"),
            ("/token?key=secret", 400, b"single repository"),
        ])


if __name__ == "__main__":
    unittest.main()
