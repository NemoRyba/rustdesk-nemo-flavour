# Stop the user-facing TBFDesk window(s); unless -UiOnly, also the debug consoles and the cmd
# wrappers the test launched. Service, server and tray stay. Retries until nothing matches,
# and reports what it stopped.
param([switch]$UiOnly)
$killed = @()
foreach ($i in 1..6) {
  $p = Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -ieq 'tbfdesk.exe' -and $_.CommandLine -notmatch '--') -or
    (-not $UiOnly -and $_.Name -ieq 'powershell.exe' -and $_.CommandLine -match 'RUST_LOG') -or
    (-not $UiOnly -and $_.Name -ieq 'cmd.exe' -and $_.CommandLine -match 'tbf-test') }
  if (-not $p) { break }
  $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue; $killed += "$($_.Name):$($_.ProcessId)" }
  Start-Sleep 1
}
"stopped: " + ($(if ($killed) { $killed -join ', ' } else { 'nothing' }))
