#!/usr/bin/env node
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const helper = path.resolve(__dirname, '../bin/agent-orca-runtime.cjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'orca-runtime-test-'));
const profile = path.join(root, 'profile');
const projection = path.join(root, 'projection');
fs.mkdirSync(profile, { mode: 0o700 });
fs.mkdirSync(projection, { mode: 0o700 });
const endpoint = path.join(profile, 'runtime.sock');
const metadataPath = path.join(profile, 'orca-runtime.json');
const publishedPath = path.join(projection, 'orca-runtime.json');
let child;
const server = net.createServer(socket => socket.pipe(socket));
const sockets = new Set();
server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
function writeMetadata(runtimeId, token) {
  const temporary = `${metadataPath}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify({ runtimeId, pid: process.pid, authToken: token,
    startedAt: Date.now(), transports: [{ kind: 'unix', endpoint }] }), { mode: 0o600 });
  fs.renameSync(temporary, metadataPath);
}
async function until(check) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (check()) return;
    await delay(25);
  }
  throw new Error('Timed out waiting for Orca relay state');
}
async function exchange(text) {
  const socket = net.createConnection(path.join(projection, 'runtime.sock'));
  socket.on('error', () => {});
  await once(socket, 'connect');
  const received = once(socket, 'data');
  socket.write(text);
  const [data] = await received;
  socket.destroy();
  assert.equal(data.toString(), text);
}
(async () => {
  try {
    server.listen(endpoint);
    await once(server, 'listening');
    fs.chmodSync(endpoint, 0o600);
    writeMetadata('runtime-first', 'secret-first');
    const inspected = spawnSync(process.execPath, [helper, 'inspect', profile], { encoding: 'utf8' });
    assert.equal(inspected.status, 0, inspected.stderr);
    assert.equal(JSON.parse(inspected.stdout).endpoint, endpoint);
    assert(!inspected.stdout.includes('secret-first'));
    let stderr = '';
    child = spawn(process.execPath, [helper, 'serve', profile, projection], { stdio: ['ignore', 'ignore', 'pipe'] });
    child.stderr.on('data', data => { stderr += data; });
    await until(() => fs.existsSync(path.join(projection, 'ready')) && fs.existsSync(publishedPath));
    let published = JSON.parse(fs.readFileSync(publishedPath));
    assert.equal(published.transports[0].endpoint, '/run/agent-orca/runtime.sock');
    assert.equal(published.authToken, 'secret-first');
    assert.equal(fs.statSync(publishedPath).mode & 0o777, 0o600);
    assert.equal(fs.statSync(path.join(projection, 'runtime.sock')).mode & 0o777, 0o600);
    await Promise.all([exchange('alpha\nwith spaces'), exchange('beta')]);
    writeMetadata('runtime-second', 'secret-second');
    await until(() => JSON.parse(fs.readFileSync(publishedPath)).runtimeId === 'runtime-second');
    await exchange('after metadata rotation');
    const active = net.createConnection(path.join(projection, 'runtime.sock'));
    active.on('error', () => {});
    await once(active, 'connect');
    const revoked = once(active, 'close');
    fs.unlinkSync(metadataPath);
    await until(() => !fs.existsSync(publishedPath));
    await revoked;
    writeMetadata('runtime-recovered', 'secret-third');
    await until(() => fs.existsSync(publishedPath));
    await exchange('after reconnect');
    fs.chmodSync(metadataPath, 0o644);
    await until(() => !fs.existsSync(publishedPath));
    fs.chmodSync(metadataPath, 0o600);
    await until(() => fs.existsSync(publishedPath));
    // Invalid JSON diagnostics must never include source snippets or tokens.
    fs.writeFileSync(metadataPath, '{"authToken":"never-log-this",bad');
    await until(() => !fs.existsSync(publishedPath));
    const invalid = spawnSync(process.execPath, [helper, 'inspect', profile], { encoding: 'utf8' });
    assert.equal(invalid.status, 1);
    assert(!invalid.stderr.includes('never-log-this'));
    assert(!stderr.includes('secret-'));
    const exited = once(child, 'exit');
    child.kill('SIGTERM');
    const [code] = await exited;
    assert.equal(code, 0, stderr);
    assert(!fs.existsSync(publishedPath));
    assert(!fs.existsSync(path.join(projection, 'ready')));
    assert(!fs.existsSync(path.join(projection, 'runtime.sock')));
    console.log('[pass] Orca metadata isolation, native socket relay, rotation, recovery and cleanup');
  } finally {
    if (child && child.exitCode === null) child.kill('SIGKILL');
    for (const socket of sockets) socket.destroy();
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
