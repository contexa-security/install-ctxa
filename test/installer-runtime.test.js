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
const powershell = process.platform === 'win32'
  ? (process.env.CONTEXA_TEST_POWERSHELL || 'powershell.exe')
  : null;
const windowsFixtureCompiler = process.platform === 'win32' ? 'powershell.exe' : null;
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

function buildWindowsCli(target, version, options = {}) {
  const finalFailure = options.failAtFinalPath
    ? 'if (System.IO.Path.GetFileName(Environment.GetCommandLineArgs()[0]).Equals("contexa.exe", StringComparison.OrdinalIgnoreCase) && args.Length > 0 && args[0] == "--help") return 19;'
    : '';
  const source = `using System; public static class Program { public static int Main(string[] args) { ${finalFailure} if (args.Length > 0 && args[0] == "--version") Console.WriteLine("${version}"); else if (args.Length > 0 && args[0] == "--help") Console.WriteLine("contexa init | reset [--simulate]"); return 0; } }`;
  const encoded = Buffer.from(source, 'utf16le').toString('base64');
  const escaped = target.replace(/'/g, "''");
  const script = `$source=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('${encoded}')); Add-Type -TypeDefinition $source -OutputAssembly '${escaped}' -OutputType ConsoleApplication`;
  const result = spawnSync(windowsFixtureCompiler, ['-NoProfile', '-NonInteractive', '-Command', script],
    { encoding: 'utf8', windowsHide: true });
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

function toPosixPath(value) {
  return value.replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`).replace(/\\/g, '/');
}

function createPosixHarness(temp, architecture = 'x86_64') {
  const shimDir = path.join(temp, 'shim');
  const installDir = path.join(temp, 'bin');
  fs.mkdirSync(shimDir, { recursive: true });
  fs.mkdirSync(installDir, { recursive: true });
  const writeShim = (name, body) => {
    const target = path.join(shimDir, name);
    fs.writeFileSync(target, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  };
  writeShim('uname', 'case "${1:-}" in -s) echo Linux ;; -m) echo ' + architecture + ' ;; *) echo Linux ;; esac');
  writeShim('ldd', 'echo "ldd (GNU libc) 2.31"');
  writeShim('getconf', 'echo "glibc 2.31"');
  return { shimDir, installDir };
}

function posixInstallerEnv(base, harness, publicKeyPath, version = '') {
  const posixShimDir = toPosixPath(harness.shimDir);
  return {
    PATH: `${posixShimDir}:/mingw64/bin:/usr/bin`,
    MSYS2_ENV_CONV_EXCL: 'PATH',
    HOME: toPosixPath(path.dirname(harness.installDir)),
    CONTEXA_VERSION: version ? `v${version}` : '',
    CONTEXA_CHANNEL_MANIFEST_URL: `${base}/channel/channel-manifest.json`,
    CONTEXA_CHANNEL_SIGNATURE_URL: `${base}/channel/channel-manifest.json.sig`,
    CONTEXA_RELEASE_DOWNLOAD_BASE: `${base}/downloads`,
    CONTEXA_TRUSTED_PUBLIC_KEY_PATH: toPosixPath(publicKeyPath),
    CONTEXA_INSTALL_DIR: toPosixPath(harness.installDir),
    CONTEXA_SKIP_PATH_UPDATE: '1',
    CONTEXA_HTTP_CONNECT_TIMEOUT_SEC: '1',
    CONTEXA_HTTP_TOTAL_TIMEOUT_SEC: '3',
    CONTEXA_HTTP_RETRIES: '1',
  };
}

function runPosixInstaller(env) {
  const quotedPath = env.PATH.replace(/'/g, `'"'"'`);
  const scriptPath = toPosixPath(sh).replace(/'/g, `'"'"'`);
  return run(gitSh, ['-c', `PATH='${quotedPath}'; export PATH; exec '${scriptPath}'`], env);
}

function buildPosixCli(version, options = {}) {
  const finalFailure = options.failAtFinalPath
    ? 'case "$0" in */contexa) [ "${1:-}" = "--help" ] && exit 19 ;; esac\n'
    : '';
  return Buffer.from('#!/bin/sh\n' + finalFailure + 'case "${1:-}" in --version) echo ' + version + ' ;; --help) echo "contexa init reset simulate" ;; *) exit 0 ;; esac\n');
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

test('PowerShell installer bounds HTTP retries and preserves the existing binary for the full fault matrix', { skip: process.platform !== 'win32', timeout: 45000 }, async (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-failures-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const wrongKeys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const xml = publicKeyXml(keys.publicKey);
  const existingBytes = buildWindowsCli(path.join(temp, 'existing.exe'), '8.0.0-old');
  const candidateBytes = buildWindowsCli(path.join(temp, 'candidate.exe'), '9.9.3-test');
  const finalSmokeFailure = buildWindowsCli(path.join(temp, 'final-smoke.exe'), '9.9.3-test', { failAtFinalPath: true });

  async function assertPreserved(handler, files, label, envOverrides = {}) {
    const installDir = path.join(temp, label);
    fs.mkdirSync(installDir);
    const installed = path.join(installDir, 'contexa.exe');
    fs.writeFileSync(installed, existingBytes);
    const before = sha256(fs.readFileSync(installed));
    await withServer(handler || releaseHandler(files), async (base) => {
      const result = await runWindowsInstaller({
        ...windowsInstallerEnv(base, installDir, '9.9.3-test', xml),
        ...envOverrides,
      });
      assert.notEqual(result.code, 0, `${label} must return a non-zero exit code`);
      return result;
    });
    assert.equal(sha256(fs.readFileSync(installed)), before, `${label} must preserve the installed binary`);
    return installed;
  }

  await assertPreserved((req, res) => { res.statusCode = 404; res.end('not found'); }, null, 'not-found');
  await assertPreserved(() => {}, null, 'timeout');
  await assertPreserved(null, createRelease(keys, '9.9.3-test', 'windows', candidateBytes, { signingKey: wrongKeys.privateKey }), 'bad-signature');
  await assertPreserved(null, createRelease(keys, '9.9.3-test', 'windows', candidateBytes, { manifestDigest: '0'.repeat(64) }), 'bad-checksum');
  await assertPreserved(null, createRelease(keys, '9.9.3-test', 'windows', finalSmokeFailure), 'final-smoke');
  await assertPreserved(null, createRelease(keys, '9.9.3-test', 'windows', candidateBytes), 'bad-architecture', {
    PROCESSOR_ARCHITECTURE: 'ARM64',
    PROCESSOR_ARCHITEW6432: '',
  });

  for (const fault of [
    {
      label: 'rate-limit',
      reason: /HTTP_429_RATE_LIMIT/,
      handler: (req, res) => { res.statusCode = 429; res.end('rate limited'); },
    },
    {
      label: 'server-error',
      reason: /HTTP_5XX/,
      handler: (req, res) => { res.statusCode = 503; res.end('unavailable'); },
    },
    {
      label: 'connection-reset',
      reason: /CONNECTION_RESET/,
      handler: (req) => req.socket.destroy(),
    },
  ]) {
    const installDir = path.join(temp, fault.label);
    fs.mkdirSync(installDir);
    const installed = path.join(installDir, 'contexa.exe');
    fs.writeFileSync(installed, existingBytes);
    const before = sha256(fs.readFileSync(installed));
    let requests = 0;
    await withServer((req, res) => {
      requests += 1;
      fault.handler(req, res);
    }, async (base) => {
      const result = await runWindowsInstaller(windowsInstallerEnv(base, installDir, '9.9.3-test', xml));
      assert.notEqual(result.code, 0);
      assert.match(result.stdout + result.stderr, fault.reason);
      assert.match(result.stdout + result.stderr, /after 2 attempt\(s\)/);
    });
    if (fault.label === 'connection-reset') {
      assert.ok(requests >= 2 && requests <= 8,
        `HttpWebRequest transport resends must remain bounded; actual requests=${requests}`);
    } else {
      assert.equal(requests, 2, `${fault.label} must use one initial request plus one bounded retry`);
    }
    assert.equal(sha256(fs.readFileSync(installed)), before);
  }
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

test('PowerShell installer recovers every persisted replacement state without deleting the legacy binary', { skip: process.platform !== 'win32', timeout: 30000 }, async (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-recovery-win-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const oldBytes = buildWindowsCli(path.join(temp, 'old.exe'), '8.0.0-old');
  const newBytes = buildWindowsCli(path.join(temp, 'new.exe'), '9.9.20-new');

  for (const state of ['DOWNLOADED', 'VERIFIED', 'OLD_MOVED', 'NEW_MOVED', 'SMOKE_PASSED']) {
    const installDir = path.join(temp, state.toLowerCase());
    fs.mkdirSync(installDir);
    const finalPath = path.join(installDir, 'contexa.exe');
    const backupPath = `${finalPath}.previous`;
    const newPath = path.join(installDir, `.contexa-${crypto.randomBytes(16).toString('hex')}.new.exe`);
    const markerPath = `${finalPath}.install-transaction.json`;
    if (state === 'DOWNLOADED' || state === 'VERIFIED') {
      fs.writeFileSync(finalPath, oldBytes);
      fs.writeFileSync(newPath, newBytes);
    } else if (state === 'OLD_MOVED') {
      fs.writeFileSync(backupPath, oldBytes);
      fs.writeFileSync(newPath, newBytes);
    } else {
      fs.writeFileSync(finalPath, newBytes);
      fs.writeFileSync(backupPath, oldBytes);
    }
    fs.writeFileSync(markerPath, JSON.stringify({
      schemaVersion: 1,
      state,
      finalPath,
      backupPath,
      newPath,
      expectedVersion: '9.9.20-new',
      hadOriginal: true,
      updatedAt: new Date().toISOString(),
    }));

    const result = await runWindowsInstaller({
      CONTEXA_INSTALL_DIR: installDir,
      CONTEXA_INSTALL_ACTION: 'recovery-probe',
      CONTEXA_SKIP_PATH_UPDATE: '1',
    });
    assert.notEqual(result.code, 0, 'the unsupported probe action runs only after startup recovery');
    assert.equal(fs.existsSync(markerPath), false, `${state} marker must be cleared after deterministic recovery`);
    const expectedVersion = state === 'OLD_MOVED' || state === 'NEW_MOVED' || state === 'SMOKE_PASSED'
      ? '9.9.20-new'
      : '8.0.0-old';
    assert.equal(spawnSync(finalPath, ['--version'], { encoding: 'utf8' }).stdout.trim(), expectedVersion);
    if (state === 'OLD_MOVED' || state === 'NEW_MOVED' || state === 'SMOKE_PASSED') {
      assert.equal(sha256(fs.readFileSync(backupPath)), sha256(oldBytes), `${state} must preserve the legacy rollback binary`);
    }
  }
});

test('PowerShell installer automatically recovers after an actual process termination at DOWNLOADED', { skip: process.platform !== 'win32', timeout: 30000 }, async (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-kill-win-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const installDir = path.join(temp, 'bin');
  fs.mkdirSync(installDir);
  const finalPath = path.join(installDir, 'contexa.exe');
  const markerPath = `${finalPath}.install-transaction.json`;
  const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const xml = publicKeyXml(keys.publicKey);
  const version = '9.9.21-new';
  const oldBytes = buildWindowsCli(path.join(temp, 'old.exe'), '8.0.0-old');
  const newBytes = buildWindowsCli(path.join(temp, 'new.exe'), version);
  fs.writeFileSync(finalPath, oldBytes);
  const files = createRelease(keys, version, 'windows', newBytes);

  await withServer((req, res) => {
    const pathname = new URL(req.url, 'http://localhost').pathname;
    if (pathname.endsWith('.sha256')) return;
    const value = files.get(pathname);
    if (!value) { res.statusCode = 404; res.end('not found'); return; }
    res.statusCode = 200;
    res.end(value);
  }, async (base) => {
    const child = spawn(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1], {
      env: {
        ...process.env,
        ...windowsInstallerEnv(base, installDir, version, xml),
        CONTEXA_HTTP_TOTAL_TIMEOUT_SEC: '30',
      },
      windowsHide: true,
    });
    let observed = false;
    for (let attempt = 0; attempt < 200; attempt += 1) {
      if (fs.existsSync(markerPath)) {
        const marker = JSON.parse(fs.readFileSync(markerPath, 'utf8'));
        if (marker.state === 'DOWNLOADED') { observed = true; break; }
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(observed, true, 'DOWNLOADED marker must be durable before the checksum request completes');
    child.kill();
    await new Promise((resolve) => child.once('exit', resolve));
  });

  assert.equal(sha256(fs.readFileSync(finalPath)), sha256(oldBytes));
  assert.equal(fs.existsSync(markerPath), true);
  await withServer(releaseHandler(files), async (base) => {
    const recovered = await runWindowsInstaller(windowsInstallerEnv(base, installDir, version, xml));
    assert.equal(recovered.code, 0, recovered.stderr || recovered.stdout);
  });
  assert.equal(spawnSync(finalPath, ['--version'], { encoding: 'utf8' }).stdout.trim(), version);
  assert.equal(fs.existsSync(markerPath), false);
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

test('POSIX installer recovers every persisted replacement state without deleting the legacy binary',
  { skip: process.platform === 'win32', timeout: 30000 }, async (t) => {
  if (!fs.existsSync(gitSh)) return;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-recovery-posix-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const oldBytes = buildPosixCli('8.0.0-old');
  const newBytes = buildPosixCli('9.9.22-new');

  for (const state of ['DOWNLOADED', 'VERIFIED', 'OLD_MOVED', 'NEW_MOVED', 'SMOKE_PASSED']) {
    const harness = createPosixHarness(path.join(temp, state.toLowerCase()));
    const finalPath = path.join(harness.installDir, 'contexa');
    const backupPath = `${finalPath}.previous`;
    const newPath = path.join(harness.installDir, `.contexa.new.${crypto.randomBytes(4).toString('hex')}`);
    const markerPath = `${finalPath}.install-transaction`;
    if (state === 'DOWNLOADED' || state === 'VERIFIED') {
      fs.writeFileSync(finalPath, oldBytes, { mode: 0o755 });
      fs.writeFileSync(newPath, newBytes, { mode: 0o755 });
    } else if (state === 'OLD_MOVED') {
      fs.writeFileSync(backupPath, oldBytes, { mode: 0o755 });
      fs.writeFileSync(newPath, newBytes, { mode: 0o755 });
    } else {
      fs.writeFileSync(finalPath, newBytes, { mode: 0o755 });
      fs.writeFileSync(backupPath, oldBytes, { mode: 0o755 });
    }
    const posixFinal = toPosixPath(finalPath);
    const posixBackup = toPosixPath(backupPath);
    const posixNew = toPosixPath(newPath);
    fs.writeFileSync(markerPath, [
      'SCHEMA_VERSION=1',
      `STATE=${state}`,
      `FINAL_PATH=${posixFinal}`,
      `BACKUP_PATH=${posixBackup}`,
      `NEW_PATH=${posixNew}`,
      'EXPECTED_VERSION=9.9.22-new',
      'HAD_ORIGINAL=1',
      '',
    ].join('\n'));

    const result = await runPosixInstaller({
      ...posixInstallerEnv('http://127.0.0.1:1', harness, path.join(temp, 'unused.pem'), '9.9.22-new'),
      CONTEXA_INSTALL_ACTION: 'recovery-probe',
    });
    assert.notEqual(result.code, 0, 'the unsupported probe action runs only after startup recovery');
    assert.equal(fs.existsSync(markerPath), false, `${state} marker must be cleared after deterministic recovery`);
    const expectedVersion = state === 'OLD_MOVED' || state === 'NEW_MOVED' || state === 'SMOKE_PASSED'
      ? '9.9.22-new'
      : '8.0.0-old';
    assert.equal(spawnSync(gitSh, [toPosixPath(finalPath), '--version'], { encoding: 'utf8' }).stdout.trim(), expectedVersion);
    if (state === 'OLD_MOVED' || state === 'NEW_MOVED' || state === 'SMOKE_PASSED') {
      assert.equal(sha256(fs.readFileSync(backupPath)), sha256(oldBytes), `${state} must preserve the legacy rollback binary`);
    }
  }
});

test('POSIX installer performs lifecycle and preserves the existing binary for the full fault matrix',
  { skip: process.platform === 'win32', timeout: 60000 }, async (t) => {
  if (!fs.existsSync(gitSh)) return;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'contexa-installer-posix-matrix-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const wrongKeys = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
  const publicKeyPath = path.join(temp, 'public.pem');
  fs.writeFileSync(publicKeyPath, keys.publicKey.export({ type: 'spki', format: 'pem' }));
  const oldVersion = '9.9.10-old';
  const currentVersion = '9.9.11-test';
  const nextVersion = '9.9.12-test';
  const oldBinary = buildPosixCli(oldVersion);
  const currentBinary = buildPosixCli(currentVersion);
  const nextBinary = buildPosixCli(nextVersion);

  const lifecycleHarness = createPosixHarness(path.join(temp, 'lifecycle'));
  const lifecycleFiles = new Map([
    ...createRelease(keys, currentVersion, 'linux', currentBinary),
    ...createRelease(keys, nextVersion, 'linux', nextBinary),
  ]);
  await withServer(releaseHandler(lifecycleFiles), async (base) => {
    const first = await runPosixInstaller(posixInstallerEnv(base, lifecycleHarness, publicKeyPath, currentVersion));
    assert.equal(first.code, 0, first.stderr || first.stdout);
    const installed = path.join(lifecycleHarness.installDir, 'contexa');
    assert.equal(spawnSync(gitSh, [toPosixPath(installed), '--version'], { encoding: 'utf8' }).stdout.trim(), currentVersion);
    const firstDigest = sha256(fs.readFileSync(installed));

    const same = await runPosixInstaller(posixInstallerEnv(base, lifecycleHarness, publicKeyPath, currentVersion));
    assert.equal(same.code, 0, same.stderr || same.stdout);
    assert.equal(sha256(fs.readFileSync(installed)), firstDigest);
    assert.equal(fs.existsSync(`${installed}.previous`), false);

    const update = await runPosixInstaller(posixInstallerEnv(base, lifecycleHarness, publicKeyPath, nextVersion));
    assert.equal(update.code, 0, update.stderr || update.stdout);
    assert.equal(spawnSync(gitSh, [toPosixPath(installed), '--version'], { encoding: 'utf8' }).stdout.trim(), nextVersion);
    assert.equal(spawnSync(gitSh, [toPosixPath(`${installed}.previous`), '--version'], { encoding: 'utf8' }).stdout.trim(), currentVersion);

    const rollback = await runPosixInstaller({
      ...posixInstallerEnv(base, lifecycleHarness, publicKeyPath, nextVersion),
      CONTEXA_INSTALL_ACTION: 'rollback',
    });
    assert.equal(rollback.code, 0, rollback.stderr || rollback.stdout);
    assert.equal(spawnSync(gitSh, [toPosixPath(installed), '--version'], { encoding: 'utf8' }).stdout.trim(), currentVersion);

    const uninstall = await runPosixInstaller({
      ...posixInstallerEnv(base, lifecycleHarness, publicKeyPath, currentVersion),
      CONTEXA_INSTALL_ACTION: 'uninstall',
    });
    assert.equal(uninstall.code, 0, uninstall.stderr || uninstall.stdout);
    assert.equal(fs.existsSync(installed), false);
    assert.equal(fs.existsSync(`${installed}.previous`), false);
  });

  async function assertPreserved(label, handler, releaseFiles, options = {}) {
    const harness = createPosixHarness(path.join(temp, label), options.architecture || 'x86_64');
    const installed = path.join(harness.installDir, 'contexa');
    fs.writeFileSync(installed, oldBinary, { mode: 0o755 });
    const before = sha256(fs.readFileSync(installed));
    await withServer(handler || releaseHandler(releaseFiles), async (base) => {
      const result = await runPosixInstaller({
        ...posixInstallerEnv(base, harness, publicKeyPath, currentVersion),
        CONTEXA_HTTP_TOTAL_TIMEOUT_SEC: options.totalTimeout || '3',
      });
      assert.notEqual(result.code, 0, `${label} must return a non-zero exit code`);
      if (options.reason) assert.match(result.stdout + result.stderr, options.reason);
    });
    assert.equal(sha256(fs.readFileSync(installed)), before, `${label} must preserve the installed binary`);
  }

  await assertPreserved('not-found', (req, res) => { res.statusCode = 404; res.end('not found'); });
  await assertPreserved('timeout', () => {}, null, { totalTimeout: '2', reason: /TIMEOUT/ });
  await assertPreserved('bad-signature', null,
    createRelease(keys, currentVersion, 'linux', currentBinary, { signingKey: wrongKeys.privateKey }));
  await assertPreserved('bad-checksum', null,
    createRelease(keys, currentVersion, 'linux', currentBinary, { manifestDigest: '0'.repeat(64) }));
  await assertPreserved('bad-architecture', null,
    createRelease(keys, currentVersion, 'linux', currentBinary), { architecture: 'i686' });
  await assertPreserved('final-smoke', null,
    createRelease(keys, currentVersion, 'linux', buildPosixCli(currentVersion, { failAtFinalPath: true })));

  for (const fault of [
    {
      label: 'rate-limit',
      reason: /HTTP_429_RATE_LIMIT/,
      handler: (req, res) => { res.statusCode = 429; res.end('rate limited'); },
    },
    {
      label: 'server-error',
      reason: /HTTP_5XX/,
      handler: (req, res) => { res.statusCode = 503; res.end('unavailable'); },
    },
    {
      label: 'connection-reset',
      reason: /CONNECTION_RESET/,
      handler: (req) => req.socket.destroy(),
    },
  ]) {
    let requests = 0;
    await assertPreserved(fault.label, (req, res) => {
      requests += 1;
      fault.handler(req, res);
    }, null, { reason: fault.reason });
    assert.equal(requests, 2, `${fault.label} must use one initial request plus one bounded retry`);
  }
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
