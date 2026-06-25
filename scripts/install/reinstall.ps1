[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param(
        [string]$Message
    )

    Write-Host "==> $Message"
}

function Assert-Command {
    param(
        [string]$Name,
        [string[]]$FallbackPaths = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    foreach ($path in $FallbackPaths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    if ($FallbackPaths.Count -gt 0) {
        $fallbackSummary = ($FallbackPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ", "
        throw "Missing required command: $Name. Also checked: $fallbackSummary"
    }

        throw "Missing required command: $Name"
}

function Add-DirectoryToPath {
    param(
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        return
    }

    $pathEntries = $env:PATH -split ";"
    if ($pathEntries -contains $Directory) {
        return
    }

    $env:PATH = "$Directory;$env:PATH"
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir "..\..")).Path
$codexRsDir = Join-Path $repoRoot "codex-rs"

if (-not (Test-Path -LiteralPath $codexRsDir -PathType Container)) {
    throw "Could not find codex-rs workspace at: $codexRsDir"
}

$cargoPath = Assert-Command -Name "cargo" -FallbackPaths @(
    $(if (-not [string]::IsNullOrWhiteSpace($env:CARGO_HOME)) { Join-Path $env:CARGO_HOME "bin\cargo.exe" }),
    $(if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe" })
)
$npmPath = Assert-Command -Name "npm"
$nodePath = Assert-Command -Name "node"

Add-DirectoryToPath -Directory (Split-Path -Parent $cargoPath)

$arch = (& $nodePath -p "process.arch").Trim()
switch ($arch) {
    "x64" {
        $platformPackage = "codex-win32-x64"
        $targetTriple = "x86_64-pc-windows-msvc"
    }
    "arm64" {
        $platformPackage = "codex-win32-arm64"
        $targetTriple = "aarch64-pc-windows-msvc"
    }
    default {
        throw "Unsupported Windows architecture: $arch"
    }
}

$npmRoot = (& $npmPath root -g).Trim()
if ([string]::IsNullOrWhiteSpace($npmRoot)) {
    throw "npm global root is empty."
}

$codexPackageRoot = Join-Path $npmRoot "@openai\codex"
$platformPackageRoot = Join-Path $codexPackageRoot "node_modules\@openai\$platformPackage"
$installedBin = Join-Path $platformPackageRoot "vendor\$targetTriple\bin\codex.exe"
$sourceBin = Join-Path $codexRsDir "target\release\codex.exe"

if (-not (Test-Path -LiteralPath $codexPackageRoot -PathType Container)) {
    throw "Global @openai/codex package not found at: $codexPackageRoot. Install it with: npm install -g @openai/codex"
}

if (-not (Test-Path -LiteralPath $platformPackageRoot -PathType Container)) {
    throw "Platform package not found at: $platformPackageRoot. Reinstall Codex with: npm install -g @openai/codex"
}

if (-not (Test-Path -LiteralPath $installedBin -PathType Leaf)) {
    throw "Installed Codex binary not found at: $installedBin"
}

Write-Step "Building codex-cli release binary"
Push-Location -LiteralPath $codexRsDir
try {
    if ([string]::IsNullOrWhiteSpace($env:CARGO_BUILD_JOBS)) {
        $env:CARGO_BUILD_JOBS = "1"
    }
    & $cargoPath build --locked -p codex-cli --release
} finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $sourceBin -PathType Leaf)) {
    throw "Build did not produce expected binary: $sourceBin"
}

$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$backupBin = "$installedBin.backup.$timestamp"

if (Test-Path -LiteralPath $backupBin) {
    throw "Backup path already exists: $backupBin"
}

Write-Step "Backing up installed binary to $backupBin"
Copy-Item -LiteralPath $installedBin -Destination $backupBin

Write-Step "Replacing installed binary at $installedBin"
Copy-Item -LiteralPath $sourceBin -Destination $installedBin -Force

Write-Step "Verifying installed Codex version"
codex --version
