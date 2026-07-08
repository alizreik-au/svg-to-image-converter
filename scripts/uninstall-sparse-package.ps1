#Requires -Version 5.1
<#
.SYNOPSIS
    Unregisters the SVG Converter sparse package, removing the "Convert SVG"
    entry from the Windows 11 primary context menu.

.DESCRIPTION
    Phase 4. Removes the identity package registered by
    install-sparse-package.ps1. This does not delete the external location
    (binaries); delete that folder separately if desired. Idempotent: succeeds
    even if the package is not currently registered.

.PARAMETER PackageName
    The package Identity/Name from AppxManifest.xml.
    Default: SvgConverter.ContextMenu

.EXAMPLE
    .\scripts\uninstall-sparse-package.ps1
#>
[CmdletBinding()]
param(
    [string] $PackageName = 'SvgConverter.ContextMenu'
)

$ErrorActionPreference = 'Stop'

$pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($null -eq $pkg) {
    Write-Host "Package '$PackageName' is not registered for the current user. Nothing to do."
    return
}

foreach ($p in $pkg) {
    Write-Host "Removing package: $($p.PackageFullName)"
    Remove-AppxPackage -Package $p.PackageFullName
}

Write-Host 'Removed. Restart Explorer if the menu entry lingers:  Stop-Process -Name explorer -Force'
