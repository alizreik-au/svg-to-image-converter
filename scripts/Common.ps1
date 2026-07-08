#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for the SVG Converter packaging/installer scripts.

.DESCRIPTION
    Dot-source this file to reuse:
      * Test-Administrator      - is the current session elevated?
      * Find-WindowsSdkTool     - locate a Windows SDK tool (makeappx/signtool).
      * New-SvgConverterLogos   - generate the MSIX StoreLogo/Square logos.

    This file only defines functions; it performs no actions when sourced.
#>

function Test-Administrator {
    <#
    .SYNOPSIS
        Returns $true if the current PowerShell session is elevated.
    #>
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Find-WindowsSdkTool {
    <#
    .SYNOPSIS
        Locate a Windows SDK command-line tool (e.g. makeappx.exe, signtool.exe).

    .DESCRIPTION
        Searches, in order:
          1. The current PATH (Get-Command).
          2. C:\Program Files (x86)\Windows Kits\10\bin\<version>\<arch>\<tool>,
             preferring the newest SDK version and an architecture that matches
             the current process (falling back to x64/x86).

        Throws if the tool cannot be found so callers can surface a clear
        "install the Windows SDK" message.

    .PARAMETER Name
        Tool file name, e.g. 'makeappx.exe'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $onPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $archPref = switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { @('arm64', 'x64', 'x86') }
        'AMD64' { @('x64', 'x86') }
        'x86'   { @('x86', 'x64') }
        default { @('x64', 'x86') }
    }

    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($root in $roots) {
        $versionDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending
        foreach ($vd in $versionDirs) {
            foreach ($arch in $archPref) {
                $candidate = Join-Path $vd.FullName (Join-Path $arch $Name)
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
        }
    }

    throw "Could not find $Name. Install the Windows 10/11 SDK (includes makeappx.exe and signtool.exe) or add it to PATH."
}

function New-SvgConverterLogos {
    <#
    .SYNOPSIS
        Generate the MSIX logo PNGs (StoreLogo 50x50, Square44x44, Square150x150)
        into the given Assets directory using System.Drawing.

    .DESCRIPTION
        No image binaries are committed to the repo; they are produced at build
        time so both the sparse and full packaging paths share one implementation.

    .PARAMETER AssetsDir
        Target directory. Created if missing. Receives StoreLogo.png,
        Square44x44Logo.png, and Square150x150Logo.png.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $AssetsDir
    )

    Add-Type -AssemblyName System.Drawing
    New-Item -ItemType Directory -Force -Path $AssetsDir | Out-Null

    function New-LogoPng {
        param([int] $Size, [string] $Path)

        $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.Clear([System.Drawing.Color]::Transparent)

            $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
            $c1 = [System.Drawing.Color]::FromArgb(255, 79, 70, 229)   # #4F46E5
            $c2 = [System.Drawing.Color]::FromArgb(255, 6, 182, 212)   # #06B6D4
            $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 45.0)
            $g.FillRectangle($brush, $rect)

            # White circle.
            $r = [int]($Size * 0.42)
            $cx = [int]($Size * 0.5)
            $cy = [int]($Size * 0.42)
            $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(230, 255, 255, 255))
            $g.FillEllipse($white, ($cx - $r / 2), ($cy - $r / 2), $r, $r)

            # Amber triangle.
            $amber = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 245, 158, 11))
            $pts = @(
                (New-Object System.Drawing.Point([int]($Size * 0.30), [int]($Size * 0.74))),
                (New-Object System.Drawing.Point([int]($Size * 0.50), [int]($Size * 0.52))),
                (New-Object System.Drawing.Point([int]($Size * 0.70), [int]($Size * 0.74)))
            )
            $g.FillPolygon($amber, $pts)

            $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $g.Dispose()
            $bmp.Dispose()
        }
    }

    New-LogoPng -Size 50  -Path (Join-Path $AssetsDir 'StoreLogo.png')
    New-LogoPng -Size 44  -Path (Join-Path $AssetsDir 'Square44x44Logo.png')
    New-LogoPng -Size 150 -Path (Join-Path $AssetsDir 'Square150x150Logo.png')
}
