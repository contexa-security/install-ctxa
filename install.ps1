#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$script:OriginalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

$script:Repository = 'contexa-security/contexa-cli'
$script:DefaultReleaseApi = 'https://api.github.com/repos/contexa-security/contexa-cli/releases/latest'
$script:DefaultDownloadBase = 'https://github.com/contexa-security/contexa-cli/releases/download'
$script:PublicKeyXml = '<RSAKeyValue><Modulus>osHQvVy9S+AGAvskLk13njD9SoRHMURAbU2RQWZgQt2t0vN3Ib7aVMIwStGdJhaDIuPHTg0WrwM6ogPDDqfFmHHm8XkviBHnkgFQWvovLHtRudSgU6g+5ReaT0G0HsWFC3aGVJhOEwo5EqJJxZgjIc533CJTyn6ZbV8C0PGPP3kZQb1C/zPCaVtQg02v3Vm1C+sivBfCFRRJlcXhfc5hvbtB40DcRFkJfkBbdHBwdAnRfuH8OnIeL9dWEFyNgR7ZIREnjqNahtZbUM9gBS1p1Zw3ffTls2QSyMvQobqwNOdfP2/LN0K8uiJJ8K7nh524wGANdTlmKY2cAAkUbZsO2FK7sLCcVDXShQptXFj31DEzdQCb9hAnarXK5C6qBFxloDGzV8b+xlALFQBIO8xwXlxR8jZq+CiVJmWHUr78A0fubstaBUSgpU1ZzdUl0plI6MczU/udM7miH/O1ih7t0ox745ahU/7eXEYOLNRAJs2gidol7m+apyY/qV7DIMhz</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

function Get-PositiveIntEnvironment {
    param([string]$Name, [int]$DefaultValue, [int]$Maximum)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $Maximum) {
        throw ($Name + ' must be an integer from 1 to ' + $Maximum + '.')
    }
    return $parsed
}

function Get-InstallDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:CONTEXA_INSTALL_DIR)) {
        return [System.IO.Path]::GetFullPath($env:CONTEXA_INSTALL_DIR)
    }
    $local = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($local) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $local = Join-Path $env:USERPROFILE 'AppData\Local'
    }
    if ([string]::IsNullOrWhiteSpace($local)) {
        throw 'Cannot resolve a user installation directory. Set CONTEXA_INSTALL_DIR and retry.'
    }
    return Join-Path $local 'Programs\Contexa'
}

function Assert-WindowsX64 {
    if ($env:OS -ne 'Windows_NT') {
        throw 'install.ps1 supports Windows only. Use install.sh on Linux or macOS.'
    }
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -notmatch '^(AMD64|x86_64)$') {
        throw ('Unsupported Windows architecture: ' + $architecture + '. The existing CLI was not changed.')
    }
}

function Test-RetryableWebFailure {
    param([System.Exception]$Error)
    if ($Error -is [System.TimeoutException]) { return $true }
    if ($Error -isnot [System.Net.WebException]) { return $false }
    if ($null -eq $Error.Response) { return $true }
    $statusCode = [int]$Error.Response.StatusCode
    return $statusCode -ge 500 -or $statusCode -eq 408 -or $statusCode -eq 429
}

function Invoke-BoundedDownload {
    param([string]$Uri)
    $connectTimeout = Get-PositiveIntEnvironment 'CONTEXA_HTTP_CONNECT_TIMEOUT_SEC' 5 60
    $totalTimeout = Get-PositiveIntEnvironment 'CONTEXA_HTTP_TOTAL_TIMEOUT_SEC' 30 300
    $retryCount = Get-PositiveIntEnvironment 'CONTEXA_HTTP_RETRIES' 2 5
    $deadline = [DateTime]::UtcNow.AddSeconds($totalTimeout)
    $lastError = $null

    for ($attempt = 1; $attempt -le ($retryCount + 1); $attempt++) {
        $request = $null
        $response = $null
        $stream = $null
        $memory = $null
        try {
            $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
            if ($remaining -le 0) { throw [System.TimeoutException]::new('HTTP total timeout exceeded.') }
            $request = [System.Net.HttpWebRequest]::Create($Uri)
            $request.Method = 'GET'
            $request.UserAgent = 'contexa-installer/phase1'
            $request.Timeout = [Math]::Min($connectTimeout, $remaining) * 1000
            $request.ReadWriteTimeout = [Math]::Min($connectTimeout, $remaining) * 1000
            $response = $request.GetResponse()
            $stream = $response.GetResponseStream()
            $memory = New-Object System.IO.MemoryStream
            $buffer = New-Object byte[] 65536
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ([DateTime]::UtcNow -gt $deadline) {
                    $request.Abort()
                    throw [System.TimeoutException]::new('HTTP total timeout exceeded.')
                }
                $memory.Write($buffer, 0, $read)
            }
            return $memory.ToArray()
        } catch {
            $lastError = $_.Exception
            $retryable = Test-RetryableWebFailure $lastError
            if (-not $retryable -or $attempt -gt $retryCount -or [DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 250
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($response) { $response.Dispose() }
            if ($memory) { $memory.Dispose() }
        }
    }
    throw $lastError
}

function Convert-BytesToText {
    param([byte[]]$Bytes)
    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Get-TrustedPublicKeyXml {
    param([string]$DownloadBase)
    if ([string]::IsNullOrWhiteSpace($env:CONTEXA_TRUSTED_PUBLIC_KEY_XML)) {
        return $script:PublicKeyXml
    }
    $uri = [Uri]$DownloadBase
    if (-not $uri.IsLoopback) {
        throw 'A test public key override is allowed only with a loopback release server.'
    }
    return $env:CONTEXA_TRUSTED_PUBLIC_KEY_XML
}

function Test-ReleaseManifestSignature {
    param([byte[]]$ManifestBytes, [byte[]]$SignatureTextBytes, [string]$PublicKeyXml)
    $signatureText = (Convert-BytesToText $SignatureTextBytes).Trim()
    try { $signature = [Convert]::FromBase64String($signatureText) } catch { throw 'Release manifest signature is not valid base64.' }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString($PublicKeyXml)
        $verified = $rsa.VerifyData(
            $ManifestBytes,
            [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'),
            $signature
        )
    } finally {
        $rsa.Dispose()
    }
    if (-not $verified) { throw 'Release manifest signature verification failed. The existing CLI was not changed.' }
}

function Get-TargetVersion {
    if (-not [string]::IsNullOrWhiteSpace($env:CONTEXA_VERSION)) {
        $version = $env:CONTEXA_VERSION.Trim()
    } else {
        $api = if ([string]::IsNullOrWhiteSpace($env:CONTEXA_RELEASE_API_URL)) { $script:DefaultReleaseApi } else { $env:CONTEXA_RELEASE_API_URL }
        $metadata = Convert-BytesToText (Invoke-BoundedDownload $api) | ConvertFrom-Json
        $version = [string]$metadata.tag_name
    }
    if ($version -notmatch '^v[0-9A-Za-z][0-9A-Za-z._-]*$') { throw ('Invalid or empty release tag: ' + $version) }
    return $version
}

function Get-ReportedVersion {
    param([string]$Binary)
    $output = & $Binary --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('Binary version check failed: ' + $Binary) }
    return ($output | Select-Object -First 1).ToString().Trim()
}

function Test-BinarySmoke {
    param([string]$Binary, [string]$ExpectedVersion)
    if ((Get-ReportedVersion $Binary) -ne $ExpectedVersion) {
        throw ('Binary version mismatch at ' + $Binary)
    }
    & $Binary --help *> $null
    if ($LASTEXITCODE -ne 0) { throw ('Binary help check failed: ' + $Binary) }
    & $Binary *> $null
    if ($LASTEXITCODE -ne 0) { throw ('Binary first-run check failed: ' + $Binary) }
}

function Ensure-CommandPath {
    param([string]$InstallDir, [string]$FinalPath)
    $separator = [System.IO.Path]::PathSeparator
    $entries = @($env:Path.Split($separator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $normalized = $InstallDir.TrimEnd('\')
    $entries = @($entries | Where-Object { $_.TrimEnd('\') -ne $normalized })
    $env:Path = $InstallDir + $separator + ($entries -join $separator)

    if ($env:CONTEXA_SKIP_PATH_UPDATE -ne '1') {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($null -eq $userPath) { $userPath = '' }
        $userEntries = @($userPath.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $userEntries = @($userEntries | Where-Object { $_.TrimEnd('\') -ne $normalized })
        [Environment]::SetEnvironmentVariable('Path', ($InstallDir + ';' + ($userEntries -join ';')).TrimEnd(';'), 'User')
    }

    $commands = @(Get-Command contexa -All -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) { throw 'Installed contexa command is not resolvable from PATH.' }
    $firstPath = [System.IO.Path]::GetFullPath($commands[0].Source)
    if ($firstPath -ne [System.IO.Path]::GetFullPath($FinalPath)) {
        throw ('PATH conflict: first contexa command is ' + $firstPath + ', expected ' + $FinalPath)
    }
    $conflicts = @($commands | Select-Object -Skip 1 | Where-Object { $_.Source -and ([System.IO.Path]::GetFullPath($_.Source) -ne [System.IO.Path]::GetFullPath($FinalPath)) })
    foreach ($conflict in $conflicts) {
        Write-Warning ('Another contexa command remains on PATH and was not deleted: ' + $conflict.Source)
    }
}

function Invoke-Rollback {
    param([string]$FinalPath, [string]$BackupPath)
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw ('No previous Contexa binary exists at ' + $BackupPath) }
    $rollbackTemp = $FinalPath + '.rollback-' + [guid]::NewGuid().ToString('N')
    try {
        if (Test-Path -LiteralPath $FinalPath) { [System.IO.File]::Move($FinalPath, $rollbackTemp) }
        [System.IO.File]::Move($BackupPath, $FinalPath)
        $version = Get-ReportedVersion $FinalPath
        & $FinalPath --help *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Rolled-back binary failed smoke verification.' }
        if (Test-Path -LiteralPath $rollbackTemp) { [System.IO.File]::Move($rollbackTemp, $BackupPath) }
        Write-Host ('  Rolled back Contexa CLI to ' + $version) -ForegroundColor Green
    } catch {
        if (-not (Test-Path -LiteralPath $FinalPath) -and (Test-Path -LiteralPath $rollbackTemp)) {
            [System.IO.File]::Move($rollbackTemp, $FinalPath)
        }
        throw
    }
}

function Invoke-Uninstall {
    param([string]$InstallDir, [string]$FinalPath, [string]$BackupPath)
    if (Test-Path -LiteralPath $FinalPath) { Remove-Item -LiteralPath $FinalPath -Force }
    if (Test-Path -LiteralPath $BackupPath) { Remove-Item -LiteralPath $BackupPath -Force }
    if ($env:CONTEXA_SKIP_PATH_UPDATE -ne '1') {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($null -ne $userPath) {
            $normalized = $InstallDir.TrimEnd('\')
            $remaining = @($userPath.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimEnd('\') -ne $normalized })
            [Environment]::SetEnvironmentVariable('Path', ($remaining -join ';'), 'User')
        }
    }
    Write-Host '  Contexa CLI binary and installer-owned PATH entry were removed. Project files were not changed.' -ForegroundColor Green
}

function Invoke-ContexaInstaller {
    Assert-WindowsX64
    $installDir = Get-InstallDirectory
    $finalPath = Join-Path $installDir 'contexa.exe'
    $backupPath = $finalPath + '.previous'
    $action = if ([string]::IsNullOrWhiteSpace($env:CONTEXA_INSTALL_ACTION)) { 'install' } else { $env:CONTEXA_INSTALL_ACTION.Trim().ToLowerInvariant() }

    if ($action -eq 'rollback') { Invoke-Rollback $finalPath $backupPath; Ensure-CommandPath $installDir $finalPath; return }
    if ($action -eq 'uninstall') { Invoke-Uninstall $installDir $finalPath $backupPath; return }
    if ($action -ne 'install') { throw ('Unsupported CONTEXA_INSTALL_ACTION: ' + $action) }

    if (-not (Test-Path -LiteralPath $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
    $version = Get-TargetVersion
    $expectedCliVersion = $version.Substring(1)
    $downloadBase = if ([string]::IsNullOrWhiteSpace($env:CONTEXA_RELEASE_DOWNLOAD_BASE)) { $script:DefaultDownloadBase } else { $env:CONTEXA_RELEASE_DOWNLOAD_BASE.TrimEnd('/') }
    $releaseBase = $downloadBase + '/' + $version

    $manifestBytes = Invoke-BoundedDownload ($releaseBase + '/release-manifest.json')
    $signatureBytes = Invoke-BoundedDownload ($releaseBase + '/release-manifest.json.sig')
    Test-ReleaseManifestSignature $manifestBytes $signatureBytes (Get-TrustedPublicKeyXml $downloadBase)
    $manifest = Convert-BytesToText $manifestBytes | ConvertFrom-Json
    if ($manifest.releaseTag -ne $version -or $manifest.cliVersion -ne $expectedCliVersion) {
        throw 'Signed release manifest does not match the requested tag and CLI version.'
    }
    if (-not $manifest.signature.required -or $manifest.signature.algorithm -ne 'RSA-3072-SHA256') {
        throw 'Signed release manifest trust contract is missing or unsupported.'
    }
    $asset = @($manifest.assets | Where-Object { $_.os -eq 'windows' -and $_.arch -eq 'x64' }) | Select-Object -First 1
    if ($null -eq $asset -or $asset.file -ne 'contexa-win-x64.exe' -or [string]::IsNullOrWhiteSpace($asset.sha256)) {
        throw 'Signed release manifest does not register a Windows x64 asset digest.'
    }

    if (Test-Path -LiteralPath $finalPath) {
        $installedVersion = Get-ReportedVersion $finalPath
        if ($installedVersion -eq $expectedCliVersion) {
            Test-BinarySmoke $finalPath $expectedCliVersion
            Ensure-CommandPath $installDir $finalPath
            Write-Host ('  Contexa ' + $version + ' is already installed; no file was replaced.') -ForegroundColor Green
            return
        }
    }

    $temporaryPath = Join-Path $installDir ('.contexa-' + [guid]::NewGuid().ToString('N') + '.new.exe')
    $oldMoved = $false
    try {
        $binaryBytes = Invoke-BoundedDownload ($releaseBase + '/' + $asset.file)
        [System.IO.File]::WriteAllBytes($temporaryPath, $binaryBytes)
        $sidecarText = (Convert-BytesToText (Invoke-BoundedDownload ($releaseBase + '/' + $asset.checksumFile))).Trim()
        $sidecarHash = $sidecarText.Split()[0].ToLowerInvariant()
        $manifestHash = ([string]$asset.sha256).ToLowerInvariant()
        $actualHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sidecarHash -ne $manifestHash -or $actualHash -ne $manifestHash) {
            throw 'Binary digest does not match the signed release manifest. The existing CLI was not changed.'
        }
        if ($asset.codeSignature -ne 'unsigned-snapshot') {
            throw ('Unsupported Windows code-signature contract: ' + $asset.codeSignature)
        }
        $signatureStatus = (Get-AuthenticodeSignature $temporaryPath).Status.ToString()
        if ($signatureStatus -ne 'NotSigned') { throw ('Windows code-signature contract mismatch: ' + $signatureStatus) }
        Test-BinarySmoke $temporaryPath $expectedCliVersion

        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
        if (Test-Path -LiteralPath $finalPath) {
            [System.IO.File]::Move($finalPath, $backupPath)
            $oldMoved = $true
        }
        [System.IO.File]::Move($temporaryPath, $finalPath)
        try {
            Test-BinarySmoke $finalPath $expectedCliVersion
        } catch {
            if (Test-Path -LiteralPath $finalPath) { Remove-Item -LiteralPath $finalPath -Force }
            if ($oldMoved -and (Test-Path -LiteralPath $backupPath)) { [System.IO.File]::Move($backupPath, $finalPath) }
            throw ('Final binary smoke failed; previous CLI was restored. ' + $_.Exception.Message)
        }
        Ensure-CommandPath $installDir $finalPath
        Write-Host ('  Contexa ' + $version + ' installed and verified.') -ForegroundColor Green
        Write-Host '  Primary commands:'
        Write-Host '    contexa init'
        Write-Host '    contexa reset'
        Write-Host '    contexa init --simulate'
        Write-Host '    contexa reset --simulate'
        Write-Host ('  Immutable reinstall: set CONTEXA_VERSION=' + $version + ' and run this installer again.')
        Write-Host '  Rollback: set CONTEXA_INSTALL_ACTION=rollback and run this installer.'
        Write-Host '  Uninstall: set CONTEXA_INSTALL_ACTION=uninstall and run this installer. Project reset is separate.'
    } catch {
        if ($oldMoved -and -not (Test-Path -LiteralPath $finalPath) -and (Test-Path -LiteralPath $backupPath)) {
            [System.IO.File]::Move($backupPath, $finalPath)
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

try {
    Invoke-ContexaInstaller
    exit 0
} catch {
    [Console]::Error.WriteLine('Contexa installer failed: ' + $_.Exception.Message)
    [Console]::Error.WriteLine('The existing CLI was preserved when possible. Fix the reported cause and run the same command again.')
    exit 1
} finally {
    $ProgressPreference = $script:OriginalProgressPreference
}
