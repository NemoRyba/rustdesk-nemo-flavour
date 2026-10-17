#requires -RunAsAdministrator
<#
    Reset a Windows TBFDesk client's settings, keeping a backup of each file.

    Run elevated: it stops/starts the service and writes under C:\Windows.

    WHAT THIS CLEARS (the *.toml in every config directory)
      TBFDesk.toml           this machine's ID, its keypair, the permanent password
      TBFDesk2.toml          every option - INCLUDING the device key (nemo-device-key)
                             and the server settings a setup string wrote
      TBFDesk_local.toml     per-user local state, including the login access token
      TBFDesk_status.toml, TBFDesk_lan_peers.toml

    Both profiles, because the service keeps its own copy and a machine whose user
    config alone was cleared comes back with its old identity:
      %APPDATA%\TBFDesk\config                                              (the signed-in user)
      C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\TBFDesk\config  (the service)

    AND the RustDesk-named directories of the same two profiles. Since 1.4.8 the app
    is TBFDesk and a first start MIGRATES a RustDesk-named config into the new
    location (RENAMING-PLAN Layer 2), so a machine whose TBFDesk config alone was
    cleared would come back with its OLD identity on the very next start, out of the
    directory 1.4.7 left behind. A reset that leaves that copy in place is a reset
    that silently did not happen - and every "fresh machine" test after it is
    measuring a provisioned machine.

    WHAT THIS LEAVES
      peers\*.toml           per-peer settings (a subdirectory, not matched)
      TBFDesk_ab, TBFDesk_group      address-book / group cache (no .toml extension)
      %APPDATA%\TBFDesk\log          logs
      the installation, the service, the registry entries, the shortcuts
      *** the .bak files this script writes ***

    THE BACKUPS ARE SECRETS. TBFDesk2.toml.bak still contains the device key - the
    machine's Layer 1 identity - and TBFDesk.toml.bak its keypair and password hash.
    For a repair they are exactly what you want; for a decommission, delete them (or
    the whole directory) afterwards.

    AFTERWARDS the machine is unprovisioned AND has a NEW ID (the keypair is
    regenerated on next start). So:
      - import a setup string again (dashboard -> Settings -> Device keys), and
      - on the server, the old device key is now bound to an ID that no longer
        exists: clear or re-point its "Bound to ID", or delete the key and issue a
        new one. With first-use claiming on, clear the binding and approve the new
        claim instead.

    Only the settings, not the install? That is this script. A full removal
    (uninstall + every leftover) is in the client repo's docs/nemo-provisioning.md.
#>

$svc  = 'TBFDesk'
$dirs = @(
  "$env:APPDATA\TBFDesk\config"
  "$env:APPDATA\RustDesk\config"
  'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\TBFDesk\config'
  'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config'
)

# Pre-1.4.8 machines still run the RustDesk-named service; stop whichever exists.
foreach ($n in @($svc, 'RustDesk')) { Stop-Service $n -Force -EA 0 }
Start-Sleep 2

foreach ($d in $dirs) {
  if (Test-Path $d) {
    Get-ChildItem $d -Filter *.toml | ForEach-Object {
      Copy-Item $_.FullName "$($_.FullName).bak" -Force
      Remove-Item $_.FullName -Force
      "cleared $($_.FullName)"
    }
  }
}

if (Get-Service $svc -EA 0) { Start-Service $svc; (Get-Service $svc).Status }
elseif (Get-Service RustDesk -EA 0) { Start-Service RustDesk; (Get-Service RustDesk).Status }
else { "no TBFDesk service installed" }
