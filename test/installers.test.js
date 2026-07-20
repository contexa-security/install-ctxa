const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.join(__dirname, '..');
const ps1Path = path.join(root, 'install.ps1');
const shPath = path.join(root, 'install.sh');
const vercelPath = path.join(root, 'vercel.json');
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

test('install.ps1 enforces the signed, bounded and atomic installation contract', () => {
  const src = read(ps1Path);
  assert.ok(src.startsWith('#Requires -Version 5.1'));
  assert.equal(src.includes('E:\\projects'), false);
  assert.equal(src.includes('localBuildPath'), false);
  assert.equal(src.includes('docker'), false, 'installer must not block on Docker');
  assertNoReplacementOrBoxDrawing(src);
  assert.match(src, /HttpWebRequest/);
  assert.match(src, /CONTEXA_HTTP_CONNECT_TIMEOUT_SEC/);
  assert.match(src, /CONTEXA_HTTP_TOTAL_TIMEOUT_SEC/);
  assert.match(src, /CONTEXA_HTTP_RETRIES/);
  assert.match(src, /release-manifest\.json\.sig/);
  assert.match(src, /snapshot-channel\/channel-manifest\.json/);
  assert.match(src, /CONTEXA_CHANNEL_SIGNATURE_URL/);
  assert.match(src, /Signed release manifest does not match the signed channel and starter version/);
  assert.equal(src.includes('releases/latest'), false);
  assert.equal(src.includes('CONTEXA_RELEASE_API_URL'), false);
  assert.match(src, /VerifyData/);
  assert.match(src, /Get-Sha256FileHex \$temporaryPath/);
  assert.match(src, /\.new\.exe/);
  assert.match(src, /\[System\.IO\.File\]::Move\(\$temporaryPath, \$finalPath\)/);
  assert.match(src, /\.previous/);
  assert.match(src, /CONTEXA_INSTALL_ACTION/);
  assert.match(src, /CONTEXA_TRUSTED_PUBLIC_KEY_XML/);
  assert.match(src, /IsLoopback/);
  assert.match(src, /Test-BinarySmoke \$temporaryPath/);
  assert.match(src, /Ensure-CommandPath/);
  assert.match(src, /was not deleted/);
  for (const command of ['contexa init', 'contexa reset', 'contexa init --simulate', 'contexa reset --simulate']) {
    assert.ok(src.includes(command), `missing primary command: ${command}`);
  }
});

test('install.sh enforces supported platforms, bounded download and atomic replacement', () => {
  const src = read(shPath);
  assert.ok(src.startsWith('#!/bin/sh'));
  assertNoReplacementOrBoxDrawing(src);
  assert.equal(/^\s*local\s+/m.test(src), false, 'POSIX sh script must not use bash-only local declarations');
  assert.equal(src.includes('docker'), false, 'installer must not block on Docker');
  assert.match(src, /--connect-timeout "\$CONNECT_TIMEOUT"/);
  assert.match(src, /--max-time "\$download_remaining"/);
  assert.match(src, /download_attempt/);
  assert.match(src, /HTTP_429_RATE_LIMIT/);
  assert.match(src, /CONNECTION_RESET/);
  assert.match(src, /release-manifest\.json\.sig/);
  assert.match(src, /snapshot-channel\/channel-manifest\.json/);
  assert.match(src, /CONTEXA_CHANNEL_SIGNATURE_URL/);
  assert.match(src, /Signed release manifest starter version mismatch/);
  assert.equal(src.includes('releases/latest'), false);
  assert.equal(src.includes('CONTEXA_RELEASE_API_URL'), false);
  assert.match(src, /openssl dgst -sha256 -verify/);
  assert.match(src, /Linux ARM64 is not supported/);
  assert.match(src, /Intel Mac is not supported/);
  assert.match(src, /glibc 2\.28 or newer/);
  assert.match(src, /\.contexa\.new\.XXXXXX/);
  assert.match(src, /BACKUP_PATH="\$INSTALL_PATH\.previous"/);
  assert.match(src, /CONTEXA_INSTALL_ACTION/);
  assert.match(src, /CONTEXA_TRUSTED_PUBLIC_KEY_PATH/);
  assert.match(src, /loopback release server/);
  assert.match(src, /smoke_binary "\$NEW_BINARY"/);
  assert.match(src, /MANIFEST_CODE_SIGNATURE/);
  assert.match(src, /was not deleted/);
  for (const command of ['contexa init', 'contexa reset', 'contexa init --simulate', 'contexa reset --simulate']) {
    assert.ok(src.includes(command), `missing primary command: ${command}`);
  }
});

test('installer files are written without UTF-8 BOM', () => {
  assert.notDeepEqual([...firstBytes(ps1Path, 3)], [0xef, 0xbb, 0xbf]);
  assert.notDeepEqual([...firstBytes(shPath, 3)], [0xef, 0xbb, 0xbf]);
});

test('Vercel static-path headers match the dynamic endpoint contract', () => {
  const config = JSON.parse(read(vercelPath));
  const stableRef = '23721bb0e7b561a7deb356656a7e2e3a879bc086';
  assert.equal(config.env.CONTEXA_STABLE_INSTALLER_REF, stableRef);
  for (const route of ['/install.ps1', '/install.sh']) {
    const redirect = config.redirects.find(candidate => candidate.source === route);
    assert.ok(redirect, `missing stable-channel redirect for ${route}`);
    assert.equal(redirect.destination, `https://raw.githubusercontent.com/contexa-security/install-ctxa/${stableRef}${route}`);
    assert.equal(redirect.permanent, false);
    const entry = config.headers.find(candidate => candidate.source === route);
    assert.ok(entry, `missing Vercel header contract for ${route}`);
    const headers = Object.fromEntries(entry.headers.map(header => [header.key.toLowerCase(), header.value]));
    assert.equal(headers['content-type'], 'text/plain; charset=utf-8');
    assert.equal(headers['cache-control'], 'no-store');
    assert.equal(headers['x-content-type-options'], 'nosniff');
  }
});

test('api prioritizes explicit paths and exposes immutable version URLs', () => {
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

  const sh = invoke('/install.sh?source=powershell', 'WindowsPowerShell/5.1');
  assert.ok(sh.body.startsWith('#!/bin/sh'));
  assert.equal(sh.headers['cache-control'], 'no-store');

  const immutable = invoke('/v9.9.9-installer-test/install.ps1');
  assert.equal(immutable.statusCode, 302);
  assert.equal(immutable.headers.location, 'https://raw.githubusercontent.com/contexa-security/install-ctxa/v9.9.9-installer-test/install.ps1');
  assert.equal(immutable.headers['cache-control'], 'public, max-age=31536000, immutable');
  const caseSensitiveTag = invoke('/v9.9.9-Installer-Test/install.sh');
  assert.equal(caseSensitiveTag.headers.location, 'https://raw.githubusercontent.com/contexa-security/install-ctxa/v9.9.9-Installer-Test/install.sh');

  const originalStableRef = process.env.CONTEXA_STABLE_INSTALLER_REF;
  try {
    process.env.CONTEXA_STABLE_INSTALLER_REF = '23721bb0e7b561a7deb356656a7e2e3a879bc086';
    const stable = invoke('/', 'WindowsPowerShell/5.1');
    assert.equal(stable.statusCode, 302);
    assert.equal(stable.headers.location, 'https://raw.githubusercontent.com/contexa-security/install-ctxa/23721bb0e7b561a7deb356656a7e2e3a879bc086/install.ps1');
    assert.equal(stable.headers['cache-control'], 'no-store');
  } finally {
    if (originalStableRef === undefined) delete process.env.CONTEXA_STABLE_INSTALLER_REF;
    else process.env.CONTEXA_STABLE_INSTALLER_REF = originalStableRef;
  }

  const originalReadFileSync = fs.readFileSync;
  let unavailable;
  try {
    fs.readFileSync = () => { throw new Error('injected read failure'); };
    unavailable = invoke('/install.sh');
  } finally {
    fs.readFileSync = originalReadFileSync;
  }
  assert.equal(unavailable.statusCode, 503);
  assert.equal(unavailable.headers['cache-control'], 'no-store');
  assert.match(unavailable.body, /temporarily unavailable/);
});

test('install.sh passes sh -n when sh is available', () => {
  const shell = process.platform === 'win32' ? 'C:\\Program Files\\Git\\bin\\sh.exe' : 'sh';
  const result = spawnSync(shell, ['-n', shPath], { encoding: 'utf8' });
  if (result.error && result.error.code === 'ENOENT') {
    return;
  }
  assert.equal(result.status, 0, result.stderr || result.stdout);
});

test('Korean installer validation failures expose stable code without raw English fallback', () => {
  const environment = {
    ...process.env,
    CONTEXA_LANG: 'ko',
    CONTEXA_HTTP_CONNECT_TIMEOUT_SEC: 'bad',
  };
  const shell = process.platform === 'win32' ? 'C:\\Program Files\\Git\\bin\\sh.exe' : 'sh';
  const sh = spawnSync(shell, [shPath], { encoding: 'utf8', env: environment });
  if (!(sh.error && sh.error.code === 'ENOENT')) {
    const output = `${sh.stdout}\n${sh.stderr}`;
    assert.equal(sh.status, 1, output);
    assert.match(output, /INSTALLER_OPERATION_FAILED/);
    assert.doesNotMatch(output, /must be an integer/);
    assert.equal(output.includes('\uFFFD'), false);
  }

  if (process.platform === 'win32') {
    const ps = spawnSync('powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1Path],
      { encoding: 'utf8', env: environment });
    const output = `${ps.stdout}\n${ps.stderr}`;
    assert.equal(ps.status, 1, output);
    assert.match(output, /INSTALLER_OPERATION_FAILED/);
    assert.doesNotMatch(output, /must be an integer/);
    assert.equal(output.includes('\uFFFD'), false);
  }
});

test('CLI release bundle satisfies the installer signature and asset contract', {
  skip: !process.env.CONTEXA_RELEASE_BUNDLE_ROOT,
}, () => {
  const bundleRoot = path.resolve(process.env.CONTEXA_RELEASE_BUNDLE_ROOT);
  const manifestPath = path.join(bundleRoot, 'release-manifest.json');
  const signaturePath = path.join(bundleRoot, 'release-manifest.json.sig');
  const channelPath = path.join(bundleRoot, 'channel-manifest.json');
  const channelSignaturePath = path.join(bundleRoot, 'channel-manifest.json.sig');
  const publicKeyPath = path.join(bundleRoot, 'release-signing-public.pem');
  for (const file of [manifestPath, signaturePath, channelPath, channelSignaturePath, publicKeyPath]) {
    assert.equal(fs.existsSync(file), true, `release contract file is missing: ${file}`);
  }

  const publicKey = fs.readFileSync(publicKeyPath);
  const manifestBytes = fs.readFileSync(manifestPath);
  const manifestSignature = Buffer.from(read(signaturePath).trim(), 'base64');
  assert.equal(crypto.verify('sha256', manifestBytes, publicKey, manifestSignature), true,
    'release manifest signature must verify with the installer trust key');
  const manifest = JSON.parse(manifestBytes);
  assert.equal(manifest.source.repository, 'contexa-security/contexa-cli');
  assert.match(manifest.source.commit, /^[0-9a-f]{40}$/);

  for (const asset of manifest.assets) {
    const binaryPath = path.join(bundleRoot, 'dist', asset.file, asset.file);
    const sidecarPath = `${binaryPath}.sha256`;
    assert.equal(fs.existsSync(binaryPath), true, `release asset is missing: ${asset.file}`);
    assert.equal(fs.existsSync(sidecarPath), true, `release sidecar is missing: ${asset.checksumFile}`);
    const actual = crypto.createHash('sha256').update(fs.readFileSync(binaryPath)).digest('hex');
    const sidecar = read(sidecarPath).trim().split(/\s+/)[0].toLowerCase();
    assert.equal(actual, asset.sha256, `manifest digest mismatch: ${asset.file}`);
    assert.equal(sidecar, asset.sha256, `sidecar digest mismatch: ${asset.file}`);
  }

  const channelBytes = fs.readFileSync(channelPath);
  const channelSignature = Buffer.from(read(channelSignaturePath).trim(), 'base64');
  assert.equal(crypto.verify('sha256', channelBytes, publicKey, channelSignature), true,
    'channel manifest signature must verify with the installer trust key');
  const channel = JSON.parse(channelBytes);
  assert.equal(channel.channel, manifest.channel);
  assert.equal(channel.releaseTag, manifest.releaseTag);
  assert.equal(channel.cliVersion, manifest.cliVersion);
  assert.equal(channel.starterVersion, manifest.starter.version);
  assert.equal(channel.sourceCommit, manifest.source.commit);
  assert.equal(channel.releaseManifestSha256,
    crypto.createHash('sha256').update(manifestBytes).digest('hex'));
});
