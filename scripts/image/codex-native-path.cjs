// Match the installed npm launcher's Linux platform-package layout. Older
// Codex packages carry vendor/ themselves rather than an optional dependency.
const { createRequire } = require('node:module');
const { dirname, join, resolve } = require('node:path');
const { realpathSync } = require('node:fs');
const packageJson = realpathSync(resolve(process.argv[2]));
const packageRequire = createRequire(packageJson);
const targets = {
  x64: ['codex-linux-x64', 'x86_64-unknown-linux-musl'],
  arm64: ['codex-linux-arm64', 'aarch64-unknown-linux-musl'],
};
const target = targets[process.arch];
if (process.platform !== 'linux' || !target) throw new Error('Unsupported Codex image platform');
let packageRoot;
try {
  packageRoot = dirname(packageRequire.resolve(`@openai/${target[0]}/package.json`));
} catch (error) {
  if (error.code !== 'MODULE_NOT_FOUND') throw error;
  packageRoot = dirname(packageJson);
}
console.log(join(packageRoot, 'vendor', target[1], 'bin', 'codex'));
