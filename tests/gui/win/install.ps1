# Install/upgrade TBFDesk from <Installer> and wait until the new exe is in place and the
# service runs. (Start-Process -Wait would never return: the installer leaves the tray running.)
param([Parameter(Mandatory=$true)][string]$Installer)
$exe = "C:\Program Files\TBFDesk\TBFDesk.exe"
$before = if (Test-Path $exe) { (Get-Item $exe).LastWriteTime } else { [datetime]::MinValue }
$t = Get-Date
Start-Process $Installer -ArgumentList "--silent-install" | Out-Null
do {
  Start-Sleep 3
  $now = (Get-Item $exe -EA SilentlyContinue).LastWriteTime
  $svc = (Get-Service TBFDesk -EA SilentlyContinue).Status
} until ((($now -ne $null) -and ($now -gt $before) -and ($svc -eq 'Running')) -or (((Get-Date) - $t).TotalSeconds -gt 180))
Start-Sleep 5
"version=" + (Get-Item $exe).VersionInfo.FileVersion
"service=" + (Get-Service TBFDesk).Status
"seconds=" + [int]((Get-Date) - $t).TotalSeconds
