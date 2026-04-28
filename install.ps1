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
    exit 1
}

$InstallDir = Join-Path $LocalAppData 'Programs\Contexa'
$FinalPath  = Join-Path $InstallDir 'contexa.exe'

# Banner
Write-Host ''
Write-Host '  ##::::::::: ##::::::: ###:: ## ######## ######## ##::: ##  ###### ' -ForegroundColor Cyan
Write-Host '  ##:::::::: ##:::::::  ####: ##    ##    ##::::::  ## ##::: ##:::: ' -ForegroundColor Cyan
Write-Host '  ##:::::::: ##:::::::  ## ##:##    ##    ######::   ###:::: ###### ' -ForegroundColor Cyan
Write-Host '  ##:::::::: ##:::::::  ##: ####    ##    ##::::::  ## ##::: ::::## ' -ForegroundColor Cyan
Write-Host '  ######### ########::  ##::: ##    ##    ######## ##::: ## ###### '  -ForegroundColor Cyan
Write-Host '  AI-Native Zero Trust Security Platform   https://ctxa.ai' -ForegroundColor Yellow
Write-Host ''

# Resolve latest release tag from GitHub.
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
    $version = $release.tag_name
} catch {
    Write-Host "  Error: could not fetch latest release info from GitHub." -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($version)) {
    Write-Host '  Error: empty version tag from GitHub API.' -ForegroundColor Red
    exit 1
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
    Write-Host '  Downloading...' -ForegroundColor DarkGray -NoNewline
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempBin -UseBasicParsing
    Write-Host "`r  Downloaded successfully.            " -ForegroundColor Green

    # Fetch SHA-256 sidecar - failure means the publisher has not yet published a digest,
    # in which case we refuse to install rather than trust an unverified binary.
    Write-Host '  Verifying checksum...' -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $shaUrl -OutFile $tempSha -UseBasicParsing
    } catch {
        Write-Host "  Error: checksum file not found at $shaUrl" -ForegroundColor Red
        Write-Host '  Refusing to install an unverified binary.' -ForegroundColor Red
        exit 1
    }

    $expected = (Get-Content $tempSha -Raw).Trim().Split()[0]
    if ([string]::IsNullOrWhiteSpace($expected)) {
        Write-Host '  Error: empty checksum file.' -ForegroundColor Red
        exit 1
    }

    $actual = (Get-FileHash -Path $tempBin -Algorithm SHA256).Hash.ToLower()
    if ($expected.ToLower() -ne $actual) {
        Write-Host '  Error: checksum mismatch.' -ForegroundColor Red
        Write-Host "    expected: $expected" -ForegroundColor Red
        Write-Host "    actual  : $actual"   -ForegroundColor Red
        Write-Host '  Refusing to install a tampered binary.' -ForegroundColor Red
        exit 1
    }

    Write-Host '  Checksum verified.' -ForegroundColor Green

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
        exit 1
    }
} finally {
    # Always clean up temp artifacts, even on failure.
    if (Test-Path $tempBin) { Remove-Item -Force $tempBin -ErrorAction SilentlyContinue }
    if (Test-Path $tempSha) { Remove-Item -Force $tempSha -ErrorAction SilentlyContinue }
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

# Success summary
Write-Host ''
Write-Host "  Contexa $version installed!" -ForegroundColor Green
Write-Host ''
Write-Host '  Get started:' -ForegroundColor White
Write-Host '    cd your-spring-project' -ForegroundColor Cyan
Write-Host '    contexa init'           -ForegroundColor Cyan
Write-Host ''
