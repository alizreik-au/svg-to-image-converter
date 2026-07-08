#Requires -Version 5.1
<#
.SYNOPSIS
    Installs SVG Converter context menu entries for .svg files.

.DESCRIPTION
    Phase 2 implementation. Registers a cascading shell menu under:
        <ClassesRoot>\SystemFileAssociations\.svg\shell\SvgConverter\

    Layout (see PROJECT_PLAN.md §7.2):
        Convert SVG
          Quick: PNG (1x)          -> -f png -s 1.0
          PNG   > 3.0x / 2.0x / 1.0x / 0.5x
          JPEG  > 3.0x / 2.0x / 1.0x / 0.5x
          WebP  > 3.0x / 2.0x / 1.0x / 0.5x

    Machine-wide install writes to HKLM (requires elevation). Use -PerUser to
    write to HKCU with no admin rights. The script is idempotent: it clears any
    previous SvgConverter menu before recreating it.

.PARAMETER InstallDir
    Directory containing svg-converter.exe.

.PARAMETER PerUser
    Register under HKCU\Software\Classes instead of HKLM (no admin required).

.EXAMPLE
    .\install-context-menu.ps1 -InstallDir "C:\Program Files\SvgConverter"

.EXAMPLE
    .\install-context-menu.ps1 -InstallDir "$env:LOCALAPPDATA\Programs\SvgConverter" -PerUser
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $InstallDir,

    [switch] $PerUser
)

$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function New-RegKey {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
}

function Set-RegDefault {
    param([string] $Path, [string] $Value)
    New-RegKey -Path $Path
    Set-ItemProperty -LiteralPath $Path -Name '(default)' -Value $Value
}

function Set-RegString {
    param([string] $Path, [string] $Name, [string] $Value)
    New-RegKey -Path $Path
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

# --- Resolve binary ---------------------------------------------------------
$exe = Join-Path $InstallDir 'svg-converter.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "svg-converter.exe not found at: $exe"
}
$exe = (Resolve-Path -LiteralPath $exe).Path
$icon = "$exe,0"

# Prefer the no-console (GUI-subsystem) variant for menu commands so no console
# window flashes on invocation; fall back to the console exe if it is missing.
$exeMenu = Join-Path $InstallDir 'svg-converterw.exe'
if (Test-Path -LiteralPath $exeMenu) {
    $exeMenu = (Resolve-Path -LiteralPath $exeMenu).Path
} else {
    Write-Warning 'svg-converterw.exe not found; menu will use svg-converter.exe (a console window may briefly flash).'
    $exeMenu = $exe
}

# --- Choose registry root + elevation check ---------------------------------
if ($PerUser) {
    $classesRoot = 'HKCU:\Software\Classes'
} else {
    if (-not (Test-Administrator)) {
        throw 'Machine-wide install requires an elevated PowerShell. Re-run as Administrator, or use -PerUser.'
    }
    $classesRoot = 'HKLM:\Software\Classes'
}

$base = "$classesRoot\SystemFileAssociations\.svg\shell\SvgConverter"

# --- Idempotency: remove any previous menu ----------------------------------
if (Test-Path -LiteralPath $base) {
    Remove-Item -LiteralPath $base -Recurse -Force
}

# --- Format x scale matrix --------------------------------------------------
$formats = @(
    [pscustomobject]@{ Key = '02_png';  Label = 'PNG';  Flag = 'png'  },
    [pscustomobject]@{ Key = '03_jpeg'; Label = 'JPEG'; Flag = 'jpg'  },
    [pscustomobject]@{ Key = '04_webp'; Label = 'WebP'; Flag = 'webp' }
)
# Ordered largest-first; leading digit forces menu order.
$scales = @(
    [pscustomobject]@{ Key = '1_3x';   Label = '3.0x'; Value = '3.0' },
    [pscustomobject]@{ Key = '2_2x';   Label = '2.0x'; Value = '2.0' },
    [pscustomobject]@{ Key = '3_1x';   Label = '1.0x'; Value = '1.0' },
    [pscustomobject]@{ Key = '4_0.5x'; Label = '0.5x'; Value = '0.5' }
)

function Get-Command-Line {
    param([string] $Format, [string] $Scale)
    return ('"{0}" convert "%1" -f {1} -s {2} --quiet' -f $exeMenu, $Format, $Scale)
}

# --- Top-level cascade parent ("Convert SVG") -------------------------------
New-RegKey -Path $base
Set-RegString -Path $base -Name 'MUIVerb' -Value 'Convert SVG'
Set-RegString -Path $base -Name 'Icon' -Value $icon
# An (empty) SubCommands value tells Explorer to build the cascade from the
# child \shell subkeys below.
Set-RegString -Path $base -Name 'SubCommands' -Value ''

$baseShell = "$base\shell"
New-RegKey -Path $baseShell

# --- One-click default: Quick PNG 1x ----------------------------------------
$quick = "$baseShell\01_quick_png"
Set-RegString -Path $quick -Name 'MUIVerb' -Value 'Quick: PNG (1x)'
Set-RegString -Path $quick -Name 'Icon' -Value $icon
Set-RegDefault -Path "$quick\command" -Value (Get-Command-Line -Format 'png' -Scale '1.0')

# --- Format submenus, each cascading into the four scales --------------------
foreach ($format in $formats) {
    $formatKey = "$baseShell\$($format.Key)"
    Set-RegString -Path $formatKey -Name 'MUIVerb' -Value $format.Label
    Set-RegString -Path $formatKey -Name 'Icon' -Value $icon
    Set-RegString -Path $formatKey -Name 'SubCommands' -Value ''

    $formatShell = "$formatKey\shell"
    New-RegKey -Path $formatShell

    foreach ($scale in $scales) {
        $scaleKey = "$formatShell\$($scale.Key)"
        Set-RegString -Path $scaleKey -Name 'MUIVerb' -Value $scale.Label
        Set-RegString -Path $scaleKey -Name 'Icon' -Value $icon
        Set-RegDefault -Path "$scaleKey\command" -Value (Get-Command-Line -Format $format.Flag -Scale $scale.Value)
    }
}

$scope = if ($PerUser) { 'current user (HKCU)' } else { 'all users (HKLM)' }
Write-Host "SVG Converter context menu installed for $scope."
Write-Host "Binary: $exe"
Write-Host 'Right-click any .svg file -> Convert SVG (Windows 11: under "Show more options").'
