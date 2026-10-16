#requires -RunAsAdministrator
<#
    Reset a Windows TBFDesk client's settings, keeping a backup of each file.

    Run elevated: it stops/starts the service and writes under C:\Windows.

    WHAT THIS CLEARS (the *.toml in both config directories)
      RustDesk.toml          this machine's ID, its keypair, the permanent password
      RustDesk2.toml         every option - INCLUDING the device key (nemo-device-key)
                             and the server settings a setup string wrote
      RustDesk_local.toml    per-user local state, including the login access token
      RustDesk_status.toml, RustDesk_lan_peers.toml

    Both directories, because the service keeps its own copy and a machine whose
    user config alone was cleared comes back with its old identity:
      %APPDATA%\RustDesk\config                                        (the signed-in user)
      C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config   (the service)

    WHAT THIS LEAVES
      peers\*.toml           per-peer settings (a subdirectory, not matched)
      RustDesk_ab, RustDesk_group    address-book / group cache (no .toml extension)
      %APPDATA%\RustDesk\log         logs
      the installation, the service, the registry entries, the shortcuts
      *** the .bak files this script writes ***

    THE BACKUPS ARE SECRETS. RustDesk2.toml.bak still contains the device key - the
    machine's Layer 1 identity - and RustDesk.toml.bak its keypair and password hash.
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

Stop-Service RustDesk -Force -EA 0; Start-Sleep 2
foreach($d in @("$env:APPDATA\RustDesk\config",'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config')){
  if(Test-Path $d){ Get-ChildItem $d -Filter *.toml | %{ Copy-Item $_.FullName "$($_.FullName).bak" -Force; Remove-Item $_.FullName -Force } }
}
Start-Service RustDesk; (Get-Service RustDesk).Status
