#Requires -Version 5.1

& {
$DirectFileInvocation = -not [string]::IsNullOrWhiteSpace($PSCommandPath)
$InstallerFailed = $false
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# PowerShell 5.1 otherwise uses a legacy code page when stdout/stderr is
# redirected, corrupting Korean output consumed by CI and automation.
$OriginalConsoleOutputEncoding = [Console]::OutputEncoding
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

$OriginalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

$requestedLanguage = [Environment]::GetEnvironmentVariable('CONTEXA_LANG')
if ([string]::IsNullOrWhiteSpace($requestedLanguage)) {
    $requestedLanguage = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
}
$InstallerLanguage = if ($requestedLanguage -match '^(?i:ko)(?:[-_].*)?$') { 'ko' } else { 'en' }

function Select-InstallerText {
    param([string]$English, [string]$KoreanUtf8Base64)
    if ($InstallerLanguage -eq 'ko') {
        return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($KoreanUtf8Base64))
    }
    return $English
}

$Repository = 'contexa-security/contexa-cli'
$DefaultChannelManifestUrl = 'https://raw.githubusercontent.com/contexa-security/contexa-cli/snapshot-channel/channel-manifest.json'
$DefaultChannelSignatureUrl = 'https://raw.githubusercontent.com/contexa-security/contexa-cli/snapshot-channel/channel-manifest.json.sig'
$DefaultDownloadBase = 'https://github.com/contexa-security/contexa-cli/releases/download'
$PublicKeyXml = '<RSAKeyValue><Modulus>osHQvVy9S+AGAvskLk13njD9SoRHMURAbU2RQWZgQt2t0vN3Ib7aVMIwStGdJhaDIuPHTg0WrwM6ogPDDqfFmHHm8XkviBHnkgFQWvovLHtRudSgU6g+5ReaT0G0HsWFC3aGVJhOEwo5EqJJxZgjIc533CJTyn6ZbV8C0PGPP3kZQb1C/zPCaVtQg02v3Vm1C+sivBfCFRRJlcXhfc5hvbtB40DcRFkJfkBbdHBwdAnRfuH8OnIeL9dWEFyNgR7ZIREnjqNahtZbUM9gBS1p1Zw3ffTls2QSyMvQobqwNOdfP2/LN0K8uiJJ8K7nh524wGANdTlmKY2cAAkUbZsO2FK7sLCcVDXShQptXFj31DEzdQCb9hAnarXK5C6qBFxloDGzV8b+xlALFQBIO8xwXlxR8jZq+CiVJmWHUr78A0fubstaBUSgpU1ZzdUl0plI6MczU/udM7miH/O1ih7t0ox745ahU/7eXEYOLNRAJs2gidol7m+apyY/qV7DIMhz</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

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

function Get-TransportFailure {
    param([System.Exception]$Error)
    $current = $Error
    while ($null -ne $current) {
        if ($current -is [System.TimeoutException] -or $current -is [System.Net.WebException]) { return $current }
        $current = $current.InnerException
    }
    return $Error
}

function Test-RetryableWebFailure {
    param([System.Exception]$Error)
    $failure = Get-TransportFailure $Error
    if ($failure -is [System.TimeoutException]) { return $true }
    if ($failure -isnot [System.Net.WebException]) { return $false }
    if ($null -eq $failure.Response) { return $true }
    $statusCode = [int]$failure.Response.StatusCode
    return $statusCode -ge 500 -or $statusCode -eq 408 -or $statusCode -eq 429
}

function Get-WebFailureReason {
    param([System.Exception]$Error)
    $failure = Get-TransportFailure $Error
    if ($failure -is [System.TimeoutException]) { return 'TIMEOUT' }
    if ($failure -is [System.Net.WebException]) {
        if ($null -eq $failure.Response) {
            if ($failure.Status -eq [System.Net.WebExceptionStatus]::Timeout) { return 'TIMEOUT' }
            return 'CONNECTION_RESET'
        }
        if ($null -ne $failure.Response) {
            $statusCode = [int]$failure.Response.StatusCode
            if ($statusCode -eq 429) { return 'HTTP_429_RATE_LIMIT' }
            if ($statusCode -eq 408) { return 'HTTP_408_TIMEOUT' }
            if ($statusCode -ge 500) { return 'HTTP_5XX' }
            return ('HTTP_' + $statusCode)
        }
        if ($failure.Status -eq [System.Net.WebExceptionStatus]::ConnectionClosed -or
            $failure.Status -eq [System.Net.WebExceptionStatus]::ReceiveFailure -or
            $failure.Status -eq [System.Net.WebExceptionStatus]::SendFailure -or
            $failure.Status -eq [System.Net.WebExceptionStatus]::ConnectFailure) {
            return 'CONNECTION_RESET'
        }
    }
    return 'NON_RETRYABLE'
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
            $request.KeepAlive = $false
            $request.Pipelined = $false
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
            if (-not $retryable -or $attempt -gt $retryCount -or [DateTime]::UtcNow -ge $deadline) {
                $reason = Get-WebFailureReason $lastError
                $guidance = if ($reason -eq 'HTTP_429_RATE_LIMIT') {
                    'The signed channel was rate-limited. Retry the same installer after the server retry window.'
                } elseif ($retryable) {
                    'The remote endpoint was temporarily unavailable. Retry the same installer.'
                } else {
                    'Check the URL and trust configuration before retrying the same installer.'
                }
                $message = 'HTTP download failed [' + $reason + '] after ' + $attempt +
                    ' attempt(s) within ' + $totalTimeout + ' second(s): ' + $Uri + '. ' + $guidance
                throw [System.IO.IOException]::new($message, $lastError)
            }
            Start-Sleep -Milliseconds 250
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($response) { $response.Dispose() }
            if ($memory) { $memory.Dispose() }
        }
    }
    $reason = Get-WebFailureReason $lastError
    throw [System.IO.IOException]::new(('HTTP download failed [' + $reason + ']: ' + $Uri), $lastError)
}

function Convert-BytesToText {
    param([byte[]]$Bytes)
    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Get-TrustedPublicKeyXml {
    param([string]$DownloadBase)
    if ([string]::IsNullOrWhiteSpace($env:CONTEXA_TRUSTED_PUBLIC_KEY_XML)) {
        return $PublicKeyXml
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

function Get-TargetRelease {
    param([string]$DownloadBase)
    if (-not [string]::IsNullOrWhiteSpace($env:CONTEXA_VERSION)) {
        $version = $env:CONTEXA_VERSION.Trim()
        if ($version -notmatch '^v[0-9A-Za-z][0-9A-Za-z._-]*$') { throw ('Invalid or empty release tag: ' + $version) }
        return [pscustomobject]@{
            ReleaseTag = $version
            CliVersion = $version.Substring(1)
            Channel = $null
            StarterVersion = $null
            ReleaseManifestSha256 = $null
        }
    }

    $manifestUrl = if ([string]::IsNullOrWhiteSpace($env:CONTEXA_CHANNEL_MANIFEST_URL)) {
        $DefaultChannelManifestUrl
    } else { $env:CONTEXA_CHANNEL_MANIFEST_URL.Trim() }
    $signatureUrl = if ([string]::IsNullOrWhiteSpace($env:CONTEXA_CHANNEL_SIGNATURE_URL)) {
        $DefaultChannelSignatureUrl
    } else { $env:CONTEXA_CHANNEL_SIGNATURE_URL.Trim() }
    $manifestBytes = Invoke-BoundedDownload $manifestUrl
    $signatureBytes = Invoke-BoundedDownload $signatureUrl
    Test-ReleaseManifestSignature $manifestBytes $signatureBytes (Get-TrustedPublicKeyXml $DownloadBase)
    $channelManifest = Convert-BytesToText $manifestBytes | ConvertFrom-Json
    $version = [string]$channelManifest.releaseTag
    $cliVersion = [string]$channelManifest.cliVersion
    $starterVersion = [string]$channelManifest.starterVersion
    $sourceCommit = [string]$channelManifest.sourceCommit
    $releaseManifestSha256 = [string]$channelManifest.releaseManifestSha256
    if ($channelManifest.schemaVersion -ne 1 -or $channelManifest.channel -ne 'snapshot') {
        throw 'Signed channel manifest schema or channel is unsupported.'
    }
    if ($version -notmatch '^v[0-9A-Za-z][0-9A-Za-z._-]*$' -or $cliVersion -ne $version.Substring(1)) {
        throw 'Signed channel manifest tag and CLI version do not match.'
    }
    if ($starterVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$') {
        throw 'Signed channel manifest starter version is invalid.'
    }
    if ($releaseManifestSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Signed channel manifest release digest is invalid.'
    }
    if ($sourceCommit -notmatch '^[0-9a-f]{40}$') {
        throw 'Signed channel manifest source commit is invalid.'
    }
    return [pscustomobject]@{
        ReleaseTag = $version
        CliVersion = $cliVersion
        Channel = 'snapshot'
        StarterVersion = $starterVersion
        SourceCommit = $sourceCommit
        ReleaseManifestSha256 = $releaseManifestSha256
    }
}

function Get-ReportedVersion {
    param([string]$Binary)
    $output = & $Binary --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('Binary version check failed: ' + $Binary) }
    return ($output | Select-Object -First 1).ToString().Trim()
}

function Get-Sha256FileHex {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-Sha256BytesHex {
    param([byte[]]$Bytes)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Assert-UnsignedAuthenticodeFile {
    param([string]$Path)
    $modulePath = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ('Windows Authenticode verifier module is missing: ' + $modulePath)
    }
    Import-Module -Name $modulePath -ErrorAction Stop
    $signatureStatus = (Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path).Status.ToString()
    if ($signatureStatus -ne 'NotSigned') {
        throw ('Windows code-signature contract mismatch: ' + $signatureStatus)
    }
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

function Test-BinaryHealthy {
    param([string]$Binary, [string]$ExpectedVersion = '')
    if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) { return $false }
    try {
        $version = Get-ReportedVersion $Binary
        if ([string]::IsNullOrWhiteSpace($version)) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $version -ne $ExpectedVersion) { return $false }
        & $Binary --help *> $null
        if ($LASTEXITCODE -ne 0) { return $false }
        & $Binary *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Write-InstallerTransaction {
    param(
        [string]$MarkerPath,
        [string]$State,
        [string]$FinalPath,
        [string]$BackupPath,
        [string]$NewPath,
        [string]$ExpectedVersion,
        [bool]$HadOriginal
    )
    $validStates = @('DOWNLOADED', 'VERIFIED', 'OLD_MOVED', 'NEW_MOVED', 'SMOKE_PASSED')
    if ($validStates -notcontains $State) { throw ('Unsupported installer transaction state: ' + $State) }
    $transaction = [ordered]@{
        schemaVersion = 1
        state = $State
        finalPath = [System.IO.Path]::GetFullPath($FinalPath)
        backupPath = [System.IO.Path]::GetFullPath($BackupPath)
        newPath = [System.IO.Path]::GetFullPath($NewPath)
        expectedVersion = $ExpectedVersion
        hadOriginal = $HadOriginal
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
    $writingPath = $MarkerPath + '.writing'
    $replacedPath = $MarkerPath + '.replaced'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($writingPath, ($transaction | ConvertTo-Json -Compress), $utf8)
    if (Test-Path -LiteralPath $MarkerPath) {
        if (Test-Path -LiteralPath $replacedPath) { Remove-Item -LiteralPath $replacedPath -Force }
        [System.IO.File]::Replace($writingPath, $MarkerPath, $replacedPath)
        if (Test-Path -LiteralPath $replacedPath) { Remove-Item -LiteralPath $replacedPath -Force }
    } else {
        [System.IO.File]::Move($writingPath, $MarkerPath)
    }
}

function Remove-InstallerTransaction {
    param([string]$MarkerPath)
    if (Test-Path -LiteralPath $MarkerPath) { Remove-Item -LiteralPath $MarkerPath -Force }
    $writingPath = $MarkerPath + '.writing'
    if (Test-Path -LiteralPath $writingPath) { Remove-Item -LiteralPath $writingPath -Force }
    $replacedPath = $MarkerPath + '.replaced'
    if (Test-Path -LiteralPath $replacedPath) { Remove-Item -LiteralPath $replacedPath -Force }
}

function Invoke-InstallerTransactionRecovery {
    param([string]$InstallDir, [string]$FinalPath, [string]$BackupPath, [string]$MarkerPath)
    $writingPath = $MarkerPath + '.writing'
    $replacedPath = $MarkerPath + '.replaced'
    if (-not (Test-Path -LiteralPath $MarkerPath) -and (Test-Path -LiteralPath $replacedPath)) {
        [System.IO.File]::Move($replacedPath, $MarkerPath)
    }
    if (-not (Test-Path -LiteralPath $MarkerPath)) {
        if (Test-Path -LiteralPath $writingPath) { Remove-Item -LiteralPath $writingPath -Force }
        return
    }

    try {
        $transaction = Get-Content -LiteralPath $MarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw ('Installer transaction marker is unreadable and was retained: ' + $MarkerPath)
    }
    $validStates = @('DOWNLOADED', 'VERIFIED', 'OLD_MOVED', 'NEW_MOVED', 'SMOKE_PASSED')
    $expectedFinal = [System.IO.Path]::GetFullPath($FinalPath)
    $expectedBackup = [System.IO.Path]::GetFullPath($BackupPath)
    $recordedFinal = [System.IO.Path]::GetFullPath([string]$transaction.finalPath)
    $recordedBackup = [System.IO.Path]::GetFullPath([string]$transaction.backupPath)
    $newPath = [System.IO.Path]::GetFullPath([string]$transaction.newPath)
    $rootPrefix = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\') + '\'
    $newName = [System.IO.Path]::GetFileName($newPath)
    if ($transaction.schemaVersion -ne 1 -or $validStates -notcontains [string]$transaction.state -or
        -not $recordedFinal.Equals($expectedFinal, [StringComparison]::OrdinalIgnoreCase) -or
        -not $recordedBackup.Equals($expectedBackup, [StringComparison]::OrdinalIgnoreCase) -or
        -not $newPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $newName -notmatch '^\.contexa-[0-9a-f]{32}\.new\.exe$' -or
        [string]::IsNullOrWhiteSpace([string]$transaction.expectedVersion)) {
        throw ('Installer transaction marker violates the exact path/state contract and was retained: ' + $MarkerPath)
    }

    $state = [string]$transaction.state
    $expectedVersion = [string]$transaction.expectedVersion
    if (Test-BinaryHealthy $FinalPath) {
        if (Test-Path -LiteralPath $newPath) { Remove-Item -LiteralPath $newPath -Force }
        Remove-InstallerTransaction $MarkerPath
        return
    }

    $newWasVerified = @('VERIFIED', 'OLD_MOVED') -contains $state
    if ($newWasVerified -and (Test-BinaryHealthy $newPath $expectedVersion)) {
        if (Test-Path -LiteralPath $FinalPath) {
            $quarantine = $FinalPath + '.failed-' + [guid]::NewGuid().ToString('N')
            [System.IO.File]::Move($FinalPath, $quarantine)
        }
        [System.IO.File]::Move($newPath, $FinalPath)
        Test-BinarySmoke $FinalPath $expectedVersion
        Remove-InstallerTransaction $MarkerPath
        return
    }

    if (Test-BinaryHealthy $BackupPath) {
        if (Test-Path -LiteralPath $FinalPath) {
            $quarantine = $FinalPath + '.failed-' + [guid]::NewGuid().ToString('N')
            [System.IO.File]::Move($FinalPath, $quarantine)
        }
        [System.IO.File]::Move($BackupPath, $FinalPath)
        if (Test-Path -LiteralPath $newPath) { Remove-Item -LiteralPath $newPath -Force }
        Remove-InstallerTransaction $MarkerPath
        return
    }

    throw ('Installer recovery found no verified healthy old or new binary. The marker and files were retained: ' + $MarkerPath)
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
        Write-Warning ((Select-InstallerText 'Another contexa command remains on PATH and was not deleted: ' 'UEFUSOyXkCDri6TrpbggY29udGV4YSDrqoXroLnsnbQg64Ko7JWEIOyeiOycvOupsCDsgq3soJztlZjsp4Ag7JWK7JWY7Iq164uI64ukOiA=') + $conflict.Source)
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
        Write-Host ('  ' + (Select-InstallerText 'Rolled back Contexa CLI to ' 'Q29udGV4YSBDTEnrpbwg64uk7J2MIOuyhOyghOycvOuhnCDroaTrsLHtlojsirXri4jri6Q6IA==') + $version) -ForegroundColor Green
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
    Write-Host ('  ' + (Select-InstallerText 'Contexa CLI binary and installer-owned PATH entry were removed. Project files were not changed.' 'Q29udGV4YSBDTEkg67CU7J2064SI66as7JmAIOyEpOy5mCDtlITroZzqt7jrnqgg7IaM7JygIFBBVEgg7ZWt66qp7J2EIOygnOqxsO2WiOyKteuLiOuLpC4g7ZSE66Gc7KCd7Yq4IO2MjOydvOydgCDrs4Dqsr3tlZjsp4Ag7JWK7JWY7Iq164uI64ukLg==')) -ForegroundColor Green
}

function Invoke-ContexaInstaller {
    Assert-WindowsX64
    $installDir = Get-InstallDirectory
    $finalPath = Join-Path $installDir 'contexa.exe'
    $backupPath = $finalPath + '.previous'
    $markerPath = $finalPath + '.install-transaction.json'
    $action = if ([string]::IsNullOrWhiteSpace($env:CONTEXA_INSTALL_ACTION)) { 'install' } else { $env:CONTEXA_INSTALL_ACTION.Trim().ToLowerInvariant() }

    if (-not (Test-Path -LiteralPath $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
    Invoke-InstallerTransactionRecovery $installDir $finalPath $backupPath $markerPath
    if ($action -eq 'rollback') { Invoke-Rollback $finalPath $backupPath; Ensure-CommandPath $installDir $finalPath; return }
    if ($action -eq 'uninstall') { Invoke-Uninstall $installDir $finalPath $backupPath; return }
    if ($action -ne 'install') {
        throw ((Select-InstallerText 'Unsupported CONTEXA_INSTALL_ACTION' '7KeA7JuQ7ZWY7KeAIOyViuuKlCBDT05URVhBX0lOU1RBTExfQUNUSU9O') + ': ' + $action)
    }

    Write-Host ('  ' + (Select-InstallerText 'Starting Contexa CLI installation.' 'Q29udGV4YSBDTEkg7ISk7LmY66W8IOyLnOyeke2VqeuLiOuLpC4='))
    $downloadBase = if ([string]::IsNullOrWhiteSpace($env:CONTEXA_RELEASE_DOWNLOAD_BASE)) { $DefaultDownloadBase } else { $env:CONTEXA_RELEASE_DOWNLOAD_BASE.TrimEnd('/') }
    $targetRelease = Get-TargetRelease $downloadBase
    $version = $targetRelease.ReleaseTag
    $expectedCliVersion = $targetRelease.CliVersion
    $releaseBase = $downloadBase + '/' + $version
    Write-Host ('  ' + ((Select-InstallerText 'Release {0} found. Checking authenticity...' '66a066as7IqkIHswfeydhCDtmZXsnbjtlojsirXri4jri6QuIOyLoOuisOyEseydhCDqsoDspp3tlZjripQg7KSR7J6F64uI64ukLi4u') -f $version))

    $manifestBytes = Invoke-BoundedDownload ($releaseBase + '/release-manifest.json')
    $signatureBytes = Invoke-BoundedDownload ($releaseBase + '/release-manifest.json.sig')
    Test-ReleaseManifestSignature $manifestBytes $signatureBytes (Get-TrustedPublicKeyXml $downloadBase)
    $manifest = Convert-BytesToText $manifestBytes | ConvertFrom-Json
    if ($manifest.releaseTag -ne $version -or $manifest.cliVersion -ne $expectedCliVersion) {
        throw 'Signed release manifest does not match the requested tag and CLI version.'
    }
    $releaseSchemaVersion = [int]$manifest.schemaVersion
    if ($releaseSchemaVersion -notin @(1, 2)) {
        throw 'Signed release manifest schema is unsupported.'
    }
    $sourceRepository = ''
    $sourceCommit = ''
    $sourceProperty = $manifest.PSObject.Properties['source']
    if ($null -ne $sourceProperty -and $null -ne $sourceProperty.Value) {
        $repositoryProperty = $sourceProperty.Value.PSObject.Properties['repository']
        $commitProperty = $sourceProperty.Value.PSObject.Properties['commit']
        if ($null -ne $repositoryProperty) { $sourceRepository = [string]$repositoryProperty.Value }
        if ($null -ne $commitProperty) { $sourceCommit = [string]$commitProperty.Value }
    }
    if ($releaseSchemaVersion -eq 2 -or -not [string]::IsNullOrWhiteSpace($sourceRepository + $sourceCommit)) {
        if ($sourceRepository -ne 'contexa-security/contexa-cli' -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
            throw 'Signed release manifest source provenance is invalid.'
        }
    }
    if ($null -ne $targetRelease.Channel -and $releaseSchemaVersion -ne 2) {
        throw 'Signed channel requires release manifest schema 2.'
    }
    if ($null -ne $targetRelease.Channel -and $sourceCommit -ne $targetRelease.SourceCommit) {
        throw 'Signed release manifest source commit does not match the signed channel.'
    }
    if ($null -ne $targetRelease.Channel -and ($manifest.channel -ne $targetRelease.Channel -or $manifest.starter.version -ne $targetRelease.StarterVersion)) {
        throw 'Signed release manifest does not match the signed channel and starter version.'
    }
    if ($null -ne $targetRelease.Channel -and (Get-Sha256BytesHex $manifestBytes) -ne $targetRelease.ReleaseManifestSha256) {
        throw 'Signed release manifest digest does not match the signed channel.'
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
            Write-Host ('  Contexa ' + $version + (Select-InstallerText ' is already installed; no file was replaced.' 'IOuyhOyghOydtCDsnbTrr7gg7ISk7LmY65CY7Ja0IOyeiOyWtCDtjIzsnbzsnYQg6rWQ7LK07ZWY7KeAIOyViuyVmOyKteuLiOuLpC4=')) -ForegroundColor Green
            return
        }
    }

    $temporaryPath = Join-Path $installDir ('.contexa-' + [guid]::NewGuid().ToString('N') + '.new.exe')
    $oldMoved = $false
    $hadOriginal = Test-Path -LiteralPath $finalPath -PathType Leaf
    $replacementStarted = $false
    try {
        Write-Host ('  ' + (Select-InstallerText 'Downloading Contexa CLI and verifying the file...' 'Q29udGV4YSBDTEnrpbwg64uk7Jq066Gc65Oc7ZWY6rOgIO2MjOydvCDrrLTqsrDshLHsnYQg6rKA7Kad7ZWY64qUIOykkeyeheuLiOuLpC4uLg=='))
        $binaryBytes = Invoke-BoundedDownload ($releaseBase + '/' + $asset.file)
        [System.IO.File]::WriteAllBytes($temporaryPath, $binaryBytes)
        Write-InstallerTransaction $markerPath 'DOWNLOADED' $finalPath $backupPath $temporaryPath $expectedCliVersion $hadOriginal
        $sidecarText = (Convert-BytesToText (Invoke-BoundedDownload ($releaseBase + '/' + $asset.checksumFile))).Trim()
        $sidecarHash = $sidecarText.Split()[0].ToLowerInvariant()
        $manifestHash = ([string]$asset.sha256).ToLowerInvariant()
        $actualHash = Get-Sha256FileHex $temporaryPath
        if ($sidecarHash -ne $manifestHash -or $actualHash -ne $manifestHash) {
            throw 'Binary digest does not match the signed release manifest. The existing CLI was not changed.'
        }
        if ($asset.codeSignature -ne 'unsigned-snapshot') {
            throw ('Unsupported Windows code-signature contract: ' + $asset.codeSignature)
        }
        Assert-UnsignedAuthenticodeFile $temporaryPath
        Test-BinarySmoke $temporaryPath $expectedCliVersion
        Write-InstallerTransaction $markerPath 'VERIFIED' $finalPath $backupPath $temporaryPath $expectedCliVersion $hadOriginal

        $replacementStarted = $true
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
        if (Test-Path -LiteralPath $finalPath) {
            [System.IO.File]::Move($finalPath, $backupPath)
            $oldMoved = $true
        }
        Write-InstallerTransaction $markerPath 'OLD_MOVED' $finalPath $backupPath $temporaryPath $expectedCliVersion $hadOriginal
        [System.IO.File]::Move($temporaryPath, $finalPath)
        Write-InstallerTransaction $markerPath 'NEW_MOVED' $finalPath $backupPath $temporaryPath $expectedCliVersion $hadOriginal
        try {
            Test-BinarySmoke $finalPath $expectedCliVersion
        } catch {
            if (Test-Path -LiteralPath $finalPath) { Remove-Item -LiteralPath $finalPath -Force }
            if ($oldMoved -and (Test-Path -LiteralPath $backupPath)) { [System.IO.File]::Move($backupPath, $finalPath) }
            throw ('Final binary smoke failed; previous CLI was restored. ' + $_.Exception.Message)
        }
        Write-InstallerTransaction $markerPath 'SMOKE_PASSED' $finalPath $backupPath $temporaryPath $expectedCliVersion $hadOriginal
        Ensure-CommandPath $installDir $finalPath
        Remove-InstallerTransaction $markerPath
        Write-Host ('  Contexa ' + $version + (Select-InstallerText ' installed and verified.' 'IOyEpOy5mOyZgCDqsoDspp3snYQg7JmE66OM7ZaI7Iq164uI64ukLg==')) -ForegroundColor Green
        Write-Host ('  ' + (Select-InstallerText 'Primary commands:' '7KO87JqUIOuqheuguTo='))
        Write-Host '    contexa init'
        Write-Host '    contexa reset'
        Write-Host '    contexa init --simulate'
        Write-Host '    contexa reset --simulate'
        Write-Host ('  ' + (Select-InstallerText 'Immutable reinstall: set CONTEXA_VERSION=' '64+Z7J28IOuyhOyghCDsnqzshKTsuZg6IENPTlRFWEFfVkVSU0lPTj0=') + $version + (Select-InstallerText ' and run this installer again.' '7J2EIOyEpOygle2VmOqzoCDshKTsuZgg7ZSE66Gc6re4656o7J2EIOuLpOyLnCDsi6TtlontlZjshLjsmpQu'))
        Write-Host ('  ' + (Select-InstallerText 'Rollback: set CONTEXA_INSTALL_ACTION=rollback and run this installer.' '66Gk67CxOiBDT05URVhBX0lOU1RBTExfQUNUSU9OPXJvbGxiYWNr7J2EIOyEpOygle2VmOqzoCDshKTsuZgg7ZSE66Gc6re4656o7J2EIOyLpO2Wie2VmOyEuOyalC4='))
        Write-Host ('  ' + (Select-InstallerText 'Uninstall: irm https://install.ctxa.ai/uninstall.ps1 | iex (project reset is separate).' '7KCc6rGwOiBpcm0gaHR0cHM6Ly9pbnN0YWxsLmN0eGEuYWkvdW5pbnN0YWxsLnBzMSB8IGlleCAo7ZSE66Gc7KCd7Yq4IHJlc2V07J2AIOuzhOuPhCk='))
    } catch {
        if ($oldMoved -and -not (Test-Path -LiteralPath $finalPath) -and (Test-Path -LiteralPath $backupPath)) {
            [System.IO.File]::Move($backupPath, $finalPath)
        }
        if ((-not $replacementStarted) -or (Test-BinaryHealthy $finalPath)) {
            Remove-InstallerTransaction $markerPath
        }
        throw
    } finally {
        if (-not (Test-Path -LiteralPath $markerPath) -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Invoke-ContexaInstaller
} catch {
    $InstallerFailed = $true
    $failureCode = 'INSTALLER_OPERATION_FAILED'
    if ($_.Exception.Message -match '\[([A-Z][A-Z0-9_]+)\]') {
        $failureCode = $Matches[1]
    }
    if ($InstallerLanguage -eq 'ko') {
        $failureSummary =
            'Contexa ' +
            (Select-InstallerText 'installer failed [' '7ISk7LmYIO2UhOuhnOq3uOueqCDsi6TtjKggWw==') +
            $failureCode +
            (Select-InstallerText ']: Check the error code, fix the cause, and run the same command again.' 'XTog7Jik66WYIOy9lOuTnOulvCDtmZXsnbjtlZjqs6Ag7JuQ7J247J2EIOyImOygle2VnCDrkqQg6rCZ7J2AIOuqheugueydhCDri6Tsi5wg7Iuk7ZaJ7ZWY7IS47JqULg==')
    } else {
        $failureSummary = 'Contexa installer failed [' + $failureCode + ']: ' + $_.Exception.Message
    }
    $preservationMessage = Select-InstallerText 'The existing CLI was preserved when possible. Fix the reported cause and run the same command again.' '6rCA64ql7ZWcIOqyveyasCDquLDsobQgQ0xJ66W8IOuztOyhtO2WiOyKteuLiOuLpC4g67O06rOg65CcIOybkOyduOydhCDtlbTqsrDtlZwg65KkIOqwmeydgCDrqoXroLnsnYQg64uk7IucIOyLpO2Wie2VmOyEuOyalC4='
    [Console]::Error.WriteLine($failureSummary)
    [Console]::Error.WriteLine($preservationMessage)
    throw [System.InvalidOperationException]::new(
        ('Contexa installer failed [' + $failureCode + '].'),
        $_.Exception
    )
} finally {
    $ProgressPreference = $OriginalProgressPreference
    if (-not $InstallerFailed -or -not $DirectFileInvocation) {
        [Console]::OutputEncoding = $OriginalConsoleOutputEncoding
    }
}
}