#Requires -Version 5.1
<#
.SYNOPSIS
    Builds SVG Converter (release) and stages the sparse-package "external
    location": the binaries, the IExplorerCommand DLL, AppxManifest.xml, and the
    generated MSIX logo assets.

.DESCRIPTION
    Phase 4 (Windows 11 primary context menu). This script does NOT register the
    package or touch the machine's Appx/registry state - it only produces the
    on-disk layout that scripts/install-sparse-package.ps1 later registers:

        <InstallDir>\
          svg-converter.exe          (console CLI)
          svg-converterw.exe         (no-console variant used by the menu)
          svg_converter_shell.dll    (IExplorerCommand COM handler)
          AppxManifest.xml
          Assets\
            StoreLogo.png            (50x50)
            Square44x44Logo.png      (44x44)
            Square150x150Logo.png    (150x150)

    Logo PNGs are generated at build time with System.Drawing (no binaries are
    committed to the repo). The AppxManifest.xml is validated for well-formedness;
    full schema validation happens at registration time (or via makeappx if the
    Windows SDK is installed).

.PARAMETER InstallDir
    External location to stage into. This is the path you pass to
    install-sparse-package.ps1 as -ExternalLocation.
    Default: %LOCALAPPDATA%\Programs\SvgConverter

.PARAMETER SkipBuild
    Stage using existing target\release artifacts instead of running cargo build.

.EXAMPLE
    .\scripts\build-sparse-package.ps1
    .\scripts\build-sparse-package.ps1 -InstallDir "C:\Program Files\SvgConverter"
#>
[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\SvgConverter'),
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestSrc = Join-Path $repoRoot 'packaging\AppxManifest.xml'
$releaseDir = Join-Path $repoRoot 'target\release'

# --- 1. Build -----------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host 'Building release binaries (cargo build --release --workspace)...'
    Push-Location $repoRoot
    try {
        & cargo build --release --workspace
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}

# --- 2. Validate required artifacts -------------------------------------------
$artifacts = @('svg-converter.exe', 'svg-converterw.exe', 'svg_converter_shell.dll')
foreach ($name in $artifacts) {
    $path = Join-Path $releaseDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing build artifact: $path. Run without -SkipBuild first."
    }
}
if (-not (Test-Path -LiteralPath $manifestSrc)) {
    throw "Missing manifest: $manifestSrc"
}

# --- 3. Validate manifest XML well-formedness ---------------------------------
try {
    [xml]$manifestXml = Get-Content -LiteralPath $manifestSrc -Raw
    Write-Host "AppxManifest.xml is well-formed (package: $($manifestXml.Package.Identity.Name))."
} catch {
    throw "AppxManifest.xml is not well-formed XML: $_"
}

# --- 4. Stage the external location -------------------------------------------
$assetsDir = Join-Path $InstallDir 'Assets'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

foreach ($name in $artifacts) {
    Copy-Item -LiteralPath (Join-Path $releaseDir $name) -Destination $InstallDir -Force
}
Copy-Item -LiteralPath $manifestSrc -Destination (Join-Path $InstallDir 'AppxManifest.xml') -Force

# --- 5. Generate MSIX logo assets ---------------------------------------------
# Shared with build-installer.ps1 (see scripts/Common.ps1).
New-SvgConverterLogos -AssetsDir $assetsDir

Write-Host ''
Write-Host "Sparse package staged at: $InstallDir"
Write-Host 'Next steps (run these yourself):'
Write-Host '  1. Enable Developer Mode (Settings > Privacy & security > For developers).'
Write-Host "  2. Register:  .\scripts\install-sparse-package.ps1 -ExternalLocation `"$InstallDir`""
Write-Host '  3. Right-click any .svg file -> Convert SVG (in the primary Windows 11 menu).'
