#Requires -Version 5.1
<#
.SYNOPSIS
    Registers the SVG Converter sparse package so the "Convert SVG" command
    appears in the Windows 11 primary (compact) right-click menu for .svg files.

.DESCRIPTION
    Phase 4 (Windows 11 primary context menu). This performs a per-user DEV
    registration of the loose AppxManifest.xml with an external location:

        Add-AppxPackage -Register <ExternalLocation>\AppxManifest.xml `
                        -ExternalLocation <ExternalLocation>

    Registering a loose manifest requires Developer Mode (or sideloading) to be
    enabled. For distribution you instead pack + sign an .msix with a trusted
    certificate and register that (see README "Production signing").

    Run scripts/build-sparse-package.ps1 first to stage <ExternalLocation>.

.PARAMETER ExternalLocation
    The staged folder containing svg-converterw.exe, svg_converter_shell.dll,
    AppxManifest.xml, and Assets\. Must match what build-sparse-package.ps1 used.
    Default: %LOCALAPPDATA%\Programs\SvgConverter

.EXAMPLE
    .\scripts\install-sparse-package.ps1
    .\scripts\install-sparse-package.ps1 -ExternalLocation "C:\Program Files\SvgConverter"
#>
[CmdletBinding()]
param(
    [string] $ExternalLocation = (Join-Path $env:LOCALAPPDATA 'Programs\SvgConverter')
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $ExternalLocation 'AppxManifest.xml'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw "AppxManifest.xml not found at: $manifest. Run scripts\build-sparse-package.ps1 first."
}
$dll = Join-Path $ExternalLocation 'svg_converter_shell.dll'
if (-not (Test-Path -LiteralPath $dll)) {
    throw "svg_converter_shell.dll not found at: $dll. Run scripts\build-sparse-package.ps1 first."
}

# --- Developer Mode / sideloading check --------------------------------------
$devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devMode = 0
if (Test-Path -LiteralPath $devModeKey) {
    $devMode = (Get-ItemProperty -LiteralPath $devModeKey -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
}
if (-not $devMode) {
    Write-Warning 'Developer Mode does not appear to be enabled.'
    Write-Warning 'Registering a loose (unsigned) manifest requires it: Settings > Privacy & security > For developers > Developer Mode = On.'
    Write-Warning 'Continuing anyway; if registration fails with 0x80073CFF, enable Developer Mode and retry.'
}

# --- Register -----------------------------------------------------------------
Write-Host "Registering sparse package from: $manifest"
Write-Host "External location:              $ExternalLocation"

Add-AppxPackage -Register $manifest -ExternalLocation $ExternalLocation

Write-Host ''
Write-Host 'Registered. Right-click a .svg file -> Convert SVG (primary Windows 11 menu).'
Write-Host 'If it does not appear immediately, restart Explorer:  Stop-Process -Name explorer -Force'
Write-Host 'To remove:  .\scripts\uninstall-sparse-package.ps1'
