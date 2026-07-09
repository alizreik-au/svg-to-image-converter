#Requires -Version 5.1
<#
.SYNOPSIS
    Installs SVG Converter for the current user: binaries + the "Convert SVG"
    right-click menu for .svg files (Windows 10 and Windows 11).

.DESCRIPTION
    This is the single entry point an end user runs. Two modes:

    -Mode Msix (default, recommended)
        Trusts the bundled signing certificate (one-time, needs a UAC prompt),
        then installs the self-contained SvgConverter MSIX. Gives a real
        "Installed apps" entry with one-click uninstall and enables the Windows 11
        primary context menu + the Windows 10 classic menu from one package.

    -Mode Classic (fallback, no MSIX / no certificate / no Developer Mode)
        Copies the binaries to a per-user (or machine) folder, registers the
        cascading registry context menu (works on Win10 and, under "Show more
        options", on Win11), and adds an "Installed apps" uninstall entry.

    Certificate trust (Msix mode) and machine-wide Classic installs require
    elevation; the script requests it with a UAC prompt only for the step that
    needs it. A per-user install needs no admin rights.

.PARAMETER Mode
    'Msix' (default) or 'Classic'.

.PARAMETER Scope
    'User' (default, no admin) or 'Machine' (all users, requires elevation).

.PARAMETER MsixPath
    Path to the .msix. Default: the SvgConverter-*.msix beside this script.

.PARAMETER CertPath
    Path to the .cer to trust before installing an MSIX signed by a self-signed
    certificate. Default: the SvgConverter-*.cer beside this script. Ignored if
    the package is signed by an already-trusted (production) certificate.

.PARAMETER BinDir
    (Classic mode) Folder containing the binaries to install. Default: the 'bin'
    folder beside this script, falling back to the repo's target\release.

.PARAMETER WithLegacyMenu
    (Msix mode) Also register the registry-based "Show more options" cascade menu
    using binaries copied to %LOCALAPPDATA%\Programs\SvgConverter. On by default
    for reliability when the packaged Win11 handler is slow to refresh.

.PARAMETER SkipLegacyMenu
    (Msix mode) Do not register the registry fallback menu.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-SvgConverter.ps1
    # Recommended: installs the signed MSIX for the current user.

.EXAMPLE
    .\Install-SvgConverter.ps1 -Mode Classic
    # No MSIX/cert: portable per-user install + registry menu.
#>
[CmdletBinding()]
param(
    [ValidateSet('Msix', 'Classic')]
    [string] $Mode = 'Msix',

    [ValidateSet('User', 'Machine')]
    [string] $Scope = 'User',

    [string] $MsixPath,
    [string] $CertPath,
    [string] $BinDir,
    [switch] $WithLegacyMenu,
    [switch] $SkipLegacyMenu
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$commonPath = Join-Path $scriptDir 'Common.ps1'
if (Test-Path -LiteralPath $commonPath) {
    . $commonPath
} else {
    # Minimal fallback if Common.ps1 was not shipped alongside.
    function Test-Administrator {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    }
}

function Find-Single {
    param([string] $Dir, [string] $Pattern)
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    $hit = Get-ChildItem -LiteralPath $Dir -Filter $Pattern -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Invoke-Elevated {
    <#
    Run a single scriptblock body (as text) in an elevated PowerShell and wait.
    Used only for the specific steps that require admin (cert trust, HKLM/Program
    Files), so a per-user MSIX install still registers for the real user.
    #>
    param([string] $CommandText)

    $bytes = [Text.Encoding]::Unicode.GetBytes($CommandText)
    $encoded = [Convert]::ToBase64String($bytes)
    $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    if ($proc.ExitCode -ne 0) {
        throw "Elevated step failed (exit $($proc.ExitCode)). Installation aborted."
    }
}

function Install-LegacyMenuFallback {
  param([string] $SourceBinDir)

  $menuScript = @(
    (Join-Path $scriptDir 'install-context-menu.ps1'),
    (Join-Path $scriptDir 'scripts\install-context-menu.ps1')
  ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $menuScript) {
    Write-Warning 'install-context-menu.ps1 not found; skipping legacy menu fallback.'
    return
  }

  $installDir = Join-Path $env:LOCALAPPDATA 'Programs\SvgConverter'
  New-Item -ItemType Directory -Force -Path $installDir | Out-Null
  foreach ($name in @('svg-converter.exe', 'svg-converterw.exe', 'svg_converter_shell.dll')) {
    $src = Join-Path $SourceBinDir $name
    if (Test-Path -LiteralPath $src) {
      Copy-Item -LiteralPath $src -Destination $installDir -Force
    }
  }
  & $menuScript -InstallDir $installDir -PerUser
  Write-Host "Legacy registry menu registered at: $installDir"
  Write-Host '(Win11: under "Show more options" -> Convert SVG.)'
}

function Install-Msix {
    # --- Locate the package + optional cert ---
    if (-not $MsixPath) { $MsixPath = Find-Single -Dir $scriptDir -Pattern 'SvgConverter-*.msix' }
    if (-not $MsixPath -or -not (Test-Path -LiteralPath $MsixPath)) {
        throw "Could not find an .msix. Place SvgConverter-*.msix next to this script or pass -MsixPath. To install without a package, use -Mode Classic."
    }
    if (-not $CertPath) { $CertPath = Find-Single -Dir $scriptDir -Pattern 'SvgConverter-*.cer' }

    Write-Host "Installing SVG Converter (MSIX): $MsixPath"

    # --- Trust the self-signed cert if provided and not already trusted ---
    if ($CertPath -and (Test-Path -LiteralPath $CertPath)) {
        $cer = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CertPath
        $thumb = $cer.Thumbprint
        $alreadyTrusted = Test-Path -LiteralPath "Cert:\LocalMachine\Root\$thumb"
        if ($alreadyTrusted) {
            Write-Host 'Signing certificate is already trusted.'
        } else {
            Write-Host 'Trusting the signing certificate (a UAC prompt will appear)...'
            $cerEsc = $CertPath.Replace("'", "''")
            $trustCmd = @"
Import-Certificate -FilePath '$cerEsc' -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
Import-Certificate -FilePath '$cerEsc' -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
"@
            Invoke-Elevated -CommandText $trustCmd
            Write-Host 'Certificate trusted.'
        }
    } else {
        Write-Host 'No .cer supplied; assuming the package is signed by a trusted certificate.'
    }

    # --- Register the package for the CURRENT user (no elevation) ---
    Write-Host 'Registering the package for the current user...'
    Add-AppxPackage -Path $MsixPath

    Write-Host ''
    Write-Host 'SVG Converter installed.'
    Write-Host 'Right-click any .svg file -> look for Quick: PNG (1x) and other Convert actions.'
    Write-Host 'If the menu does not appear immediately, restart Explorer:  Stop-Process -Name explorer -Force'
    Write-Host 'To uninstall: Settings > Apps > Installed apps > SVG Converter, or run Uninstall-SvgConverter.ps1.'

    $wantLegacy = (-not $SkipLegacyMenu) -and ($WithLegacyMenu -or -not $PSBoundParameters.ContainsKey('WithLegacyMenu'))
    if ($wantLegacy) {
      $legacyBin = @(
        (Join-Path $scriptDir 'bin'),
        (Join-Path (Split-Path -Parent $scriptDir) 'target\release')
      ) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'svg-converter.exe') } | Select-Object -First 1
      if ($legacyBin) {
        Write-Host ''
        Write-Host 'Registering legacy registry menu fallback (Show more options)...'
        Install-LegacyMenuFallback -SourceBinDir $legacyBin
      } else {
        Write-Warning 'Legacy menu fallback skipped: bin\ folder with svg-converter.exe not found beside installer.'
      }
    }
}

function Install-Classic {
    # --- Resolve binaries + legacy menu script ---
    if (-not $BinDir) {
        $candidates = @(
            (Join-Path $scriptDir 'bin'),
            (Join-Path (Split-Path -Parent $scriptDir) 'target\release')
        )
        $BinDir = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'svg-converter.exe') } | Select-Object -First 1
    }
    if (-not $BinDir -or -not (Test-Path -LiteralPath (Join-Path $BinDir 'svg-converter.exe'))) {
        throw "Could not find binaries for Classic install. Pass -BinDir pointing at a folder with svg-converter.exe."
    }

    $menuScript = @(
        (Join-Path $scriptDir 'install-context-menu.ps1'),
        (Join-Path $scriptDir 'scripts\install-context-menu.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $menuScript) {
        throw "install-context-menu.ps1 not found next to this script."
    }

    $machine = ($Scope -eq 'Machine')
    if ($machine -and -not (Test-Administrator)) {
        # Re-run the whole classic machine install elevated.
        Write-Host 'Machine-wide install requires elevation; requesting it...'
        $self = $MyInvocation.MyCommand.Path
        $selfEsc = $self.Replace("'", "''")
        $binEsc = $BinDir.Replace("'", "''")
        Invoke-Elevated -CommandText "& '$selfEsc' -Mode Classic -Scope Machine -BinDir '$binEsc'"
        return
    }

    $installDir = if ($machine) { 'C:\Program Files\SvgConverter' } else { Join-Path $env:LOCALAPPDATA 'Programs\SvgConverter' }
    Write-Host "Installing SVG Converter (Classic) to: $installDir"
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    foreach ($name in @('svg-converter.exe', 'svg-converterw.exe', 'svg_converter_shell.dll')) {
        $src = Join-Path $BinDir $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $installDir -Force
        }
    }

    # Register the cascading registry context menu.
    if ($machine) {
        & $menuScript -InstallDir $installDir
    } else {
        & $menuScript -InstallDir $installDir -PerUser
    }

    # Add an "Installed apps" (Add/Remove Programs) entry so users can uninstall
    # from Settings as well as via Uninstall-SvgConverter.ps1.
    Register-ClassicArp -InstallDir $installDir -Machine:$machine

    Write-Host ''
    Write-Host 'SVG Converter installed (Classic).'
    Write-Host 'Right-click any .svg file -> Convert SVG (Windows 11: under "Show more options").'
    Write-Host 'To uninstall: Settings > Apps > Installed apps > SVG Converter, or run Uninstall-SvgConverter.ps1 -Mode Classic.'
}

function Register-ClassicArp {
    param([string] $InstallDir, [switch] $Machine)

    $root = if ($Machine) { 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SvgConverter' }
            else { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SvgConverter' }
    New-Item -Path $root -Force | Out-Null

    $uninstaller = @(
        (Join-Path $scriptDir 'Uninstall-SvgConverter.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    $scopeArg = if ($Machine) { 'Machine' } else { 'User' }
    $uninstallCmd = if ($uninstaller) {
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstaller`" -Mode Classic -Scope $scopeArg"
    } else {
        "powershell.exe -NoProfile -Command `"Remove-Item -Recurse -Force '$InstallDir'`""
    }

    Set-ItemProperty -LiteralPath $root -Name 'DisplayName' -Value 'SVG Converter'
    Set-ItemProperty -LiteralPath $root -Name 'DisplayVersion' -Value '1.0.0'
    Set-ItemProperty -LiteralPath $root -Name 'Publisher' -Value 'SVG Converter'
    Set-ItemProperty -LiteralPath $root -Name 'InstallLocation' -Value $InstallDir
    Set-ItemProperty -LiteralPath $root -Name 'DisplayIcon' -Value (Join-Path $InstallDir 'svg-converter.exe')
    Set-ItemProperty -LiteralPath $root -Name 'UninstallString' -Value $uninstallCmd
    Set-ItemProperty -LiteralPath $root -Name 'NoModify' -Value 1 -Type DWord
    Set-ItemProperty -LiteralPath $root -Name 'NoRepair' -Value 1 -Type DWord
}

switch ($Mode) {
    'Msix' { Install-Msix }
    'Classic' { Install-Classic }
    default { throw "Unknown mode: $Mode" }
}
