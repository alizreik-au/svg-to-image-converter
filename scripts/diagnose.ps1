#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses why the "Convert SVG" right-click action might do nothing, and
    clearly separates a broken CORE ENGINE from broken HANDLER WIRING.

.DESCRIPTION
    Read-only with respect to system state: it does NOT change the registry,
    Appx packages, or the signing certificate. It:

      1. Locates the installed SVG Converter binaries (MSIX package under
         C:\Program Files\WindowsApps, a Classic per-user/machine install, or the
         repo's target\release build).
      2. Reports the packaged (MSIX) Windows 11 handler. As of the in-process
         fix, the handler converts INSIDE the DLL (svg_converter_shell.dll) and
         never launches an executable, so there is no exe path to resolve for it.
      3. Reports the legacy registry cascade (Classic mode), which DOES shell out
         to a normal, non-WindowsApps copy of the exe.
      4. Proves the CORE ENGINE works by running svg-converter.exe against a
         temp SVG -- using a copy that is NOT under WindowsApps (a repo/Classic
         copy, or a temp copy of the packaged exe). Directly executing a
         WindowsApps exe from a normal shell is denied by design (ERROR_ACCESS_
         DENIED / "Access is denied") and is NOT the bug.
      5. Optionally enables file logging and prints the diagnostics log tail.

    Interpreting results:
      * Core engine OK + menu still does nothing  -> handler wiring/registration.
        Enable logging (-EnableLogging), reproduce from Explorer, then -ShowLog.
      * Core engine FAILS                          -> fix the CLI/render pipeline
        first; the menu cannot work until it does.

.PARAMETER InstallDir
    Explicit folder holding the binaries/DLL. Overrides auto-detection.

.PARAMETER EnableLogging
    Create %LOCALAPPDATA%\SvgConverter\diagnostics.on so both the DLL handler and
    the exe write to %LOCALAPPDATA%\SvgConverter\logs\svg-converter.log. Takes
    effect immediately (no Explorer restart needed).

.PARAMETER DisableLogging
    Remove the diagnostics sentinel file.

.PARAMETER ShowLog
    Print the last lines of the diagnostics log (if any).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\diagnose.ps1

.EXAMPLE
    # Turn logging on, right-click a .svg in Explorer to reproduce, then:
    .\scripts\diagnose.ps1 -EnableLogging
    .\scripts\diagnose.ps1 -ShowLog
#>
[CmdletBinding()]
param(
    [string] $InstallDir,
    [switch] $EnableLogging,
    [switch] $DisableLogging,
    [switch] $ShowLog
)

$ErrorActionPreference = 'Stop'

$packageName = 'SvgConverter.ContextMenu'
$dllName = 'svg_converter_shell.dll'
$guiExe = 'svg-converterw.exe'
$consoleExe = 'svg-converter.exe'

$diagBase = Join-Path $env:LOCALAPPDATA 'SvgConverter'
$sentinel = Join-Path $diagBase 'diagnostics.on'
$logPath = Join-Path $diagBase 'logs\svg-converter.log'

function Write-Section {
    param([string] $Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Test-IsWindowsApps {
    param([string] $Path)
    return ($Path -like '*\WindowsApps\*') -or ($Path -like '*\WindowsApps')
}

function Get-CandidateDirs {
    $dirs = New-Object System.Collections.Generic.List[string]

    if ($InstallDir) { $dirs.Add($InstallDir) }

    # MSIX (sparse or full) package install location -> under WindowsApps.
    $pkg = Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($pkg -and $pkg.InstallLocation) { $dirs.Add($pkg.InstallLocation) }

    # Classic installs (normal, executable directories).
    $dirs.Add((Join-Path $env:LOCALAPPDATA 'Programs\SvgConverter'))
    $dirs.Add('C:\Program Files\SvgConverter')

    # Repo build output (developer machine).
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $dirs.Add((Join-Path $repoRoot 'target\release'))

    return $dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

function Get-RunnableConsoleExe {
    <#
        Return a console svg-converter.exe that can actually be executed from a
        normal shell. Prefers a non-WindowsApps copy; if only the packaged copy
        exists, copies it to a temp folder (WindowsApps exec is ACL-denied).
        Returns a PSCustomObject { Path; Origin; TempDir } or $null.
    #>
    param([string[]] $Dirs)

    foreach ($dir in $Dirs) {
        $exe = Join-Path $dir $consoleExe
        if ((Test-Path -LiteralPath $exe) -and -not (Test-IsWindowsApps $dir)) {
            return [pscustomobject]@{ Path = $exe; Origin = $dir; TempDir = $null }
        }
    }

    foreach ($dir in $Dirs) {
        $exe = Join-Path $dir $consoleExe
        if ((Test-Path -LiteralPath $exe) -and (Test-IsWindowsApps $dir)) {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("svgdiag-exe-" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            $dst = Join-Path $tmp $consoleExe
            Copy-Item -LiteralPath $exe -Destination $dst -Force
            return [pscustomobject]@{ Path = $dst; Origin = "$dir (copied to temp; WindowsApps exec is denied by design)"; TempDir = $tmp }
        }
    }

    return $null
}

# --- 0. Logging toggles (our own app folder only) ----------------------------
if ($EnableLogging) {
    New-Item -ItemType Directory -Force -Path $diagBase | Out-Null
    Set-Content -LiteralPath $sentinel -Value '' -NoNewline
    Write-Host "Diagnostics logging ENABLED (sentinel: $sentinel)."
    Write-Host 'Reproduce from Explorer, then run this script again with -ShowLog.'
}
if ($DisableLogging) {
    Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
    Write-Host "Diagnostics logging disabled (removed $sentinel)."
}

# --- 1. Locate binaries -------------------------------------------------------
Write-Section 'Installed binaries'
$dirs = @(Get-CandidateDirs)
if ($dirs.Count -eq 0) {
    Write-Warning 'No SVG Converter install directory found (MSIX, Classic, or target\release).'
} else {
    foreach ($dir in $dirs) {
        $have = @()
        foreach ($n in @($consoleExe, $guiExe, $dllName)) {
            if (Test-Path -LiteralPath (Join-Path $dir $n)) { $have += $n }
        }
        $tag = if (Test-IsWindowsApps $dir) { '  [packaged / WindowsApps]' } else { '' }
        Write-Host ("{0}{1}`n    present: {2}" -f $dir, $tag, ($(if ($have) { $have -join ', ' } else { '(none)' })))
    }
}

# --- 2. Packaged (MSIX) Windows 11 handler -----------------------------------
Write-Section 'Packaged (MSIX) handler'
$pkgDir = $dirs | Where-Object { (Test-IsWindowsApps $_) -and (Test-Path -LiteralPath (Join-Path $_ $dllName)) } |
    Select-Object -First 1
if ($pkgDir) {
    Write-Host "Handler DLL present: $(Join-Path $pkgDir $dllName)"
    Write-Host 'This handler now converts IN-PROCESS (inside the DLL). It does NOT'
    Write-Host 'launch svg-converterw.exe, so there is no exe path to resolve and the'
    Write-Host 'WindowsApps CreateProcessW/ERROR_ACCESS_DENIED problem no longer applies.'
} else {
    Write-Host 'No packaged handler DLL found under WindowsApps.'
    Write-Host '(Expected if you use the Classic/registry menu only.)'
}

# --- 3. Legacy registry cascade (Classic mode) -------------------------------
Write-Section 'Legacy registry context menu'
$regBases = @(
    'HKCU:\Software\Classes\SystemFileAssociations\.svg\shell\SvgConverter',
    'HKLM:\Software\Classes\SystemFileAssociations\.svg\shell\SvgConverter'
)
$foundReg = $false
foreach ($rb in $regBases) {
    if (Test-Path -LiteralPath $rb) {
        $foundReg = $true
        Write-Host "Present: $rb"
        $quickCmd = Join-Path $rb 'shell\01_quick_png\command'
        if (Test-Path -LiteralPath $quickCmd) {
            $val = (Get-ItemProperty -LiteralPath $quickCmd).'(default)'
            Write-Host "    Quick PNG command: $val"
            Write-Host '    (This path shells out to a non-WindowsApps exe copy, which is fine.)'
        }
    }
}
if (-not $foundReg) {
    Write-Host 'No legacy registry menu found (expected if you only use the Win11 MSIX package).'
}

# --- 4. Core engine check (never executes the WindowsApps copy) --------------
Write-Section 'Core engine (runs a non-WindowsApps svg-converter.exe)'
$runnable = Get-RunnableConsoleExe -Dirs $dirs
if (-not $runnable) {
    Write-Warning "No runnable svg-converter.exe found; cannot test the core engine."
} else {
    Write-Host "Using: $($runnable.Path)"
    Write-Host "Origin: $($runnable.Origin)"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("svgdiag-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $testSvg = Join-Path $tmp 'diagnose test.svg'
        $svgBody = '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#4F46E5"/><circle cx="32" cy="32" r="20" fill="#F59E0B"/></svg>'
        Set-Content -LiteralPath $testSvg -Value $svgBody -Encoding UTF8

        Write-Host "Running: `"$($runnable.Path)`" convert `"$testSvg`" -f png -s 1.0 -v"
        & $runnable.Path convert "$testSvg" -f png -s 1.0 -v
        $code = $LASTEXITCODE
        $outPng = Join-Path $tmp 'diagnose test.png'
        if ($code -eq 0 -and (Test-Path -LiteralPath $outPng)) {
            $len = (Get-Item -LiteralPath $outPng).Length
            Write-Host "CORE ENGINE OK: produced $outPng ($len bytes)." -ForegroundColor Green
            Write-Host 'The packaged handler links this same core in-process, so if the menu'
            Write-Host 'still does nothing the issue is registration, not conversion.'
        } else {
            Write-Warning "CORE ENGINE FAILED (exit=$code, output present=$([bool](Test-Path -LiteralPath $outPng)))."
            Write-Warning 'Fix the CLI/render pipeline before investigating the menu.'
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if ($runnable.TempDir) {
            Remove-Item -LiteralPath $runnable.TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- 5. Appx registration -----------------------------------------------------
Write-Section 'Appx package registration'
$pkg = Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) {
    Write-Host "Registered: $($pkg.PackageFullName)"
    Write-Host "    InstallLocation: $($pkg.InstallLocation)"
} else {
    Write-Host "No '$packageName' Appx package registered for the current user."
    Write-Host '(Expected if you use the Classic/registry menu only.)'
}

# --- 6. Diagnostics log -------------------------------------------------------
Write-Section 'Diagnostics log'
Write-Host "Sentinel: $sentinel (exists: $(Test-Path -LiteralPath $sentinel))"
Write-Host "Log file: $logPath (exists: $(Test-Path -LiteralPath $logPath))"
if ($ShowLog) {
    if (Test-Path -LiteralPath $logPath) {
        Write-Host '--- last 40 lines ---'
        Get-Content -LiteralPath $logPath -Tail 40
    } else {
        Write-Host 'No log yet. Run with -EnableLogging, reproduce from Explorer, then -ShowLog.'
    }
}

Write-Host ''
Write-Host 'Diagnosis complete.' -ForegroundColor Cyan
