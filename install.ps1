#Requires -Version 5.1
<#
.SYNOPSIS
  Contexa CLI installer for Windows.

.DESCRIPTION
  Downloads the latest contexa-win-x64.exe release from GitHub, verifies it
  against the published SHA-256 digest, installs it under
  %LOCALAPPDATA%\Programs\Contexa, and adds that directory to the user PATH.

.NOTES
  Requires PowerShell 5.1 or later.
  Run with: irm https://install.ctxa.ai/install.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

# PowerShell 5.x defaults to TLS 1.0 on some Windows installations.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:OriginalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

function Restore-InstallerState {
    $ProgressPreference = $script:OriginalProgressPreference
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Write-Banner {
    Write-Host ''
    Write-Host '  ===============================================' -ForegroundColor Cyan
    Write-Host '   Contexa CLI Installer' -ForegroundColor Cyan
    Write-Host '   AI-Native Zero Trust Security Platform' -ForegroundColor Yellow
    Write-Host '   https://ctxa.ai' -ForegroundColor DarkGray
    Write-Host '  ===============================================' -ForegroundColor Cyan
    Write-Host ''
}

function Test-Java17 {
    if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
        Write-Host '  ! Java was not found. CLI installation can continue, but Contexa projects require JDK 17+.' -ForegroundColor Yellow
        return
    }

    try {
        $javaLines = cmd /c "java -version 2>&1"
        foreach ($line in $javaLines) {
            $lineStr = $line.ToString()
            if ($lineStr -match 'version "([^"]+)"' -or $lineStr -match 'openjdk version "([^"]+)"') {
                $fullVer = $Matches[1]
                $major = $null
                if ($fullVer -match '^1\.([0-9]+)') {
                    $major = [int]$Matches[1]
                } elseif ($fullVer -match '^([0-9]+)') {
                    $major = [int]$Matches[1]
                }
                if ($major -ge 17) {
                    Write-Host '  Java check: JDK 17+ detected.' -ForegroundColor Green
                } else {
                    Write-Host "  ! Java 17+ was not detected (detected: $fullVer)." -ForegroundColor Yellow
                }
                return
            }
        }
        Write-Host '  ! Could not determine Java version. Contexa projects require JDK 17+.' -ForegroundColor Yellow
    } catch {
        Write-Host '  ! Java version check failed. Contexa projects require JDK 17+.' -ForegroundColor Yellow
    }
}

function Test-DockerOptional {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host '  ! Docker CLI was not found. Basic CLI install is OK; local infra commands will need Docker.' -ForegroundColor Yellow
        return
    }

    try {
        & docker ps > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host '  Docker check: daemon is running.' -ForegroundColor Green
        } else {
            Write-Host '  ! Docker daemon is not running. Basic CLI install is OK; local infra commands will need it.' -ForegroundColor Yellow
        }
    } catch {
        Write-Host '  ! Docker check failed. Basic CLI install is OK; local infra commands will need Docker.' -ForegroundColor Yellow
    }
}

$Repo       = 'contexa-security/contexa-cli'
$BinaryName = 'contexa-win-x64.exe'

$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $LocalAppData = Join-Path $env:USERPROFILE 'AppData\Local'
}
if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
    Write-Host '  Error: cannot resolve a writable installation directory.' -ForegroundColor Red
    Write-Host '         Both LOCALAPPDATA and USERPROFILE are empty.' -ForegroundColor Red
    Restore-InstallerState
    return
}

$InstallDir = if (-not [string]::IsNullOrWhiteSpace($env:CONTEXA_INSTALL_DIR)) {
    $env:CONTEXA_INSTALL_DIR
} else {
    Join-Path $LocalAppData 'Programs\Contexa'
}
$FinalPath = Join-Path $InstallDir 'contexa.exe'

Write-Banner
Write-Host '  Running environment checks...' -ForegroundColor DarkGray
Test-Java17
Test-DockerOptional
Write-Host ''

$version = $null
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
    if ($release -and $release.tag_name) {
        $version = $release.tag_name
    }
} catch {
    Write-Host '  Error: could not fetch latest release info from GitHub.' -ForegroundColor Red
    Write-Host "         $_" -ForegroundColor Red
    Restore-InstallerState
    return
}

if ([string]::IsNullOrWhiteSpace($version)) {
    Write-Host '  Error: empty version tag from GitHub API.' -ForegroundColor Red
    Restore-InstallerState
    return
}

$downloadUrl = "https://github.com/$Repo/releases/download/$version/$BinaryName"
$shaUrl      = "$downloadUrl.sha256"

Write-Host "  Version  : $version"      -ForegroundColor White
Write-Host '  Platform : Windows x64'   -ForegroundColor White
Write-Host "  Target   : $FinalPath"    -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

$tempBin = [System.IO.Path]::GetTempFileName()
$tempSha = "$tempBin.sha256"

try {
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

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempBin -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host '  Error: GitHub binary download failed.' -ForegroundColor Red
        Write-Host "         $downloadUrl" -ForegroundColor Red
        Write-Host "         $_" -ForegroundColor Red
        return
    }

    $actualSize = (Get-Item $tempBin).Length
    Write-Host ("  Downloaded {0}." -f (Format-Bytes $actualSize)) -ForegroundColor Green

    Write-Host '  Verifying checksum...' -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $shaUrl -OutFile $tempSha -UseBasicParsing -ErrorAction Stop
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

    try {
        Move-Item -Force -Path $tempBin -Destination $FinalPath
    } catch [System.IO.IOException] {
        Write-Host ''
        Write-Host "  Error: could not write $FinalPath" -ForegroundColor Red
        Write-Host '         The existing contexa.exe may be in use by another process.' -ForegroundColor Red
        Write-Host '         Close any running contexa session and re-run this installer.' -ForegroundColor Red
        return
    }

    try {
        & $FinalPath --help > $null 2>&1
        if ($LASTEXITCODE -ne 0) { throw "contexa --help exited with $LASTEXITCODE" }
        Write-Host '  Binary smoke check passed.' -ForegroundColor Green
    } catch {
        Write-Host '  Error: installed binary did not run successfully.' -ForegroundColor Red
        Write-Host "         $_" -ForegroundColor Red
        return
    }
} finally {
    if (Test-Path $tempBin) { Remove-Item -Force $tempBin -ErrorAction SilentlyContinue }
    if (Test-Path $tempSha) { Remove-Item -Force $tempSha -ErrorAction SilentlyContinue }
    Restore-InstallerState
}

$LegacyBinPath = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $null } else { Join-Path $env:USERPROFILE '.local\bin\contexa.exe' }
if ($LegacyBinPath -and (Test-Path $LegacyBinPath)) {
    try {
        Remove-Item -Force $LegacyBinPath -ErrorAction Stop
        Write-Host "  Cleaned up legacy duplicate contexa binary at $LegacyBinPath." -ForegroundColor Green
    } catch {
        Write-Host "  Warning: legacy duplicate contexa binary found at $LegacyBinPath but could not be removed." -ForegroundColor Yellow
        Write-Host '           Please delete it manually to avoid PATH conflicts.' -ForegroundColor Yellow
    }
}

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

Write-Host ''
Write-Host "  Contexa $version installed!" -ForegroundColor Green
Write-Host ''
Write-Host '  Get started:' -ForegroundColor White
Write-Host '    cd your-spring-project' -ForegroundColor Cyan
Write-Host '    contexa init'           -ForegroundColor Cyan
Write-Host ''
