# zpeek installer for Windows PowerShell 5.1+ and PowerShell 7+.
#
#   irm https://raw.githubusercontent.com/alaleks/zpeek/master/install.ps1 | iex
#
# Environment overrides:
#   ZPEEK_VERSION      install a specific release tag (default: latest)
#   ZPEEK_INSTALL_DIR  where to put zpeek.exe (default: %LOCALAPPDATA%\zpeek\bin)
#   ZPEEK_REPO         GitHub repository (owner/name)
#   ZPEEK_RELEASE_URL  base URL with the release assets (mirrors, local tests)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is much faster without it

# throw, not exit: with `irm … | iex`, exit would close the user's PowerShell window.
function Fail($message) {
    throw "zpeek installer: $message"
}

$repo = if ($env:ZPEEK_REPO) { $env:ZPEEK_REPO } else { 'alaleks/zpeek' }
if ($env:ZPEEK_RELEASE_URL) {
    $base = $env:ZPEEK_RELEASE_URL.TrimEnd('/')
} elseif ($env:ZPEEK_VERSION) {
    $base = "https://github.com/$repo/releases/download/$($env:ZPEEK_VERSION)"
} else {
    $base = "https://github.com/$repo/releases/latest/download"
}

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'x86_64' }
    'ARM64' { 'aarch64' }
    default { Fail "unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)" }
}
# 32-bit PowerShell on 64-bit Windows reports x86; the real machine is in this variable.
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { $arch = 'x86_64' }
if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $arch = 'aarch64' }

$asset = "zpeek-windows-$arch.zip"
$installDir = if ($env:ZPEEK_INSTALL_DIR) { $env:ZPEEK_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'zpeek\bin' }

# TLS 1.2 for Windows PowerShell 5.1 on older systems.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$temp = Join-Path ([IO.Path]::GetTempPath()) ("zpeek." + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $archive = Join-Path $temp $asset
    Write-Host "Downloading $asset..."
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $archive

    $checksums = $null
    try {
        $checksums = (Invoke-WebRequest -UseBasicParsing -Uri "$base/checksums.txt").Content
        if ($checksums -is [byte[]]) { $checksums = [Text.Encoding]::UTF8.GetString($checksums) }
    } catch {
        # PowerShell 5.1 and 7 throw different exception types; any failure means "no checksums".
        Write-Warning 'checksums.txt is unavailable; the download was not verified.'
    }
    if ($checksums) {
        $expected = $null
        foreach ($line in ($checksums -split "`r?`n")) {
            $fields = $line.Trim() -split '\s+'
            if ($fields.Count -ge 2 -and (($fields[1] -replace '^\*', '') -eq $asset)) { $expected = $fields[0].ToLower(); break }
        }
        if (-not $expected) { Fail "checksum for $asset is missing" }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLower()
        if ($actual -ne $expected) { Fail 'checksum verification failed' }
    }

    $extract = Join-Path $temp 'extract'
    # .NET's ZipFile instead of Expand-Archive: same behavior on PowerShell 5.1
    # and 7, and it avoids Expand-Archive bugs in some module versions.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extract)
    $exe = Join-Path $extract 'zpeek.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Fail "$asset does not contain zpeek.exe" }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    $destination = Join-Path $installDir 'zpeek.exe'
    Copy-Item -Force -LiteralPath $exe -Destination $destination
} finally {
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = if ($userPath) { $userPath -split ';' | Where-Object { $_ } } else { @() }
$pathAdded = $false
if ($parts -notcontains $installDir) {
    [Environment]::SetEnvironmentVariable('Path', (($parts + $installDir) -join ';'), 'User')
    $env:Path = "$env:Path;$installDir"
    $pathAdded = $true
    Write-Host "Added $installDir to the user PATH."
}

# Cosmetic only: a failure here (e.g. antivirus delaying the first run) must not fail the install.
$version = $null
try { $version = & $destination --version 2>$null } catch { }
if (-not $version) { $version = 'zpeek' }
Write-Host "$version installed at $destination"
if ($pathAdded) {
    Write-Host 'Open a new terminal, then run: zpeek'
} else {
    Write-Host 'Run: zpeek'
}
