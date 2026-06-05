#Requires -Version 5.1
<#
.SYNOPSIS
  Contexa CLI installer for Windows (PowerShell).

.DESCRIPTION
  Downloads the latest contexa-win-x64.exe release from GitHub, verifies it
  against the published SHA-256 digest, installs it under
  %LOCALAPPDATA%\Programs\Contexa, and adds that directory to the user PATH.

.NOTES
  Requires PowerShell 5.1 or later.
  Run with: irm https://install.ctxa.ai/install.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

# Force TLS 1.2 - PowerShell 5.x defaults to TLS 1.0 which GitHub rejects.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Pin console output to UTF-8 for the duration of this script so the banner's
# box-drawing characters (█ ╗ ═ ║ ...) render correctly under PowerShell 5.x
# on Korean Windows, which otherwise defaults the console to cp949 and turns
# every utf-8 byte > 0x7F into mojibake (the user reports seeing 'â').
# We restore the original encoding in the trailing finalizer below.
$script:OriginalConsoleOutputEncoding = $null
try {
    $script:OriginalConsoleOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# Suppress PowerShell's built-in Invoke-WebRequest progress UI. On localized
# Windows it renders as "요청 스트림을 쓰는 중...(쓴 바이트 수: 17933446)"
# which is illegible (raw bytes, no total, no percentage). We replace it with
# a short, human-readable size line printed by Format-Bytes below.
$script:OriginalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

$Repo       = 'contexa-security/contexa-cli'
$BinaryName = 'contexa-win-x64.exe'

# Resolve a base directory for installation. LOCALAPPDATA is the standard
# location, but service accounts and minimal CI environments may have it
# unset; fall back to USERPROFILE\AppData\Local before giving up.
$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $LocalAppData = Join-Path $env:USERPROFILE 'AppData\Local'
}
if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
    Write-Host '  Error: cannot resolve a writable installation directory.' -ForegroundColor Red
    Write-Host '         Both LOCALAPPDATA and USERPROFILE are empty.'      -ForegroundColor Red
    return
}

$InstallDir = Join-Path $LocalAppData 'Programs\Contexa'
$FinalPath  = Join-Path $InstallDir 'contexa.exe'

# Banner. The box-drawing glyphs render correctly on three layers:
#   1) Vercel serves install.ps1 with Content-Type charset=utf-8 (vercel.json),
#      so Invoke-RestMethod decodes the bytes as utf-8 instead of ISO-8859-1.
#   2) Above we pinned [Console]::OutputEncoding = UTF8 so Write-Host emits
#      utf-8 bytes the conhost can interpret correctly.
#   3) Modern Windows Terminal / PowerShell 7 ships with Cascadia Mono which
#      includes every glyph below. Old conhost raster fonts may still drop
#      a glyph or two; for that small population we recommend Windows Terminal
#      in the install guide rather than further degrade the banner here.
Write-Host ''
Write-Host '  ░█████╗░░█████╗░███╗░░██╗████████╗███████╗██╗░░██╗░█████╗░' -ForegroundColor Cyan
Write-Host '  ██╔══██╗██╔══██╗████╗░██║╚══██╔══╝██╔════╝╚██╗██╔╝██╔══██╗' -ForegroundColor Cyan
Write-Host '  ██║░░╚═╝██║░░██║██╔██╗██║░░░██║░░░█████╗░░░╚███╔╝░███████║' -ForegroundColor Cyan
Write-Host '  ██║░░██╗██║░░██║██║╚████║░░░██║░░░██╔══╝░░░██╔██╗░██╔══██║' -ForegroundColor Cyan
Write-Host '  ╚█████╔╝╚█████╔╝██║░╚███║░░░██║░░░███████╗██╔╝░██╗██║░░██║' -ForegroundColor Cyan
Write-Host '  ░╚════╝░░╚════╝░╚═╝░░╚══╝░░░╚═╝░░░╚══════╝╚═╝░░╚═╝╚═╝░░╚═╝' -ForegroundColor Cyan
Write-Host ''
Write-Host '  AI-Native Zero Trust Security Platform   https://ctxa.ai' -ForegroundColor Yellow
Write-Host ''

# Pre-flight check for installer
Write-Host '  Running pre-flight environment checks...' -ForegroundColor DarkGray
$CheckPass = $true

# Check Java 17+
$javaInstalled = $false
$javaVersionOk = $false
$detectedJavaVer = 'unknown'

if (Get-Command java -ErrorAction SilentlyContinue) {
    $javaInstalled = $true
    try {
        # Capture stderr and stdout as array of lines using cmd to prevent PowerShell ErrorActionStop trigger on stderr
        $javaLines = cmd /c "java -version 2>&1"
        foreach ($line in $javaLines) {
            $lineStr = $line.ToString()
            if ($lineStr -match 'version "([^"]+)"' -or $lineStr -match 'openjdk version "([^"]+)"') {
                $fullVer = $Matches[1]
                if ($fullVer -match '^1\.([0-9]+)') {
                    $detectedJavaVer = [int]$Matches[1]
                } elseif ($fullVer -match '^([0-9]+)') {
                    $detectedJavaVer = [int]$Matches[1]
                }
                if ($detectedJavaVer -ge 17) {
                    $javaVersionOk = $true
                }
                break
            }
        }
    } catch { }
}

if (-not $javaVersionOk) {
    if ($javaInstalled) {
        Write-Host "  ! Java 17+ was not detected (detected: $detectedJavaVer)" -ForegroundColor Yellow
    } else {
        Write-Host '  ! Java is not installed on this machine.' -ForegroundColor Yellow
    }
    $CheckPass = $false
}

# Check Docker
$dockerInstalled = $false
$dockerRunning = $false

if (Get-Command docker -ErrorAction SilentlyContinue) {
    $dockerInstalled = $true
    try {
        & docker ps > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            $dockerRunning = $true
        }
    } catch { }
}

if (-not $dockerRunning) {
    if ($dockerInstalled) {
        Write-Host '  ! Docker daemon is not running.' -ForegroundColor Yellow
    } else {
        Write-Host '  ! Docker CLI is not installed.' -ForegroundColor Yellow
    }
    $CheckPass = $false
}

if (-not $CheckPass) {
    Write-Host ''
    Write-Host '  Some dependencies are missing. However, you can still install Contexa CLI' -ForegroundColor White
    Write-Host '  to configure your Spring project using Standalone/Skip mode.' -ForegroundColor White
    
    $interactive = $true
    try {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
            $interactive = $false
        }
    } catch {
        $interactive = $false
    }

    $continueInstall = 'y'
    if ($interactive) {
        $promptAns = Read-Host '  Would you like to proceed with the CLI installation anyway? (y/n)'
        $continueInstall = $promptAns.Trim().ToLower()
    } else {
        Write-Host ''
        Write-Host '  Non-interactive shell detected. Proceeding with installation automatically...' -ForegroundColor DarkGray
    }

    if ($continueInstall -ne 'y' -and $continueInstall -ne 'yes') {
        Write-Host ''
        Write-Host '  Installation aborted by user.' -ForegroundColor Red
        Write-Host '  - To install JDK 17:  https://adoptium.net'
        Write-Host '  - To install Docker:  https://docs.docker.com/engine/install/'
        Write-Host ''
        
        $ProgressPreference = $script:OriginalProgressPreference
        if ($script:OriginalConsoleOutputEncoding) {
            try { [Console]::OutputEncoding = $script:OriginalConsoleOutputEncoding } catch { }
        }
        return
    }
} else {
    Write-Host '  Pre-flight environment checks passed.' -ForegroundColor Green
    Write-Host ''
}

# Resolve latest release tag from GitHub.
$version = 'v0.1.0'
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
    if ($release -and $release.tag_name) {
        $version = $release.tag_name
    }
} catch {
    Write-Host "  Warning: could not fetch latest release info from GitHub. Falling back to default version: $version" -ForegroundColor Yellow
}

if ([string]::IsNullOrWhiteSpace($version)) {
    Write-Host '  Error: empty version tag from GitHub API.' -ForegroundColor Red
    return
}

$downloadUrl = "https://github.com/$Repo/releases/download/$version/$BinaryName"
$shaUrl      = "$downloadUrl.sha256"

# Info box
Write-Host "  Version  : $version"      -ForegroundColor White
Write-Host "  Platform : Windows x64"   -ForegroundColor White
Write-Host "  Target   : $FinalPath"    -ForegroundColor DarkGray
Write-Host ''

# Prepare install directory.
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

# Download to a temporary path; verify before promoting it.
$tempBin = [System.IO.Path]::GetTempFileName()
$tempSha = "$tempBin.sha256"

try {
    # Resolve expected size with a HEAD request so we can show a meaningful
    # "Downloading 87.3 MB..." line up front - the user otherwise has no
    # idea whether the download is 1 MB or 1 GB.
    $expectedSize = $null
    try {
        $headResp = Invoke-WebRequest -Uri $downloadUrl -Method Head -UseBasicParsing -ErrorAction Stop
        if ($headResp.Headers.'Content-Length') {
            $expectedSize = [long]$headResp.Headers.'Content-Length'
        }
    } catch { }

    if ($expectedSize) {
        Write-Host ("  Downloading {0}..." -f (Format-Bytes $expectedSize)) -ForegroundColor DarkGray
    } else {
        Write-Host '  Downloading...' -ForegroundColor DarkGray
    }

    $usingLocalFallback = $false
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempBin -UseBasicParsing
        
        # Report actual downloaded size on completion.
        $actualSize = (Get-Item $tempBin).Length
        Write-Host ("  Downloaded {0}." -f (Format-Bytes $actualSize)) -ForegroundColor Green
    } catch {
        Write-Host '  GitHub download failed. Searching for local build fallback...' -ForegroundColor Yellow
        $localBuildPath = 'E:\projects\contexa-cli\dist\contexa-win-x64.exe'
        if (Test-Path $localBuildPath) {
            Copy-Item -Path $localBuildPath -Destination $tempBin -Force
            $actualSize = (Get-Item $tempBin).Length
            Write-Host ("  Found and copied local build fallback ({0}) from $localBuildPath" -f (Format-Bytes $actualSize)) -ForegroundColor Green
            $usingLocalFallback = $true
        } else {
            Write-Host "  Error: GitHub download failed and no local build found at $localBuildPath" -ForegroundColor Red
            Write-Host "  $_" -ForegroundColor Red
            return
        }
    }

    if (-not $usingLocalFallback) {
        # Fetch SHA-256 sidecar
        Write-Host '  Verifying checksum...' -ForegroundColor DarkGray
        try {
            Invoke-WebRequest -Uri $shaUrl -OutFile $tempSha -UseBasicParsing
        } catch {
            Write-Host "  Error: checksum file not found at $shaUrl" -ForegroundColor Red
            Write-Host '  Refusing to install an unverified binary.' -ForegroundColor Red
            return
        }

        $expected = (Get-Content $tempSha -Raw).Trim().Split()[0]
        if ([string]::IsNullOrWhiteSpace($expected)) {
            Write-Host '  Error: empty checksum file.' -ForegroundColor Red
            return
        }

        $actual = (Get-FileHash -Path $tempBin -Algorithm SHA256).Hash.ToLower()
        if ($expected.ToLower() -ne $actual) {
            Write-Host '  Error: checksum mismatch.' -ForegroundColor Red
            Write-Host "    expected: $expected" -ForegroundColor Red
            Write-Host "    actual  : $actual"   -ForegroundColor Red
            Write-Host '  Refusing to install a tampered binary.' -ForegroundColor Red
            return
        }

        Write-Host '  Checksum verified.' -ForegroundColor Green
    } else {
        Write-Host '  Skipping checksum verification for local fallback build.' -ForegroundColor Yellow
    }

    # Promote the verified binary to its final location. Windows holds a hard
    # lock on running .exe files, so a self-upgrade while contexa is open
    # cannot succeed - report it explicitly instead of bubbling a confusing
    # IOException.
    try {
        Move-Item -Force -Path $tempBin -Destination $FinalPath
    } catch [System.IO.IOException] {
        Write-Host ''
        Write-Host "  Error: could not write $FinalPath" -ForegroundColor Red
        Write-Host '         The existing contexa.exe is in use by another process.' -ForegroundColor Red
        Write-Host '         Close any running contexa session and re-run this installer.' -ForegroundColor Red
        return
    }
} finally {
    # Always clean up temp artifacts, even on failure.
    if (Test-Path $tempBin) { Remove-Item -Force $tempBin -ErrorAction SilentlyContinue }
    if (Test-Path $tempSha) { Remove-Item -Force $tempSha -ErrorAction SilentlyContinue }
}
# Clean up legacy contexa binary in USERPROFILE\.local\bin if present on Windows to avoid PATH conflicts
$LegacyBinPath = Join-Path $env:USERPROFILE '.local\bin\contexa.exe'
if (Test-Path $LegacyBinPath) {
    try {
        Remove-Item -Force $LegacyBinPath -ErrorAction Stop
        Write-Host "  Cleaned up legacy duplicate contexa binary at $LegacyBinPath to prevent PATH conflicts." -ForegroundColor Green
    } catch {
        Write-Host "  Warning: legacy duplicate contexa binary found at $LegacyBinPath but could not be removed." -ForegroundColor Yellow
        Write-Host "           Please delete it manually to avoid PATH conflicts." -ForegroundColor Yellow
    }
}

# Add InstallDir to the user PATH if not already present (User scope, no admin needed).
# Both sides are normalized (trailing backslash stripped) so that
# "C:\...\Contexa" and "C:\...\Contexa\" don't get treated as two entries
# and accumulate on every reinstall.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ([string]::IsNullOrEmpty($userPath)) { $userPath = '' }

$normalizedTarget = $InstallDir.TrimEnd('\')
$pathEntries = $userPath.Split(';') | Where-Object { $_ -ne '' }
$alreadyOnPath = @($pathEntries | ForEach-Object { $_.TrimEnd('\') }) -contains $normalizedTarget

if (-not $alreadyOnPath) {
    $newPath = if ($userPath.EndsWith(';') -or $userPath -eq '') { "$userPath$InstallDir" } else { "$userPath;$InstallDir" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host ''
    Write-Host "  Added $InstallDir to user PATH." -ForegroundColor Green
    Write-Host '  Open a new terminal for the change to take effect.' -ForegroundColor DarkGray
}

# Restore the user's original $ProgressPreference so any subsequent commands
# in the same session keep their default progress UI.
$ProgressPreference = $script:OriginalProgressPreference

# Restore the original console output encoding too. We only flipped it for
# the banner + status lines above; leaving it pinned to utf-8 could surprise
# subsequent commands in the same shell session that expect cp949.
if ($script:OriginalConsoleOutputEncoding) {
    try { [Console]::OutputEncoding = $script:OriginalConsoleOutputEncoding } catch { }
}

# Success summary
Write-Host ''
Write-Host "  Contexa $version installed!" -ForegroundColor Green
Write-Host ''
Write-Host '  Get started:' -ForegroundColor White
Write-Host '    cd your-spring-project' -ForegroundColor Cyan
Write-Host '    contexa init'           -ForegroundColor Cyan
Write-Host ''
