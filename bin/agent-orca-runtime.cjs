#!/usr/bin/env node
'use strict';

// Publish only Orca's bootstrap metadata and relay its native Unix socket.
// This helper never interprets RPC messages or executes host commands.
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const SOCKET_ENDPOINT = '/run/agent-orca/runtime.sock';

function privateEntry(file, kind, privateMode = false) {
  const stat = fs.lstatSync(file);
  if (kind === 'directory' && fs.realpathSync(file) !== file) {
    throw new Error(`Orca directory must use its canonical path: ${file}`);
  }
  const correctKind = kind === 'directory' ? stat.isDirectory() : kind === 'socket' ? stat.isSocket() : stat.isFile();
  if (!correctKind || stat.uid !== process.getuid() || (stat.mode & (privateMode ? 0o077 : 0o022))) {
    throw new Error(`Orca ${kind} must be owned by the current user with safe permissions: ${file}`);
  }
  return stat;
}

function readSource(profile) {
  privateEntry(profile, 'directory');
  const metadataPath = path.join(profile, 'orca-runtime.json');
  privateEntry(metadataPath, 'file', true);
  let metadata;
  try { metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8')); }
  catch { throw new Error('Cannot read valid Orca runtime metadata'); }
  if (!metadata || typeof metadata.runtimeId !== 'string' || !metadata.runtimeId ||
      typeof metadata.authToken !== 'string' || !metadata.authToken ||
      !Number.isSafeInteger(metadata.pid) || metadata.pid <= 0) {
    throw new Error('Orca runtime metadata is incomplete');
  }
  const transports = Array.isArray(metadata.transports) ? metadata.transports : [metadata.transport];
  const transport = transports.find(item => item && item.kind === 'unix');
  if (!transport || typeof transport.endpoint !== 'string' || !path.isAbsolute(transport.endpoint)) {
    throw new Error('Orca runtime metadata has no absolute Unix socket endpoint');
  }
  const parent = path.dirname(transport.endpoint);
  const uid = process.getuid();
  if (parent !== profile && !parent.startsWith(`/tmp/.orca-daemon-${uid}/`)) {
    throw new Error('Orca socket must be in its profile or its private relocated runtime directory');
  }
  privateEntry(parent, 'directory', parent !== profile);
  if (parent !== profile) privateEntry(`/tmp/.orca-daemon-${uid}`, 'directory', true);
  privateEntry(transport.endpoint, 'socket', true);
  return { metadata, endpoint: transport.endpoint, endpoint_dir: parent };
}

function atomicWrite(file, data) {
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`;
  try {
    fs.writeFileSync(temporary, data, { mode: 0o600, flag: 'wx' });
    fs.renameSync(temporary, file);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

function serve(profile, projection) {
  privateEntry(projection, 'directory', true);
  const socketPath = path.join(projection, 'runtime.sock');
  const metadataPath = path.join(projection, 'orca-runtime.json');
  const readyPath = path.join(projection, 'ready');
  for (const file of [socketPath, metadataPath, readyPath]) {
    if (fs.existsSync(file)) throw new Error(`Orca projection must be fresh: ${projection}`);
  }
  let cached = null;
  let published = null;
  let stopping = false;
  const connections = new Set();
  const destroyConnections = () => {
    for (const socket of connections) socket.destroy();
    connections.clear();
  };
  const refresh = () => {
    try {
      const next = readSource(profile);
      const projected = { ...next.metadata, transports: [{ kind: 'unix', endpoint: SOCKET_ENDPOINT }] };
      delete projected.transport;
      const serialized = `${JSON.stringify(projected)}\n`;
      if (serialized !== published) {
        // Drop sessions attached to an old runtime before exposing its replacement.
        destroyConnections();
        atomicWrite(metadataPath, serialized);
        published = serialized;
      }
      cached = next;
    } catch {
      cached = null;
      published = null;
      fs.rmSync(metadataPath, { force: true });
      destroyConnections();
    }
  };
  const server = net.createServer(client => {
    // Revalidate on every connection, not just at the polling interval.
    refresh();
    if (!cached || stopping) return client.destroy();
    const upstream = net.createConnection(cached.endpoint);
    connections.add(client);
    connections.add(upstream);
    for (const [socket, other] of [[client, upstream], [upstream, client]]) {
      socket.on('error', () => other.destroy());
      socket.on('close', () => { connections.delete(socket); other.destroy(); });
    }
    client.pipe(upstream);
    upstream.pipe(client);
  });
  let timer;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    clearInterval(timer);
    destroyConnections();
    for (const file of [metadataPath, readyPath]) fs.rmSync(file, { force: true });
    server.close(() => {
      fs.rmSync(socketPath, { force: true });
      process.exitCode ??= 0;
    });
  };
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
  server.on('error', () => {
    process.stderr.write('Orca native socket relay failed\n');
    process.exitCode = 1;
    stop();
  });
  server.listen(socketPath, () => {
    fs.chmodSync(socketPath, 0o600);
    refresh();
    atomicWrite(readyPath, 'ready\n');
    timer = setInterval(refresh, 200);
  });
}

function main(argv) {
  const [command, profileArg, projectionArg] = argv;
  if ((command !== 'inspect' && command !== 'serve') || !profileArg ||
      (command === 'serve' ? !projectionArg || argv.length !== 3 : argv.length !== 2)) {
    throw new Error('usage: agent-orca-runtime.cjs inspect <host-profile> | serve <host-profile> <projection-dir>');
  }
  const profile = path.resolve(profileArg);
  if (command === 'inspect') {
    const source = readSource(profile);
    process.stdout.write(`${JSON.stringify({ runtimeId: source.metadata.runtimeId, pid: source.metadata.pid,
      endpoint: source.endpoint, endpoint_dir: source.endpoint_dir })}\n`);
  } else serve(profile, path.resolve(projectionArg));
}

if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}
module.exports = { readSource, serve, SOCKET_ENDPOINT };
