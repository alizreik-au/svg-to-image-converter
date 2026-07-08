#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls SVG Converter (MSIX or Classic), removing binaries, the context
    menu, and any "Installed apps" entry.

.DESCRIPTION
    Matching uninstaller for Install-SvgConverter.ps1.

    -Mode Msix (default)
        Removes the SvgConverter MSIX package for the current user. Optionally
        removes the dev signing certificate from the trusted stores with
        -RemoveCert (needs elevation).

    -Mode Classic
        Removes the registry context menu, deletes the install folder, and
        removes the "Installed apps" uninstall entry. Machine-wide removal needs
        elevation; a per-user removal does not.

    Idempotent: succeeds even if nothing is installed.

.PARAMETER Mode
    'Msix' (default) or 'Classic'.

.PARAMETER Scope
    (Classic) 'User' (default) or 'Machine'.

.PARAMETER PackageName
    (Msix) Appx package Identity/Name. Default: SvgConverter.ContextMenu.

.PARAMETER RemoveCert
    (Msix) Also remove the dev signing certificate from LocalMachine trusted
    stores (needs elevation). Off by default so other test packages are unaffected.

.PARAMETER InstallDir
    (Classic) Install folder to delete. Default: matches the Scope.

.EXAMPLE
    .\Uninstall-SvgConverter.ps1
    # Removes the MSIX package for the current user.

.EXAMPLE
    .\Uninstall-SvgConverter.ps1 -Mode Classic
#>
[CmdletBinding()]
param(
    [ValidateSet('Msix', 'Classic')]
    [string] $Mode = 'Msix',

    [ValidateSet('User', 'Machine')]
    [string] $Scope = 'User',

    [string] $PackageName = 'SvgConverter.ContextMenu',
    [switch] $RemoveCert,
    [string] $InstallDir
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$commonPath = Join-Path $scriptDir 'Common.ps1'
if (Test-Path -LiteralPath $commonPath) {
    . $commonPath
} else {
    function Test-Administrator {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    }
}

function Invoke-Elevated {
    param([string] $CommandText)
    $bytes = [Text.Encoding]::Unicode.GetBytes($CommandText)
    $encoded = [Convert]::ToBase64String($bytes)
    $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    if ($proc.ExitCode -ne 0) {
        throw "Elevated step failed (exit $($proc.ExitCode))."
    }
}

function Uninstall-Msix {
    $pkgs = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if ($null -eq $pkgs) {
        Write-Host "Package '$PackageName' is not installed for the current user."
    } else {
        foreach ($p in $pkgs) {
            Write-Host "Removing package: $($p.PackageFullName)"
            Remove-AppxPackage -Package $p.PackageFullName
        }
        Write-Host 'Package removed.'
    }

    if ($RemoveCert) {
        Write-Host 'Removing dev signing certificate from trusted stores (a UAC prompt will appear)...'
        $subject = 'CN=SvgConverter Dev'
        $cmd = @"
Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPeople |
    Where-Object { `$_.Subject -eq '$subject' } |
    ForEach-Object { Remove-Item -LiteralPath `$_.PSPath -Force }
"@
        Invoke-Elevated -CommandText $cmd
        Write-Host 'Certificate removed.'
    }

    Write-Host 'Restart Explorer if the menu lingers:  Stop-Process -Name explorer -Force'
}

function Uninstall-Classic {
    $machine = ($Scope -eq 'Machine')
    if ($machine -and -not (Test-Administrator)) {
        Write-Host 'Machine-wide uninstall requires elevation; requesting it...'
        $self = $MyInvocation.MyCommand.Path
        $selfEsc = $self.Replace("'", "''")
        Invoke-Elevated -CommandText "& '$selfEsc' -Mode Classic -Scope Machine"
        return
    }

    if (-not $InstallDir) {
        $InstallDir = if ($machine) { 'C:\Program Files\SvgConverter' } else { Join-Path $env:LOCALAPPDATA 'Programs\SvgConverter' }
    }

    # Remove the registry context menu via the shipped script.
    $menuScript = @(
        (Join-Path $scriptDir 'uninstall-context-menu.ps1'),
        (Join-Path $scriptDir 'scripts\uninstall-context-menu.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($menuScript) {
        if ($machine) { & $menuScript } else { & $menuScript -PerUser }
    } else {
        Write-Warning 'uninstall-context-menu.ps1 not found; skipping registry menu removal.'
    }

    # Remove the "Installed apps" entry.
    $arp = if ($machine) { 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SvgConverter' }
           else { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SvgConverter' }
    if (Test-Path -LiteralPath $arp) { Remove-Item -LiteralPath $arp -Recurse -Force }

    # Delete the install folder.
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host "Removed install folder: $InstallDir"
    }

    Write-Host 'SVG Converter (Classic) uninstalled.'
}

switch ($Mode) {
    'Msix' { Uninstall-Msix }
    'Classic' { Uninstall-Classic }
    default { throw "Unknown mode: $Mode" }
}
