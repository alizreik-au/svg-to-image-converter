#Requires -Version 5.1
<#
.SYNOPSIS
    Removes SVG Converter context menu registry entries.

.DESCRIPTION
    Phase 2 implementation. Deletes the SvgConverter cascade created by
    install-context-menu.ps1 from:
        <ClassesRoot>\SystemFileAssociations\.svg\shell\SvgConverter

    Idempotent: succeeds even if nothing is installed. Machine-wide removal
    (HKLM) requires elevation; use -PerUser to remove the HKCU registration.

.PARAMETER PerUser
    Remove the HKCU\Software\Classes registration instead of HKLM.

.EXAMPLE
    .\uninstall-context-menu.ps1

.EXAMPLE
    .\uninstall-context-menu.ps1 -PerUser
#>
[CmdletBinding()]
param(
    [switch] $PerUser
)

$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if ($PerUser) {
    $classesRoot = 'HKCU:\Software\Classes'
} else {
    if (-not (Test-Administrator)) {
        throw 'Machine-wide uninstall requires an elevated PowerShell. Re-run as Administrator, or use -PerUser.'
    }
    $classesRoot = 'HKLM:\Software\Classes'
}

$base = "$classesRoot\SystemFileAssociations\.svg\shell\SvgConverter"
$scope = if ($PerUser) { 'current user (HKCU)' } else { 'all users (HKLM)' }

if (Test-Path -LiteralPath $base) {
    Remove-Item -LiteralPath $base -Recurse -Force
    Write-Host "SVG Converter context menu removed for $scope."
} else {
    Write-Host "SVG Converter context menu was not present for $scope. Nothing to do."
}
