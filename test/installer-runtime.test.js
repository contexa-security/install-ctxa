const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const ps1 = path.join(root, 'install.ps1');
const sh = path.join(root, 'install.sh');
const powershell = process.platform === 'win32' ? 'powershell.exe' : null;
const pwsh = process.platform === 'win32' ? 'pwsh.exe' : null;
const pwshAvailable = !!pwsh && !spawnSync(pwsh, ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'],
  { windowsHide: true }).error;
const gitSh = process.platform === 'win32' ? 'C:\\Program Files\\Git\\bin\\sh.exe' : 'sh';

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function base64UrlBytes(value) {
  return Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function publicKeyXml(publicKey) {
  const jwk = publicKey.export({ format: 'jwk' });
  return `<RSAKeyValue><Modulus>${base64UrlBytes(jwk.n).toString('base64')}</Modulus><Exponent>${base64UrlBytes(jwk.e).toString('base64')}</Exponent></RSAKeyValue>`;
}

function createRelease(keys, version, platform, assetBytes, options = {}) {
  const file = platform === 'windows' ? 'contexa-win-x64.exe' : 'contexa-linux-x64';
  const digest = options.manifestDigest || sha256(assetBytes);
  const asset = {
    os: platform,
    arch: 'x64',
    file,
    checksumFile: `${file}.sha256`,
    sha256: digest,
    codeSignature: 'unsigned-snapshot',
  };
  const manifest = Buffer.from(`${JSON.stringify({
    channel: options.releaseChannel || 'snapshot',
    releaseTag: options.releaseTag || `v${version}`,
    cliVersion: options.releaseCliVersion || version,
    starter: {
      groupId: 'ai.ctxa',
      artifactId: 'spring-boot-starter-contexa',
      version: options.releaseStarterVersion || '0.1.0-SNAPSHOT',
    },
    assets: [asset],
    signature: {
      required: true,
      algorithm: 'RSA-3072-SHA256',
      file: 'release-manifest.json.sig',
      publicKeyFile: 'release-signing-public.pem',
    },
  }, null, 2)}\n`);
  const signer = options.signingKey || keys.privateKey;
  const signature = crypto.sign('sha256', manifest, signer).toString('base64');
  const prefix = `/downloads/v${version}/`;
  return new Map([
    [`${prefix}release-manifest.json`, manifest],
    [`${prefix}release-manifest.json.sig`, Buffer.from(`${options.signature || signature}\n`)],
    [`${prefix}${file}`, assetBytes],
    [`${prefix}${file}.sha256`, Buffer.from(`${options.sidecarDigest || digest}  ${file}\n`)],
  ]);
}

function createChannel(keys, version, options = {}) {
  const manifest = Buffer.from(`${JSON.stringify({
    schemaVersion: 1,
    channel: options.channel || 'snapshot',
    releaseTag: options.releaseTag || `v${version}`,
    cliVersion: options.cliVersion || version,
    starterVersion: options.starterVersion || '0.1.0-SNAPSHOT',
    releaseManifestSha256: options.releaseManifestSha256 || '0'.repeat(64),
  }, null, 2)}\n`);
  const signer = options.signingKey || keys.privateKey;
  const signature = crypto.sign('sha256', manifest, signer).toString('base64');
  return new Map([
    ['/channel/channel-manifest.json', manifest],
    ['/channel/channel-manifest.json.sig', Buffer.from(`${signature}\n`)],
  ]);
}

function createChannelForRelease(keys, version, releaseFiles, options = {}) {
  const releaseManifest = releaseFiles.get(`/downloads/v${version}/release-manifest.json`);
  assert.ok(releaseManifest, 'release manifest fixture is required before creating a channel');
  return createChannel(keys, version, {
    ...options,
    releaseManifestSha256: sha256(releaseManifest),
  });
}

async function withServer(handler, body) {
  const sockets = new Set();
  const server = http.createServer(handler);
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return await body(base);
  } finally {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
  }
}

function releaseHandler(files) {
  return (req, res) => {
    const value = files.get(new URL(req.url, 'http://localhost').pathname);
    if (!value) {
      res.statusCode = 404;
      res.end('not found');
      return;
    }
    res.statusCode = 200;
    res.setHeader('Content-Length', value.length);
    res.end(value);
  };
}

function run(command, args, env, timeout = 10000) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: { ...process.env, ...env },
      windowsHide: true,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`process timed out: ${command} ${args.join(' ')}`));
    }, timeout);
    child.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once('exit', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

function buildWindowsCli(target, version) {
  const source = `using System; public static class Program { public static int Main(string[] args) { if (args.Length > 0 && args[0] == "--version") Console.WriteLine("${version}"); else if (args.Length > 0 && args[0] == "--help") Console.WriteLine("contexa init | reset [--simulate]"); return 0; } }`;
  const encoded = Buffer.from(source, 'utf16le').toString('base64');
  const escaped = target.replace(/'/g, "''");
  const script = `$source=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('${encoded}')); Add-Type -TypeDefinition $source -OutputAssembly '${escaped}' -OutputType ConsoleApplication`;
  const result = spawnSync(powershell, ['-NoProfile', '-NonInteractive', '-Command', script], { encoding: 'utf8', windowsHide: true });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return fs.readFileSync(target);
}

function windowsInstallerEnv(base, installDir, version, keyXml, action = 'install') {
  return {
    CONTEXA_VERSION: `v${version}`,
    CONTEXA_RELEASE_DOWNLOAD_BASE: `${base}/downloads`,
    CONTEXA_TRUSTED_PUBLIC_KEY_XML: keyXml,
    CONTEXA_INSTALL_DIR: installDir,
    CONTEXA_INSTALL_ACTION: action,
    CONTEXA_SKIP_PATH_UPDATE: '1',
    CONTEXA_HTTP_CONNECT_TIMEOUT_SEC: '1',
    CONTEXA_HTTP_TOTAL_TIMEOUT_SEC: '2',
    CONTEXA_HTTP_RETRIES: '1',
  };
}

function windowsChannelInstallerEnv(base, installDir, keyXml) {
  return {
    ...windowsInstallerEnv(base, installDir, 'unused', keyXml),
    CONTEXA_VERSION: '',
    CONTEXA_CHANNEL_MANIFEST_URL: `${base}/channel/channel-manifest.json`,
    CONTEXA_CHANNEL_SIGNATURE_URL: `${base}/channel/channel-manifest.json.sig`,
  };
}

function runWindowsInstaller(env) {
  return run(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1], env);
}

function runPwshInstaller(env) {
  return run(pwsh, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1], env);
}

test('PowerShell installer performs install, no-op, update, rollback and uninstall', { skip: process.platform !== 'win32', timeout: 30000 }, async (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-lifecycle-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const installDir = path.join(temp, 'bin');
  const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const xml = publicKeyXml(keys.publicKey);
  const v1Path = path.join(temp, 'v1.exe');
  const v2Path = path.join(temp, 'v2.exe');
  const v1 = buildWindowsCli(v1Path, '9.9.1-test');
  const v2 = buildWindowsCli(v2Path, '9.9.2-test');
  const files = new Map([
    ...createRelease(keys, '9.9.1-test', 'windows', v1),
    ...createRelease(keys, '9.9.2-test', 'windows', v2),
  ]);

  await withServer(releaseHandler(files), async (base) => {
    const first = await runWindowsInstaller(windowsInstallerEnv(base, installDir, '9.9.1-test', xml));
    assert.equal(first.code, 0, first.stderr || first.stdout);
    const installed = path.join(installDir, 'contexa.exe');
    assert.equal(spawnSync(installed, ['--version'], { encoding: 'utf8' }).stdout.trim(), '9.9.1-test');
    const originalTime = fs.statSync(installed).mtimeMs;

    const same = await runWindowsInstaller(windowsInstallerEnv(base, installDir, '9.9.1-test', xml));
    assert.equal(same.code, 0, same.stderr || same.stdout);
    assert.equal(fs.statSync(installed).mtimeMs, originalTime, 'same-version install must not replace the binary');
    assert.equal(fs.existsSync(`${installed}.previous`), false);

    const update = await runWindowsInstaller(windowsInstallerEnv(base, installDir, '9.9.2-test', xml));
    assert.equal(update.code, 0, update.stderr || update.stdout);
    assert.equal(spawnSync(installed, ['--version'], { encoding: 'utf8' }).stdout.trim(), '9.9.2-test');
    assert.equal(spawnSync(`${installed}.previous`, ['--version'], { encoding: 'utf8' }).stdout.trim(), '9.9.1-test');

    const rollback = await runWindowsInstaller(windowsInstallerEnv(base, installDir, '9.9.2-test', xml, 'rollback'));
    assert.equal(rollback.code, 0, rollback.stderr || rollback.stdout);
    assert.equal(spawnSync(installed, ['--version'], { encoding: 'utf8' }).stdout.trim(), '9.9.1-test');

    const uninstall = await runWindowsInstaller(windowsInstallerEnv(base, installDir, '9.9.1-test', xml, 'uninstall'));
    assert.equal(uninstall.code, 0, uninstall.stderr || uninstall.stdout);
    assert.equal(fs.existsSync(installed), false);
    assert.equal(fs.existsSync(`${installed}.previous`), false);
  });
});

test('PowerShell installer returns failure and preserves the existing binary for 404, timeout, signature and checksum faults', { skip: process.platform !== 'win32', timeout: 30000 }, async (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-failures-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const wrongKeys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const xml = publicKeyXml(keys.publicKey);
  const existingBytes = buildWindowsCli(path.join(temp, 'existing.exe'), '8.0.0-old');
  const candidateBytes = buildWindowsCli(path.join(temp, 'candidate.exe'), '9.9.3-test');

  async function assertPreserved(handler, files, label) {
    const installDir = path.join(temp, label);
    fs.mkdirSync(installDir);
    const installed = path.join(installDir, 'contexa.exe');
    fs.writeFileSync(installed, existingBytes);
    const before = sha256(fs.readFileSync(installed));
    await withServer(handler || releaseHandler(files), async (base) => {
      const result = await runWindowsInstaller(windowsInstallerEnv(base, installDir, '9.9.3-test', xml));
      assert.notEqual(result.code, 0, `${label} must return a non-zero exit code`);
    });
    assert.equal(sha256(fs.readFileSync(installed)), before, `${label} must preserve the installed binary`);
  }

  await assertPreserved((req, res) => { res.statusCode = 404; res.end('not found'); }, null, 'not-found');
  await assertPreserved(() => {}, null, 'timeout');
  await assertPreserved(null, createRelease(keys, '9.9.3-test', 'windows', candidateBytes, { signingKey: wrongKeys.privateKey }), 'bad-signature');
  await assertPreserved(null, createRelease(keys, '9.9.3-test', 'windows', candidateBytes, { manifestDigest: '0'.repeat(64) }), 'bad-checksum');
});

test('PowerShell installer resolves the signed snapshot channel and rejects channel contract drift before replacement', { skip: process.platform !== 'win32', timeout: 30000 }, async (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-channel-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const wrongKeys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const xml = publicKeyXml(keys.publicKey);
  const version = '9.9.5-test';
  const candidate = buildWindowsCli(path.join(temp, 'candidate.exe'), version);
  const existing = buildWindowsCli(path.join(temp, 'existing.exe'), '8.0.0-old');
  const validRelease = createRelease(keys, version, 'windows', candidate);
  const validFiles = new Map([
    ...validRelease,
    ...createChannelForRelease(keys, version, validRelease),
  ]);
  const installDir = path.join(temp, 'valid');
  await withServer(releaseHandler(validFiles), async (base) => {
    const result = await runWindowsInstaller(windowsChannelInstallerEnv(base, installDir, xml));
    assert.equal(result.code, 0, result.stderr || result.stdout);
  });
  assert.equal(spawnSync(path.join(installDir, 'contexa.exe'), ['--version'], { encoding: 'utf8' }).stdout.trim(), version);

  async function assertChannelFailure(label, releaseOptions, channelOptions) {
    const targetDir = path.join(temp, label);
    fs.mkdirSync(targetDir);
    const installed = path.join(targetDir, 'contexa.exe');
    fs.writeFileSync(installed, existing);
    const before = sha256(fs.readFileSync(installed));
    const releaseFiles = createRelease(keys, version, 'windows', candidate, releaseOptions);
    const files = new Map([
      ...releaseFiles,
      ...createChannelForRelease(keys, version, releaseFiles, channelOptions),
    ]);
    await withServer(releaseHandler(files), async (base) => {
      const result = await runWindowsInstaller(windowsChannelInstallerEnv(base, targetDir, xml));
      assert.notEqual(result.code, 0, `${label} must fail`);
    });
    assert.equal(sha256(fs.readFileSync(installed)), before, `${label} must preserve the installed binary`);
  }

  await assertChannelFailure('channel-cli-mismatch', {}, { cliVersion: '9.9.5-other' });
  await assertChannelFailure('release-tag-mismatch', { releaseTag: 'v9.9.5-other' }, {});
  await assertChannelFailure('starter-mismatch', { releaseStarterVersion: '0.2.0-SNAPSHOT' }, {});
  await assertChannelFailure('asset-mismatch', { manifestDigest: '0'.repeat(64) }, {});
  await assertChannelFailure('channel-signature', {}, { signingKey: wrongKeys.privateKey });
});

test('POSIX installer completes a signed Linux x64 installation against a fake release server', { skip: process.platform !== 'win32', timeout: 20000 }, async (t) => {
  if (!fs.existsSync(gitSh)) return;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-posix-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const shimDir = path.join(temp, 'shim');
  const installDir = path.join(temp, 'bin');
  fs.mkdirSync(shimDir);
  fs.mkdirSync(installDir);
  const writeShim = (name, body) => {
    const target = path.join(shimDir, name);
    fs.writeFileSync(target, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  };
  writeShim('uname', 'case "${1:-}" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac');
  writeShim('ldd', 'echo "ldd (GNU libc) 2.31"');
  writeShim('getconf', 'echo "glibc 2.31"');

  const version = '9.9.4-test';
  const binary = Buffer.from(`#!/bin/sh\ncase "\${1:-}" in --version) echo ${version} ;; --help) echo "contexa init reset simulate" ;; *) exit 0 ;; esac\n`);
  const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const publicPem = keys.publicKey.export({ type: 'spki', format: 'pem' });
  const publicKeyPath = path.join(temp, 'public.pem');
  fs.writeFileSync(publicKeyPath, publicPem);
  const releaseFiles = createRelease(keys, version, 'linux', binary);
  const files = new Map([
    ...releaseFiles,
    ...createChannelForRelease(keys, version, releaseFiles),
  ]);

  await withServer(releaseHandler(files), async (base) => {
    const toPosixPath = (value) => value.replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`).replace(/\\/g, '/');
    const posixShimDir = toPosixPath(shimDir);
    const env = {
      PATH: `${posixShimDir}:/mingw64/bin:/usr/bin`,
      MSYS2_ENV_CONV_EXCL: 'PATH',
      HOME: toPosixPath(temp),
      CONTEXA_VERSION: '',
      CONTEXA_CHANNEL_MANIFEST_URL: `${base}/channel/channel-manifest.json`,
      CONTEXA_CHANNEL_SIGNATURE_URL: `${base}/channel/channel-manifest.json.sig`,
      CONTEXA_RELEASE_DOWNLOAD_BASE: `${base}/downloads`,
      CONTEXA_TRUSTED_PUBLIC_KEY_PATH: toPosixPath(publicKeyPath),
      CONTEXA_INSTALL_DIR: toPosixPath(installDir),
      CONTEXA_SKIP_PATH_UPDATE: '1',
      CONTEXA_HTTP_CONNECT_TIMEOUT_SEC: '1',
      CONTEXA_HTTP_TOTAL_TIMEOUT_SEC: '3',
      CONTEXA_HTTP_RETRIES: '1',
    };
    const scriptPath = sh.replace(/\\/g, '/');
    const result = await run(gitSh, ['-c', `PATH='${posixShimDir}:/mingw64/bin:/usr/bin'; export PATH; exec '${scriptPath}'`], env);
    assert.equal(result.code, 0, result.stderr || result.stdout);
    const installed = path.join(installDir, 'contexa').replace(/\\/g, '/');
    const versionResult = spawnSync(gitSh, [installed, '--version'], { encoding: 'utf8' });
    assert.equal(versionResult.status, 0, versionResult.stderr);
    assert.equal(versionResult.stdout.trim(), version);
  });
});

test('PowerShell 5.1 installer emits intact Korean success and error messages',
  { skip: process.platform !== 'win32', timeout: 10000 }, async (t) => {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-ko-ps5-'));
    t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
    const baseEnv = {
      CONTEXA_LANG: 'ko',
      CONTEXA_INSTALL_DIR: path.join(temp, 'bin'),
      CONTEXA_SKIP_PATH_UPDATE: '1',
    };
    const uninstall = await runWindowsInstaller({
      ...baseEnv,
      CONTEXA_INSTALL_ACTION: 'uninstall',
    });
    assert.equal(uninstall.code, 0, uninstall.stderr || uninstall.stdout);
    assert.match(uninstall.stdout, /바이너리.*제거/);
    assert.equal((uninstall.stdout + uninstall.stderr).includes('\uFFFD'), false);

    const invalid = await runWindowsInstaller({
      ...baseEnv,
      CONTEXA_INSTALL_ACTION: 'invalid',
    });
    assert.equal(invalid.code, 1);
    assert.match(invalid.stderr, /설치 프로그램 실패.*지원하지 않는 CONTEXA_INSTALL_ACTION/s);
    assert.equal((invalid.stdout + invalid.stderr).includes('\uFFFD'), false);
  });

test('PowerShell 7 installer emits intact Korean success and error messages',
  { skip: process.platform !== 'win32' || !pwshAvailable, timeout: 10000 }, async (t) => {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-ko-ps7-'));
    t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
    const baseEnv = {
      CONTEXA_LANG: 'ko',
      CONTEXA_INSTALL_DIR: path.join(temp, 'bin'),
      CONTEXA_SKIP_PATH_UPDATE: '1',
    };
    const uninstall = await runPwshInstaller({
      ...baseEnv,
      CONTEXA_INSTALL_ACTION: 'uninstall',
    });
    assert.equal(uninstall.code, 0, uninstall.stderr || uninstall.stdout);
    assert.match(uninstall.stdout, /바이너리.*제거/);
    assert.equal((uninstall.stdout + uninstall.stderr).includes('\uFFFD'), false);

    const invalid = await runPwshInstaller({
      ...baseEnv,
      CONTEXA_INSTALL_ACTION: 'invalid',
    });
    assert.equal(invalid.code, 1);
    assert.match(invalid.stderr, /설치 프로그램 실패.*지원하지 않는 CONTEXA_INSTALL_ACTION/s);
    assert.equal((invalid.stdout + invalid.stderr).includes('\uFFFD'), false);
  });

test('POSIX installer emits intact Korean success and error messages', { timeout: 10000 }, async (t) => {
  if (process.platform === 'win32' && !fs.existsSync(gitSh)) return;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-ko-posix-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const scriptPath = process.platform === 'win32' ? sh.replace(/\\/g, '/') : sh;
  const baseEnv = {
    HOME: temp,
    CONTEXA_LANG: 'ko',
    CONTEXA_INSTALL_DIR: path.join(temp, 'bin'),
    CONTEXA_SKIP_PATH_UPDATE: '1',
  };
  const uninstall = await run(gitSh, [scriptPath], {
    ...baseEnv,
    CONTEXA_INSTALL_ACTION: 'uninstall',
  });
  assert.equal(uninstall.code, 0, uninstall.stderr || uninstall.stdout);
  assert.match(uninstall.stdout, /바이너리.*제거/);
  assert.equal((uninstall.stdout + uninstall.stderr).includes('\uFFFD'), false);

  const invalid = await run(gitSh, [scriptPath], {
    ...baseEnv,
    CONTEXA_INSTALL_ACTION: 'invalid',
  });
  assert.equal(invalid.code, 1);
  assert.match(invalid.stderr, /설치 프로그램 실패.*지원하지 않는 CONTEXA_INSTALL_ACTION/s);
  assert.equal((invalid.stdout + invalid.stderr).includes('\uFFFD'), false);
});
