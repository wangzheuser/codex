[CmdletBinding()]
param(
    [string]$Profile = $env:CODEX_REINSTALL_PROFILE
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Profile)) {
    $Profile = "dev-small"
}

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

function Test-FileContainsCrLf {
    param(
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    for ($index = 0; $index -lt ($bytes.Length - 1); $index++) {
        if ($bytes[$index] -eq 13 -and $bytes[$index + 1] -eq 10) {
            return $true
        }
    }

    return $false
}

function Assert-SqlxMigrationsUseLf {
    param(
        [string]$CodexRsDir
    )

    $migrationDirs = @(
        "state\migrations",
        "state\logs_migrations",
        "state\goals_migrations",
        "state\memory_migrations"
    )
    $badFiles = @()

    foreach ($relativeDir in $migrationDirs) {
        $dir = Join-Path $CodexRsDir $relativeDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            continue
        }

        Get-ChildItem -LiteralPath $dir -Filter "*.sql" -File | ForEach-Object {
            if (Test-FileContainsCrLf -Path $_.FullName) {
                $badFiles += $_.FullName
            }
        }
    }

    if ($badFiles.Count -eq 0) {
        return
    }

    $fileList = $badFiles -join [Environment]::NewLine
    throw "SQLx migration files must use LF line endings before building Codex. CRLF changes migration checksums and can make local SQLite DBs fail to open after reinstall. Normalize these files and rerun the script:$([Environment]::NewLine)$fileList"
}

function Get-PackageJsonVersion {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $packageJson = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $versionProperty = $packageJson.PSObject.Properties["version"]
        if ($null -ne $versionProperty -and -not [string]::IsNullOrWhiteSpace($versionProperty.Value)) {
            return [string]$versionProperty.Value
        }
    } catch {
        return $null
    }

    return $null
}

function Get-CargoWorkspaceVersion {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $inWorkspacePackage = $false
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*\[workspace\.package\]\s*$') {
            $inWorkspacePackage = $true
            continue
        }

        if ($inWorkspacePackage -and $line -match '^\s*\[') {
            return $null
        }

        if ($inWorkspacePackage -and $line -match '^\s*version\s*=\s*"([^"]+)"') {
            return $matches[1]
        }
    }

    return $null
}

function Get-CodexBinaryVersion {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $output = & $Path --version 2>$null | Select-Object -First 1
    } catch {
        return $null
    }

    if ($output -match 'codex-cli\s+([0-9][0-9A-Za-z.+-]*)') {
        return $matches[1]
    }

    return $null
}

function ConvertTo-CodexDevVersion {
    param(
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    $baseVersion = $Version.Trim()
    if ($baseVersion -match 'codex-cli\s+([0-9][0-9A-Za-z.+-]*)') {
        $baseVersion = $matches[1]
    }

    $baseVersion = $baseVersion -replace '-dev$', ''
    if ([string]::IsNullOrWhiteSpace($baseVersion) -or $baseVersion -eq "0.0.0") {
        return $null
    }

    return "$baseVersion-dev"
}

function Resolve-CodexDevVersion {
    param(
        [string]$RepoRoot,
        [string]$UserProfile
    )

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEV_VERSION)) {
        $explicitVersion = $env:CODEX_DEV_VERSION.Trim()
        if ($explicitVersion -match 'codex-cli\s+([0-9][0-9A-Za-z.+-]*)') {
            return $matches[1]
        }

        return $explicitVersion
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEV_BASE_VERSION)) {
        $devVersion = ConvertTo-CodexDevVersion -Version $env:CODEX_DEV_BASE_VERSION
        if ($null -ne $devVersion) {
            return $devVersion
        }
    }

    $repoVersionCandidates = @(
        (Get-CargoWorkspaceVersion -Path (Join-Path $RepoRoot "codex-rs\Cargo.toml")),
        (Get-PackageJsonVersion -Path (Join-Path $RepoRoot "codex-cli\package.json"))
    )
    foreach ($candidate in $repoVersionCandidates) {
        $devVersion = ConvertTo-CodexDevVersion -Version $candidate
        if ($null -ne $devVersion) {
            return $devVersion
        }
    }

    $npmCommand = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $npmCommand) {
        $npmRoot = (& $npmCommand.Source root -g 2>$null | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($npmRoot)) {
            $devVersion = ConvertTo-CodexDevVersion -Version (Get-PackageJsonVersion -Path (Join-Path $npmRoot "@openai\codex\package.json"))
            if ($null -ne $devVersion) {
                return $devVersion
            }
        }
    }

    $officialDesktopBinary = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin\codex.exe"
    $devVersion = ConvertTo-CodexDevVersion -Version (Get-CodexBinaryVersion -Path $officialDesktopBinary)
    if ($null -ne $devVersion) {
        return $devVersion
    }

    $appDataPackageJson = Join-Path $env:APPDATA "npm\node_modules\@openai\codex\package.json"
    $devVersion = ConvertTo-CodexDevVersion -Version (Get-PackageJsonVersion -Path $appDataPackageJson)
    if ($null -ne $devVersion) {
        return $devVersion
    }

    $userPackageJson = Join-Path $UserProfile "AppData\Roaming\npm\node_modules\@openai\codex\package.json"
    $devVersion = ConvertTo-CodexDevVersion -Version (Get-PackageJsonVersion -Path $userPackageJson)
    if ($null -ne $devVersion) {
        return $devVersion
    }

    return "0.0.0-dev"
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
Add-DirectoryToPath -Directory (Split-Path -Parent $cargoPath)

$buildOutputDir = switch ($Profile) {
    "release" { "release" }
    "dev" { "debug" }
    default { $Profile }
}

$cargoArgs = switch ($Profile) {
    "release" { @("build", "--locked", "-p", "codex-cli", "--release") }
    "dev" { @("build", "--locked", "-p", "codex-cli") }
    default { @("build", "--locked", "-p", "codex-cli", "--profile", $Profile) }
}

$userProfile = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $env:USERPROFILE
} else {
    [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
}

$devHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEV_HOME)) {
    $env:CODEX_DEV_HOME
} else {
    Join-Path $userProfile ".codex-dev"
}
$installRoot = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEV_INSTALL_ROOT)) {
    $env:CODEX_DEV_INSTALL_ROOT
} else {
    Join-Path $userProfile ".local\share\codex-dev"
}
$shimDir = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEV_SHIM_DIR)) {
    $env:CODEX_DEV_SHIM_DIR
} else {
    Join-Path $userProfile ".local\bin"
}
$sourceHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEV_SEED_HOME)) {
    $env:CODEX_DEV_SEED_HOME
} else {
    Join-Path $userProfile ".codex"
}

$installBinDir = Join-Path $installRoot "bin"
$installedBin = Join-Path $installBinDir "codex.exe"
$sourceBin = Join-Path $codexRsDir "target\$buildOutputDir\codex.exe"
$devVersion = Resolve-CodexDevVersion -RepoRoot $repoRoot -UserProfile $userProfile

function ConvertTo-PowerShellLiteral {
    param(
        [string]$Value
    )

    return "'" + $Value.Replace("'", "''") + "'"
}

function Write-PowerShellShim {
    param(
        [string]$Path,
        [string[]]$ExtraArgs = @()
    )

    $binaryLiteral = ConvertTo-PowerShellLiteral -Value $installedBin
    $devHomeLiteral = ConvertTo-PowerShellLiteral -Value $devHome
    $versionOutputLiteral = ConvertTo-PowerShellLiteral -Value "codex-cli $devVersion"
    $extra = if ($ExtraArgs.Count -gt 0) {
        " " + (($ExtraArgs | ForEach-Object { ConvertTo-PowerShellLiteral -Value $_ }) -join " ")
    } else {
        ""
    }
    $content = @"
#!/usr/bin/env pwsh
if (`$args.Count -eq 1 -and (`$args[0] -eq '--version' -or `$args[0] -eq '-V')) {
    Write-Output $versionOutputLiteral
    exit 0
}
`$env:CODEX_HOME = $devHomeLiteral
`$env:CODEX_SQLITE_HOME = $devHomeLiteral
& $binaryLiteral$extra @args
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Write-CmdShim {
    param(
        [string]$Path,
        [string[]]$ExtraArgs = @()
    )

    $extra = if ($ExtraArgs.Count -gt 0) { " " + ($ExtraArgs -join " ") } else { "" }
    $content = @"
@echo off
if "%~1"=="--version" if "%~2"=="" (
  echo codex-cli $devVersion
  exit /b 0
)
if "%~1"=="-V" if "%~2"=="" (
  echo codex-cli $devVersion
  exit /b 0
)
set "CODEX_HOME=$devHome"
set "CODEX_SQLITE_HOME=$devHome"
"$installedBin"$extra %*
exit /b %ERRORLEVEL%
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
}

Assert-SqlxMigrationsUseLf -CodexRsDir $codexRsDir

Write-Step "Resolved codex-dev version: codex-cli $devVersion"
Write-Step "Building codex-cli with Cargo profile: $Profile"
Push-Location -LiteralPath $codexRsDir
try {
    & $cargoPath @cargoArgs
} finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $sourceBin -PathType Leaf)) {
    throw "Build did not produce expected binary: $sourceBin"
}

New-Item -ItemType Directory -Path $devHome -Force | Out-Null
New-Item -ItemType Directory -Path $installBinDir -Force | Out-Null
New-Item -ItemType Directory -Path $shimDir -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$backupBin = if (Test-Path -LiteralPath $installedBin -PathType Leaf) {
    "$installedBin.backup.$timestamp"
} else {
    $null
}

if ($null -ne $backupBin -and (Test-Path -LiteralPath $backupBin)) {
    throw "Backup path already exists: $backupBin"
}

if ($null -ne $backupBin) {
    Write-Step "Backing up existing codex-dev binary to $backupBin"
    Copy-Item -LiteralPath $installedBin -Destination $backupBin
}

Write-Step "Installing codex-dev binary at $installedBin"
Copy-Item -LiteralPath $sourceBin -Destination $installedBin -Force

foreach ($fileName in @("config.toml", "auth.json", "AGENTS.md")) {
    $sourcePath = Join-Path $sourceHome $fileName
    $destinationPath = Join-Path $devHome $fileName
    if ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -and -not (Test-Path -LiteralPath $destinationPath)) {
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
    }
}

Write-Step "Writing codex-dev and cx-dev shims to $shimDir"
Write-PowerShellShim -Path (Join-Path $shimDir "codex-dev.ps1")
Write-PowerShellShim -Path (Join-Path $shimDir "cx-dev.ps1") -ExtraArgs @("--dangerously-bypass-approvals-and-sandbox")
Write-CmdShim -Path (Join-Path $shimDir "codex-dev.cmd")
Write-CmdShim -Path (Join-Path $shimDir "cx-dev.cmd") -ExtraArgs @("--dangerously-bypass-approvals-and-sandbox")

Write-Step "Verifying installed codex-dev version"
& (Join-Path $shimDir "codex-dev.ps1") --version
Write-Step "Verifying installed cx-dev version"
& (Join-Path $shimDir "cx-dev.ps1") --version
