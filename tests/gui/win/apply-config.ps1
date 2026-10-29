# Replace the SERVICE's settings (TBFDesk2.toml) with <Toml>; the identity file
# (TBFDesk.toml: the ID the device key is bound to) is kept. Restarts the service.
param([Parameter(Mandatory=$true)][string]$Toml)
$svc = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\TBFDesk\config"
$usr = "$env:SystemDrive\Users\tbf\AppData\Roaming\TBFDesk\config"
Stop-Service TBFDesk -Force; Get-Process tbfdesk -EA SilentlyContinue | Stop-Process -Force; Start-Sleep 3
Remove-Item "$svc\TBFDesk2.toml.bak" -Force -EA SilentlyContinue
Copy-Item $Toml "$svc\TBFDesk2.toml" -Force
Remove-Item "$usr\TBFDesk2.toml*","$usr\TBFDesk_local.toml*" -Force -EA SilentlyContinue
Start-Service TBFDesk; Start-Sleep 6
"service=" + (Get-Service TBFDesk).Status
