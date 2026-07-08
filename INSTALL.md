# Installing SVG Converter

SVG Converter adds a **Convert SVG** entry to the right‑click menu of `.svg`
files in Windows Explorer, so you can turn an SVG into a **PNG**, **JPEG**, or
**WebP** at ×0.5 / ×1 / ×2 / ×3 without opening any app.

This guide is for people installing a downloaded copy. If you are building from
source, see the developer commands at the bottom.

---

## What you downloaded

Inside the installer folder you should see something like:

```
SvgConverter-1.0.0.0-x64.msix     the app package
SvgConverter-1.0.0.0-x64.cer      a certificate used to trust the package
Install-SvgConverter.ps1          run this to install
Uninstall-SvgConverter.ps1        run this to uninstall
INSTALL.md                        this guide
bin\                              (used only by the no‑package fallback)
```

## Prerequisites

- **Windows 10 (version 1809 or newer) or Windows 11**, 64‑bit.
- No Rust, Node, ImageMagick, or other tools are needed — everything is included.

---

## Install (recommended)

1. Open the installer folder in File Explorer.
2. Right‑click **`Install-SvgConverter.ps1`** and choose **Run with PowerShell**.
   - If Windows blocks scripts, open PowerShell and run:
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\Install-SvgConverter.ps1
     ```
3. Click **Yes** on the **User Account Control (UAC)** prompt. This one‑time
   prompt is asking permission to *trust the app’s certificate* (see
   [Why the security prompts?](#why-the-security-prompts) below).
4. When it finishes, **right‑click any `.svg` file → Convert SVG** and pick a
   format and size. The image is saved next to the original file
   (e.g. `logo.svg` → `logo@2x.png`).

If the menu does not appear right away, restart Explorer:

```powershell
Stop-Process -Name explorer -Force
```

> **Double‑click alternative:** once the certificate is trusted (step 3 above,
> or done manually), you can also just double‑click the `.msix` and use the
> built‑in Windows **App Installer** window.

---

## Why the security prompts?

The app is distributed as an **MSIX package**. Windows only installs MSIX
packages that are **digitally signed**, and it will only trust a signature it
recognizes.

- This build is signed with a **self‑signed certificate** (`.cer` file included).
  It proves the package hasn’t been tampered with, but Windows doesn’t know the
  publisher yet — so the installer imports that certificate into your **Trusted**
  store first (that’s the UAC prompt), then installs the package.
- You may also see a **SmartScreen** warning the first time. This is normal for
  apps that aren’t yet widely downloaded. Choose **More info → Run anyway** if
  you trust the source.

For a commercial release these prompts disappear once the package is signed with
a certificate from a public authority (see
[For distributors](#for-distributors-production-signing)).

---

## Uninstall

Any one of these works:

- **Settings:** *Settings → Apps → Installed apps → SVG Converter → Uninstall.*
- **Script:** right‑click **`Uninstall-SvgConverter.ps1`** → *Run with PowerShell*, or:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\Uninstall-SvgConverter.ps1
  ```

To also remove the trust certificate that was added during install:

```powershell
.\Uninstall-SvgConverter.ps1 -RemoveCert
```

---

## Fallback: install without a package (no certificate)

If your organization blocks MSIX sideloading, or you don’t want to trust a
certificate, use **Classic mode**. It copies the program into your user profile
and adds the right‑click menu through the registry — **no admin, no certificate,
no Developer Mode**:

```powershell
.\Install-SvgConverter.ps1 -Mode Classic
```

On Windows 11 the entry appears under **Show more options** (Shift+F10). It still
shows up in *Settings → Installed apps* for easy removal, or:

```powershell
.\Uninstall-SvgConverter.ps1 -Mode Classic
```

To install for **all users** (requires an admin prompt):

```powershell
.\Install-SvgConverter.ps1 -Mode Classic -Scope Machine
```

---

## For distributors: production signing

The included certificate is for testing/sideloading only. For public release:

1. Set the `Publisher` in `packaging\full\AppxManifest.xml` to your real
   publisher name (e.g. `CN=Contoso Ltd, O=Contoso Ltd, C=US`).
2. Sign with a certificate whose subject matches that `Publisher`, using a
   trusted authority such as **Azure Trusted Signing** or an **EV code‑signing
   certificate**:
   ```powershell
   .\scripts\build-installer.ps1 -PfxPath C:\path\to\production.pfx
   ```
   With a publicly trusted certificate, end users get **no certificate prompt
   and no SmartScreen warning** — they can double‑click the `.msix` directly.
3. Optionally publish to the **Microsoft Store** or **winget** for one‑line
   installs.

---

## Building from source (developers)

```powershell
cd svg-converter
# Produce the signed MSIX + cert + scripts in target\installer:
.\scripts\build-installer.ps1
```

Requirements: the Rust toolchain (1.87+) and the Windows 10/11 SDK (provides
`makeappx.exe` and `signtool.exe`). See `README.md` for the full developer and
context‑menu details.
