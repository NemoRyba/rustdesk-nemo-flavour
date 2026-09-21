<#
.SYNOPSIS
  Produce ONE double-clickable TBFDesk installer for Windows.

.DESCRIPTION
  H29. Until now the only thing ever shipped was a hand-assembled four-file ZIP that no
  script in this repo produced, so "deployment" meant copying four loose files to each
  machine and remembering to keep them together. If sciter.dll is missing the client does
  not start; if service.exe is missing there is no Windows service, which means no
  unattended access, no login screen and no UAC prompt.

  The installer logic was never the gap -- install_me, --silent-install, the *install.exe
  click-setup convention and the self-extracting packer in libs/portable are all present
  and untouched. What was missing is this wrapper. It follows the recipe upstream CI uses
  (.github/workflows/flutter-build.yml), adapted from its x86 matrix to x64.

  Output:  dist\tbfdesk-<version>-x64-install.exe   plus a .sha256 next to it.

  Install on a workstation:
      tbfdesk-<version>-x64-install.exe                 (interactive)
      tbfdesk-<version>-x64-install.exe --silent-install (unattended / GPO / RMM)

  The same file is what you POST to /nemo/api/update together with its sha256 to drive
  the existing signed updater.

.NOTES
  Must run on the Windows build host -- it needs the toolchain that
  build-run-windows-client.ps1 needs. It cannot be produced from Linux.

  WHY THE PACKER, AND NOT A BARE RENAMED EXE: install_me copies the whole folder by
  filename and never renames the executable, while the service, shortcuts and
  UninstallString it registers all point at RustDesk.exe. So running
  `rustdesk-host=...,.exe --silent-install` directly produces an install directory with
  no RustDesk.exe in it. The packer avoids that: it extracts its payload as rustdesk.exe
  and passes its OWN outer filename through RUSTDESK_APPNAME, which is what
  get_license_from_exe_name reads. Put the locked name on the PACKER:
      tbfdesk-<version>-host=<h>,key=<k>,install.exe

  NOT SIGNED. Unsigned, this triggers SmartScreen and an "unknown publisher" UAC prompt.
  For a handful of admin-pushed seats that is usually tolerated -- and the trust anchor
  for UPDATES is already the Ed25519 manifest signature plus the sha256 the updater
  verifies before installing, not Authenticode. Buying an OV/EV certificate is a
  deliberate decision; see -SignWith.
#>
[CmdletBinding()]
param(
    # Locked-exe licence name baked into the OUTER filename, e.g.
    # "host=tbfdesk.example.com,key=<b64>". Leave empty for a generic installer.
    [string]$License = "",
    # Path to a code-signing .pfx. Unsigned if omitted.
    [string]$SignWith = "",
    [string]$SignPassword = "",
    # Skip the cargo build and package whatever is already in target\release.
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$client = Join-Path $root "rustdesk-client-nemo"
$dist = Join-Path $root "dist"
$staging = Join-Path $client "Release"

function Need($path, $what) {
    if (-not (Test-Path $path)) { throw "$what not found at $path" }
}

# --- version -----------------------------------------------------------------
$cargo = Get-Content (Join-Path $client "Cargo.toml") -Raw
if ($cargo -notmatch '(?m)^version\s*=\s*"([^"]+)"') { throw "cannot read the version from Cargo.toml" }
$version = $Matches[1]
if ($version -notmatch '^\d+(\.\d+)*$') {
    # get_version_number() parses the '-suffix' with unwrap_or(0), so "1.4.6-tbf1" scores
    # identically to "1.4.6" and the updater would never offer it.
    throw "version '$version' is not numeric-only; the updater cannot compare it"
}
Write-Host "TBFDesk $version" -ForegroundColor Cyan

# --- build -------------------------------------------------------------------
if (-not $NoBuild) {
    # Deliberately WITHOUT -Fast: that profile sets lto=false / codegen-units=256 /
    # incremental=1 and must never be what ships.
    & (Join-Path $PSScriptRoot "build-run-windows-client.ps1") -NoRun
    if ($LASTEXITCODE -ne 0) { throw "client build failed" }

    # build-run-windows-client.ps1 does not build this one; build.py does, and the
    # shipped ZIP has always contained it.
    Push-Location $client
    cargo build --release -p dylib_virtual_display
    if ($LASTEXITCODE -ne 0) { throw "dylib_virtual_display build failed" }
    Pop-Location
}

# --- stage -------------------------------------------------------------------
$rel = Join-Path $client "target\release"
Need (Join-Path $rel "rustdesk.exe") "rustdesk.exe"
Need (Join-Path $rel "service.exe") "service.exe"
Need (Join-Path $rel "dylib_virtual_display.dll") "dylib_virtual_display.dll"

# sciter.dll is a proprietary redistributable and is NOT fetched at build time on
# purpose: a package step that curls a binary off the internet is not reproducible and
# fails offline. Keep the exact DLL in the repo.
$sciter = Join-Path $root "downloads\sciter-x64\sciter.dll"
if (-not (Test-Path $sciter)) {
    throw @"
sciter.dll (x64) not found at $sciter

It is not in the repo yet. Fetch it ONCE from the sciter-sdk (bin.win/x64/sciter.dll),
commit it together with its SHA-256, and confirm the redistribution terms while you are
there. Without it the installed client will not start -- src/ui.rs loads it from next to
the exe and the build only warns when it is missing.
"@
}

if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Path $staging | Out-Null
Copy-Item (Join-Path $rel "rustdesk.exe") $staging
Copy-Item (Join-Path $rel "service.exe") $staging
Copy-Item (Join-Path $rel "dylib_virtual_display.dll") $staging
Copy-Item $sciter $staging
Write-Host "staged 4 files into $staging" -ForegroundColor Green

# --- pack --------------------------------------------------------------------
# generate.py embeds the staged folder into the packer crate; the packer then extracts it
# to a temp dir at run time and launches rustdesk.exe with the packer's own filename in
# RUSTDESK_APPNAME.
Push-Location (Join-Path $client "libs\portable")
python generate.py -f ..\..\Release -o . -e ..\..\Release\rustdesk.exe
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "generate.py failed" }
Pop-Location

Push-Location $client
cargo build --release -p rustdesk-portable-packer
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "packer build failed" }
Pop-Location

$packed = Join-Path $rel "rustdesk-portable-packer.exe"
Need $packed "the packed installer"

# --- name, sign, hash --------------------------------------------------------
# The name matters: libs/portable turns any name ending in "install.exe" into
# click_setup, which is what makes a double-click install rather than run portable.
$suffix = if ($License) { "$License," } else { "" }
$outName = "tbfdesk-$version-x64-$($suffix)install.exe"
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
$out = Join-Path $dist $outName
Copy-Item $packed $out -Force

if ($SignWith) {
    & signtool sign /fd sha256 /f $SignWith /p $SignPassword /tr http://timestamp.digicert.com /td sha256 $out
    if ($LASTEXITCODE -ne 0) { throw "signing failed" }
    Write-Host "signed with $SignWith" -ForegroundColor Green
} else {
    Write-Warning "UNSIGNED: SmartScreen will warn and UAC will say 'unknown publisher'."
}

$hash = (Get-FileHash -Algorithm SHA256 $out).Hash.ToLower()
Set-Content -Path "$out.sha256" -Value "$hash  $outName" -NoNewline

Write-Host ""
Write-Host "  $out" -ForegroundColor Cyan
Write-Host "  sha256 $hash"
Write-Host ""
Write-Host "  install:   $outName"
Write-Host "  unattended: $outName --silent-install"
Write-Host "  publish:   POST it with that sha256 to /nemo/api/update"
