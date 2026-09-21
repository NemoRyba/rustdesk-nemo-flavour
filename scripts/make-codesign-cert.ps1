<#
.SYNOPSIS
  Create a self-signed code-signing certificate for TBFDesk, and the .cer to trust it on
  the fleet.

.DESCRIPTION
  Read this first, because it corrects a common assumption:

  **Let's Encrypt cannot sign code.** It issues TLS *server* certificates only. There is no
  free public CA for Authenticode. The options are:

    1. Buy an OV or EV code-signing certificate (DigiCert, Sectigo, ...). Only this makes
       the installer trusted on machines you do not control, and only EV clears Microsoft
       SmartScreen immediately -- OV still needs reputation to build up.
    2. Self-sign, and push the certificate to your own machines' Trusted Publishers store
       via Group Policy. Free, and on a managed fleet it is *equivalent* for the thing you
       actually care about: the UAC prompt says TBFDesk instead of "unknown publisher",
       and the installer stops looking like something that fell off a truck.
    3. Ship unsigned.

  For ~15 domain-joined workstations plus a few technician machines, (2) is the right
  answer and this script implements it. Note what it does NOT do: a self-signed certificate
  does nothing on a machine that has not been given the .cer, so anything outside the
  domain still sees SmartScreen.

  Also worth separating: the **TLS certificate for the management API** is a different
  thing entirely, and there Let's Encrypt IS the right tool -- see DEPLOY.md.

  Note the real trust anchor for UPDATES is neither of these: the update manifest is
  Ed25519-signed by the server key and the updater verifies the sha256 before installing.
  Authenticode is about the first install and about what the UAC prompt says.

.EXAMPLE
  .\make-codesign-cert.ps1 -Password (Read-Host -AsSecureString)
  # then, once:
  #   deploy dist\tbfdesk-codesign.cer to Computer Config > Policies > Windows Settings >
  #   Security Settings > Public Key Policies > Trusted Publishers
  # then:
  #   .\package-windows-client.ps1 -SignWith dist\tbfdesk-codesign.pfx -SignPassword ...
#>
[CmdletBinding()]
param(
    [string]$Subject = "TBF Desk",
    [int]$Years = 5,
    [Parameter(Mandatory = $true)][SecureString]$Password,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root "dist" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# CodeSigningCert is the EKU that matters (1.3.6.1.5.5.7.3.3); without it signtool refuses.
$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject "CN=$Subject" `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddYears($Years)

$pfx = Join-Path $OutDir "tbfdesk-codesign.pfx"
$cer = Join-Path $OutDir "tbfdesk-codesign.cer"

# The .pfx holds the PRIVATE key -- it is the thing that can sign as you. Treat it like
# the server signing key: offline, backed up, never in the repo.
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $Password | Out-Null
# The .cer is public. This is what goes out to the fleet.
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

$thumb = $cert.Thumbprint
Write-Host ""
Write-Host "  private key : $pfx   (KEEP OFFLINE, back it up, never commit)" -ForegroundColor Yellow
Write-Host "  public cert : $cer   (deploy this to the fleet)" -ForegroundColor Cyan
Write-Host "  thumbprint  : $thumb"
Write-Host ""
Write-Host "Next, once, on the domain controller:" -ForegroundColor Cyan
Write-Host "  Group Policy Management > edit a GPO linked to the workstations OU >"
Write-Host "  Computer Configuration > Policies > Windows Settings > Security Settings >"
Write-Host "  Public Key Policies > Trusted Publishers > Import > $cer"
Write-Host ""
Write-Host "  Import it into Trusted Root Certification Authorities in the same GPO too --"
Write-Host "  a self-signed cert is its own root, so without that it chains to nothing and"
Write-Host "  the signature still shows as untrusted."
Write-Host ""
Write-Host "Then build a signed installer:" -ForegroundColor Cyan
Write-Host "  .\scripts\package-windows-client.ps1 -SignWith $pfx -SignPassword <pw>"
Write-Host ""
Write-Host "Verify on a workstation after deploying the GPO:"
Write-Host "  Get-AuthenticodeSignature .\tbfdesk-<version>-x64-install.exe"
Write-Host "  -> Status should be Valid, not UnknownError/NotTrusted."
Write-Host ""
Write-Warning "Machines that did NOT get the GPO still see SmartScreen. That is inherent to self-signing, not a bug."
