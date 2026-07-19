const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.join(__dirname, '..');
const ps1Path = path.join(root, 'install.ps1');
const shPath = path.join(root, 'install.sh');
const api = require('../api/index');

function read(file) {
  return fs.readFileSync(file, 'utf8');
}

function firstBytes(file, count) {
  return fs.readFileSync(file).subarray(0, count);
}

function assertNoReplacementOrBoxDrawing(src) {
  assert.equal(src.includes('\ufffd'), false, 'source must not contain replacement characters');
  assert.equal(/[┌┐└┘─│]/u.test(src), false, 'installer output must stay ASCII-safe');
}

test('install.ps1 is ASCII-safe and has no unverified local fallback', () => {
  const src = read(ps1Path);
  assert.ok(src.startsWith('#Requires -Version 5.1'));
  assert.equal(src.includes('E:\\projects'), false);
  assert.equal(src.includes('localBuildPath'), false);
  assert.equal(src.includes('Skipping checksum verification for local fallback'), false);
  assertNoReplacementOrBoxDrawing(src);
  assert.match(src, /Invoke-WebRequest -Uri \$shaUrl/);
  assert.match(src, /Get-FileHash -Path \$tempBin -Algorithm SHA256/);
  assert.match(src, /Release tag\/binary version mismatch/);
  assert.match(src, /NewGuid\(\).*'\.exe'/);
  assert.match(src, /& \$tempBin --version/);
  assert.match(src, /& \$FinalPath --help/);
  for (const command of ['contexa init', 'contexa reset', 'contexa init --simulate', 'contexa reset --simulate']) {
    assert.ok(src.includes(command), `missing primary command: ${command}`);
  }
});

test('install.sh is POSIX-oriented and avoids corrupted banner bytes', () => {
  const src = read(shPath);
  assert.ok(src.startsWith('#!/bin/sh'));
  assert.equal(src.includes("H='?"), false);
  assertNoReplacementOrBoxDrawing(src);
  assert.equal(/^\s*local\s+/m.test(src), false, 'POSIX sh script must not use bash-only local declarations');
  assert.match(src, /CONTEXA_INSTALL_DIR/);
  assert.match(src, /HOME\/.local\/bin/);
  assert.match(src, /checksum mismatch/);
  assert.match(src, /release tag\/binary version mismatch/);
  assert.match(src, /"\$TMP_BIN" --version/);
  assert.match(src, /"\$INSTALL_PATH" --help/);
  for (const command of ['contexa init', 'contexa reset', 'contexa init --simulate', 'contexa reset --simulate']) {
    assert.ok(src.includes(command), `missing primary command: ${command}`);
  }
});

test('installer files are written without UTF-8 BOM', () => {
  assert.notDeepEqual([...firstBytes(ps1Path, 3)], [0xef, 0xbb, 0xbf]);
  assert.notDeepEqual([...firstBytes(shPath, 3)], [0xef, 0xbb, 0xbf]);
});

test('api routes PowerShell clients to install.ps1 and defaults to install.sh', () => {
  function invoke(url, ua = '') {
    const headers = {};
    const res = {
      statusCode: 200,
      headers,
      setHeader(k, v) { headers[k.toLowerCase()] = v; },
      send(body) { this.body = body; },
    };
    api({ url, headers: { 'user-agent': ua } }, res);
    return res;
  }

  const ps = invoke('/install.ps1');
  assert.equal(ps.statusCode, 200);
  assert.ok(ps.body.startsWith('#Requires -Version 5.1'));
  assert.equal(ps.headers['content-type'], 'text/plain; charset=utf-8');
  assert.equal(ps.headers['x-content-type-options'], 'nosniff');

  const uaPs = invoke('/', 'WindowsPowerShell/5.1');
  assert.ok(uaPs.body.startsWith('#Requires -Version 5.1'));

  const sh = invoke('/');
  assert.ok(sh.body.startsWith('#!/bin/sh'));
});

test('install.sh passes sh -n when sh is available', () => {
  const result = spawnSync('sh', ['-n', shPath], { encoding: 'utf8' });
  if (result.error && result.error.code === 'ENOENT') {
    return;
  }
  assert.equal(result.status, 0, result.stderr || result.stdout);
});
