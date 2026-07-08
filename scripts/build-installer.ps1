#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the end-user installer for SVG Converter: a single, self-contained,
    signed MSIX package (SvgConverter-<version>-x64.msix) plus the trust
    certificate and the user-facing install/uninstall scripts.

.DESCRIPTION
    This is the reproducible "make the installer" entry point. It:

      1. Builds release binaries         (cargo build --release --workspace)
      2. Stages a FULL MSIX layout       (binaries + DLL + generated logos +
                                          packaging\full\AppxManifest.xml)
      3. Packs it with makeappx.exe      -> <OutputDir>\SvgConverter-<ver>-x64.msix
      4. Signs it with signtool.exe      (self-signed dev cert by default, or a
                                          real .pfx you supply for production)
      5. Assembles the distributable     (msix + .cer + Install/Uninstall scripts
                                          + INSTALL.md) in <OutputDir>

    Unlike the sparse package (scripts/build-sparse-package.ps1), the produced
    MSIX CONTAINS the binaries, so it installs a real "Installed apps" entry with
    one-click uninstall and needs no Developer Mode. The bundled IExplorerCommand
    handler drives BOTH the Windows 11 primary menu and the Windows 10 (1809+)
    classic menu.

    Output (default OutputDir = target\installer):
        SvgConverter-1.0.0.0-x64.msix     the installer artifact
        SvgConverter-1.0.0.0-x64.cer      public cert to trust (self-signed only)
        Install-SvgConverter.ps1          single user entry point
        Uninstall-SvgConverter.ps1        matching uninstaller
        INSTALL.md                        end-user guide

    The end user runs:  Install-SvgConverter.ps1   (or double-clicks the .msix
    after the cert is trusted).

.PARAMETER OutputDir
    Where to emit the installer artifacts. Default: <repo>\target\installer.

.PARAMETER Version
    Package version (4-part, e.g. 1.0.0.0). Must match the AppxManifest Identity
    version. Default: read from packaging\full\AppxManifest.xml.

.PARAMETER CertSubject
    Subject of the self-signed signing certificate. MUST equal the AppxManifest
    Identity/Publisher. Default: CN=SvgConverter Dev.

.PARAMETER PfxPath
    Path to a production code-signing .pfx. When supplied, the package is signed
    with it instead of generating a self-signed dev certificate.

.PARAMETER PfxPassword
    Password for -PfxPath (SecureString). Prompted if the .pfx needs one and this
    is omitted.

.PARAMETER SkipBuild
    Reuse existing target\release binaries instead of running cargo build.

.PARAMETER SkipSign
    Pack the MSIX but do not sign it (produces an unsigned .msix for validation
    only; an unsigned package cannot be installed).

.EXAMPLE
    .\scripts\build-installer.ps1
    # Signed dev MSIX + cert + scripts in target\installer.

.EXAMPLE
    .\scripts\build-installer.ps1 -PfxPath C:\certs\prod.pfx
    # Production-signed MSIX (Publisher in the manifest must match the pfx subject).
#>
[CmdletBinding()]
param(
    [string] $OutputDir,
    [string] $Version,
    [string] $CertSubject = 'CN=SvgConverter Dev',
    [string] $PfxPath,
    [System.Security.SecureString] $PfxPassword,
    [switch] $SkipBuild,
    [switch] $SkipSign
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repoRoot 'target\release'
$manifestSrc = Join-Path $repoRoot 'packaging\full\AppxManifest.xml'

if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'target\installer' }

# --- 1. Build ----------------------------------------------------------------
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

# --- 2. Validate inputs ------------------------------------------------------
$artifacts = @('svg-converter.exe', 'svg-converterw.exe', 'svg_converter_shell.dll')
foreach ($name in $artifacts) {
    $path = Join-Path $releaseDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing build artifact: $path. Run without -SkipBuild first."
    }
}
if (-not (Test-Path -LiteralPath $manifestSrc)) {
    throw "Missing full manifest: $manifestSrc"
}

# Validate + read identity from the manifest so the filename, version, and cert
# subject stay consistent with what actually ships.
try {
    [xml]$manifestXml = Get-Content -LiteralPath $manifestSrc -Raw
} catch {
    throw "packaging\full\AppxManifest.xml is not well-formed XML: $_"
}
$identity = $manifestXml.Package.Identity
$packageName = $identity.Name
$manifestVersion = $identity.Version
$manifestPublisher = $identity.Publisher
Write-Host "Manifest OK: $packageName $manifestVersion (Publisher $manifestPublisher)."

if (-not $Version) { $Version = $manifestVersion }
if (-not $PfxPath -and $CertSubject -ne $manifestPublisher) {
    Write-Warning "CertSubject '$CertSubject' does not match manifest Publisher '$manifestPublisher'."
    Write-Warning 'A self-signed package whose cert subject differs from the Publisher will fail to install.'
}

# --- 3. Stage the full-package layout ----------------------------------------
$stageDir = Join-Path $OutputDir 'pkg'
if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
$assetsDir = Join-Path $stageDir 'Assets'
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

foreach ($name in $artifacts) {
    Copy-Item -LiteralPath (Join-Path $releaseDir $name) -Destination $stageDir -Force
}
Copy-Item -LiteralPath $manifestSrc -Destination (Join-Path $stageDir 'AppxManifest.xml') -Force
New-SvgConverterLogos -AssetsDir $assetsDir

# --- 4. Pack the MSIX --------------------------------------------------------
$makeappx = Find-WindowsSdkTool -Name 'makeappx.exe'
$msixName = "SvgConverter-$Version-x64.msix"
$msixPath = Join-Path $OutputDir $msixName

Write-Host "Packing MSIX with: $makeappx"
& $makeappx pack /d $stageDir /p $msixPath /o
if ($LASTEXITCODE -ne 0) { throw "makeappx pack failed (exit $LASTEXITCODE)." }
Write-Host "Packed: $msixPath"

# --- 5. Sign -----------------------------------------------------------------
$cerPath = $null
if ($SkipSign) {
    Write-Warning 'Signing skipped (-SkipSign). The unsigned .msix is for validation only and cannot be installed.'
} else {
    $signtool = Find-WindowsSdkTool -Name 'signtool.exe'

    if ($PfxPath) {
        # --- Production / supplied certificate ---
        if (-not (Test-Path -LiteralPath $PfxPath)) { throw "PFX not found: $PfxPath" }
        Write-Host "Signing with supplied certificate: $PfxPath"
        if ($PfxPassword) {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxPassword))
            & $signtool sign /fd SHA256 /a /f $PfxPath /p $plain $msixPath
        } else {
            & $signtool sign /fd SHA256 /a /f $PfxPath $msixPath
        }
        if ($LASTEXITCODE -ne 0) { throw "signtool sign failed (exit $LASTEXITCODE)." }
    } else {
        # --- Self-signed dev certificate (sideload/testing) ---
        Write-Host "Locating or creating self-signed cert: $CertSubject"
        $cert = Get-ChildItem Cert:\CurrentUser\My |
            Where-Object { $_.Subject -eq $CertSubject -and $_.HasPrivateKey } |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1

        if (-not $cert) {
            Write-Host 'No matching cert found; creating a new self-signed code-signing certificate.'
            $cert = New-SelfSignedCertificate -Type Custom -Subject $CertSubject `
                -KeyUsage DigitalSignature -FriendlyName 'SvgConverter Dev Signing' `
                -CertStoreLocation 'Cert:\CurrentUser\My' `
                -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
        }

        $cerPath = Join-Path $OutputDir ("SvgConverter-$Version-x64.cer")
        Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
        Write-Host "Exported public certificate: $cerPath"

        & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint $msixPath
        if ($LASTEXITCODE -ne 0) { throw "signtool sign failed (exit $LASTEXITCODE)." }
    }
    Write-Host 'Signed successfully.'
}

# --- 6. Assemble the distributable -------------------------------------------
# The user-facing scripts, plus the pieces the Classic (no-MSIX) fallback needs:
# loose binaries under bin\ and the legacy registry-menu scripts.
$distFiles = @(
    (Join-Path $PSScriptRoot 'Install-SvgConverter.ps1'),
    (Join-Path $PSScriptRoot 'Uninstall-SvgConverter.ps1'),
    (Join-Path $PSScriptRoot 'Common.ps1'),
    (Join-Path $PSScriptRoot 'install-context-menu.ps1'),
    (Join-Path $PSScriptRoot 'uninstall-context-menu.ps1'),
    (Join-Path $PSScriptRoot 'diagnose.ps1'),
    (Join-Path $repoRoot 'INSTALL.md')
)
foreach ($f in $distFiles) {
    if (Test-Path -LiteralPath $f) {
        Copy-Item -LiteralPath $f -Destination $OutputDir -Force
    }
}

# Loose binaries for the Classic fallback (Install-SvgConverter.ps1 -Mode Classic).
$binOut = Join-Path $OutputDir 'bin'
New-Item -ItemType Directory -Force -Path $binOut | Out-Null
foreach ($name in $artifacts) {
    Copy-Item -LiteralPath (Join-Path $releaseDir $name) -Destination $binOut -Force
}

Write-Host ''
Write-Host '=============================================================='
Write-Host " Installer ready: $OutputDir"
Write-Host '=============================================================='
Write-Host "  Package : $msixName"
if ($cerPath) { Write-Host "  Cert    : $(Split-Path -Leaf $cerPath)" }
Write-Host '  Scripts : Install-SvgConverter.ps1 / Uninstall-SvgConverter.ps1'
Write-Host ''
Write-Host 'End user installs by running (from the output folder):'
Write-Host '  powershell -ExecutionPolicy Bypass -File .\Install-SvgConverter.ps1'
Write-Host 'or by double-clicking the .msix once the certificate is trusted.'
