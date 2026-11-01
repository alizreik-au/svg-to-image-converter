#Requires -Version 5.1
<#
.SYNOPSIS
    Build a single-file Windows 10/11 x64 setup executable and SHA-256 checksum.
.DESCRIPTION
    Requires Rust/MSVC and Inno Setup 6.3+ or 7. Builds the existing CLI and
    no-console converter with a static C runtime, then packages the classic
    Explorer menu with a per-user installer and native uninstaller.
    No MSIX certificate, Windows SDK packaging tools, or admin rights are needed.
.PARAMETER OutputDir
    Release assets directory. Defaults to target\installer.
.PARAMETER IsccPath
    Optional path to the Inno Setup command-line compiler (ISCC.exe).
#>
[CmdletBinding()]
param(
    [string] $OutputDir,
    [string] $IsccPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'target\installer' }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$buildDir = Join-Path $repoRoot 'target\setup-build'
$stageDir = Join-Path $buildDir 'packaging'
$binDir = Join-Path $buildDir 'x86_64-pc-windows-msvc\release'

if (-not $IsccPath) {
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($compiler) { $IsccPath = $compiler.Source }
    foreach ($major in @(7, 6)) {
        foreach ($base in @("$env:LOCALAPPDATA\Programs", $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($IsccPath -or -not $base) { continue }
            $candidate = Join-Path $base "Inno Setup $major\ISCC.exe"
            if (Test-Path -LiteralPath $candidate) { $IsccPath = $candidate }
        }
    }
}
if (-not $IsccPath -or -not (Test-Path -LiteralPath $IsccPath)) {
    throw 'Install Inno Setup 6.3+ or 7 from https://jrsoftware.org/isdl.php, or supply -IsccPath.'
}
$IsccPath = (Resolve-Path -LiteralPath $IsccPath).Path
[xml]$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'packaging\full\AppxManifest.xml') -Raw
$version = [string]$manifest.Package.Identity.Version
if ($version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "Invalid package version: $version" }

New-Item -ItemType Directory -Path $OutputDir, $stageDir -Force | Out-Null
Push-Location $repoRoot
$previousRustFlags = $env:RUSTFLAGS
$previousEncodedFlags = $env:CARGO_ENCODED_RUSTFLAGS
try {
    # An isolated target directory prevents accidental reuse of dynamic-runtime
    # binaries from the MSIX/developer build. Restore the caller's flags below.
    if ($previousEncodedFlags) {
        $env:CARGO_ENCODED_RUSTFLAGS = $previousEncodedFlags + [char]31 + '-Ctarget-feature=+crt-static'
    } else {
        $env:RUSTFLAGS = "$previousRustFlags -C target-feature=+crt-static".Trim()
    }
    & cargo build --release --locked --package svg-converter --bins `
        --target x86_64-pc-windows-msvc --target-dir $buildDir
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)." }

    # Include the actual dependency license texts with the distributed binaries.
    $metadataText = & cargo metadata --locked --format-version 1 --filter-platform x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Could not read dependency metadata.' }
    $metadata = $metadataText | ConvertFrom-Json
    $notices = New-Object Text.StringBuilder
    [void]$notices.AppendLine('SVG Converter - third-party notices')
    foreach ($package in ($metadata.packages | Sort-Object name, version)) {
        if ($package.id -in $metadata.workspace_members) { continue }
        [void]$notices.AppendLine("`r`n===== $($package.name) $($package.version) =====")
        [void]$notices.AppendLine("License: $($package.license)")
        [void]$notices.AppendLine("Source: $($package.repository)")
        $packageDir = Split-Path -Parent $package.manifest_path
        $licenseFiles = @(Get-ChildItem -LiteralPath $packageDir -File |
            Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE|AUTHORS|COPYRIGHT)([._-]|$)' })
        if ($package.license_file) {
            $licenseFiles += Get-Item -LiteralPath (Join-Path $packageDir $package.license_file)
        }
        foreach ($file in ($licenseFiles | Sort-Object FullName -Unique)) {
            [void]$notices.AppendLine("--- $($file.Name) ---")
            [void]$notices.AppendLine((Get-Content -LiteralPath $file.FullName -Raw))
        }
        if ($licenseFiles.Count -eq 0) { throw "No bundled license text found for $($package.name)." }
    }
    [IO.File]::WriteAllText((Join-Path $stageDir 'THIRD_PARTY_NOTICES.txt'), $notices.ToString())

    # Reuse the repository icon. ICO supports a PNG payload at 256x256.
    $iconPng = Join-Path $stageDir 'icon.png'
    & (Join-Path $binDir 'svg-converter.exe') convert (Join-Path $repoRoot 'packaging\assets\icon.svg') `
        --output $iconPng --overwrite --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Could not render the setup icon.' }
    $pngBytes = [IO.File]::ReadAllBytes($iconPng)
    $iconWriter = New-Object IO.BinaryWriter([IO.File]::Create((Join-Path $stageDir 'SvgConverter.ico')))
    try {
        $iconWriter.Write([uint16]0)  # reserved
        $iconWriter.Write([uint16]1)  # icon
        $iconWriter.Write([uint16]1)  # one image
        $iconWriter.Write([byte[]]@(0, 0, 0, 0)) # 256x256, true color
        $iconWriter.Write([uint16]1)
        $iconWriter.Write([uint16]32)
        $iconWriter.Write([uint32]$pngBytes.Length)
        $iconWriter.Write([uint32]22) # payload offset
        $iconWriter.Write($pngBytes)
    } finally { $iconWriter.Dispose() }

    & $IsccPath "/DAppVersion=$version" "/DRepoRoot=$repoRoot" "/DBinDir=$binDir" `
        "/DStageDir=$stageDir" "/DOutputDir=$OutputDir" (Join-Path $repoRoot 'packaging\windows\setup.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed (exit $LASTEXITCODE)." }

    $setupPath = Join-Path $OutputDir "SvgConverter-$version-windows-x64-setup.exe"
    $hash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$setupPath.sha256", "$hash  $([IO.Path]::GetFileName($setupPath))`r`n")
    Write-Host "`nRelease installer: $setupPath"
    Write-Host "Checksum: $setupPath.sha256"
    Write-Host 'This setup is unsigned. A public download may show a Windows SmartScreen warning.'
} finally {
    $env:RUSTFLAGS = $previousRustFlags
    $env:CARGO_ENCODED_RUSTFLAGS = $previousEncodedFlags
    Pop-Location
}
