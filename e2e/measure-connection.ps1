<#
.SYNOPSIS
    Drive N outgoing RustDesk (Nemo) connections to a target peer, capture the
    client log, and emit a CSV of the path taken and timing for each attempt.

.DESCRIPTION
    Layer 4 driver. Produces the before/after evidence for the performance work:
    run it against a target once to get a baseline, change the topology / flip a
    setting, run it again, and diff the CSVs.

    Per attempt it launches `rustdesk.exe --connect <PeerId>` with RUST_LOG=info,
    lets the session run briefly (long enough for the punch + establish lines to
    be logged), then terminates it and feeds the captured log to
    analyze-connection-log.ps1.

    RUNTIME DETAILS TO CONFIRM ON FIRST RUN (see README.md):
      * Log capture. This script sets RUST_LOG=info and redirects the process's
        stderr to a temp file. If your build writes logs only to a file instead
        of stderr, pass -LogPath to that file (the client's log directory) and
        the script will read it instead. Confirm which on the first VM run.
      * Session teardown. The connect window is force-terminated after
        -DwellSeconds. If the client spawns child processes, adjust
        Stop-Session below.

.PARAMETER ClientExe
    Path to rustdesk.exe. For a locked-exe build the server host/key/relay are
    baked into the filename, so no server args are needed.

.PARAMETER PeerId
    The target peer's RustDesk ID.

.PARAMETER Count
    Number of connection attempts (default 10).

.PARAMETER Label
    Short label for this run; names the CSV under results/ (e.g. "wan-baseline").

.PARAMETER DwellSeconds
    Seconds to let each session run before terminating (default 8).

.PARAMETER LogPath
    Optional: read this log file instead of captured stderr (use when the client
    logs to a file rather than stderr).

.PARAMETER ConnectArgs
    Optional extra args passed to rustdesk.exe (e.g. "--password","secret").

.EXAMPLE
    ./measure-connection.ps1 -ClientExe .\run-windows-client\rustdesk.exe -PeerId 123456789 -Count 20 -Label wan-baseline
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ClientExe,
    [Parameter(Mandatory)][string]$PeerId,
    [int]$Count = 10,
    [string]$Label = 'run',
    [int]$DwellSeconds = 8,
    [string]$LogPath,
    [string[]]$ConnectArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Invariant culture so CSV numbers use '.' regardless of host locale.
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$analyzer = Join-Path $here 'analyze-connection-log.ps1'
$resultsDir = Join-Path $here 'results'
if (-not (Test-Path $ClientExe)) { throw "client exe not found: $ClientExe" }
if (-not (Test-Path $analyzer)) { throw "analyzer not found: $analyzer" }
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

function Stop-Session {
    param($Proc)
    if ($Proc -and -not $Proc.HasExited) {
        try { Stop-Process -Id $Proc.Id -Force -ErrorAction Stop } catch {}
    }
    # Best-effort: sweep any lingering connect windows from this exe.
    $exeName = [IO.Path]::GetFileNameWithoutExtension($ClientExe)
    Get-Process -Name $exeName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq (Resolve-Path $ClientExe).Path } |
        ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
}

$allRows = New-Object System.Collections.Generic.List[object]
Write-Host "Measuring $Count connection(s) to peer $PeerId ..." -ForegroundColor Cyan

for ($attempt = 1; $attempt -le $Count; $attempt++) {
    $stderrFile = Join-Path $env:TEMP ("nemo_measure_{0}_{1}.log" -f $PID, $attempt)
    $argList = @('--connect', $PeerId) + $ConnectArgs

    $env:RUST_LOG = 'info'
    $proc = Start-Process -FilePath $ClientExe -ArgumentList $argList `
        -RedirectStandardError $stderrFile -RedirectStandardOutput ($stderrFile + '.out') `
        -PassThru -WindowStyle Minimized

    # Wait for the session to establish and log its lines.
    $deadline = (Get-Date).AddSeconds($DwellSeconds)
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 250
    }
    Stop-Session -Proc $proc

    $logToParse = if ($LogPath) { $LogPath } else { $stderrFile }
    $rows = @()
    if (Test-Path $logToParse) {
        $rows = @(& $analyzer -Path $logToParse)
    }

    if ($rows.Count -eq 0) {
        Write-Host ("  attempt {0,3}: no connection event parsed" -f $attempt) -ForegroundColor Yellow
    }
    foreach ($r in $rows) {
        $r | Add-Member -NotePropertyName attempt -NotePropertyValue $attempt -Force
        $r | Add-Member -NotePropertyName label -NotePropertyValue $Label -Force
        $allRows.Add($r)
        Write-Host ("  attempt {0,3}: {1,-14} establish={2,8} ms  punch={3} ms" -f `
            $attempt, $r.path, $r.establish_ms, $r.punch_ms)
    }

    if (-not $LogPath) {
        Remove-Item $stderrFile, ($stderrFile + '.out') -ErrorAction SilentlyContinue
    }
}

if ($allRows.Count -eq 0) {
    Write-Host "No events captured. Confirm the log-capture method (see README / -LogPath)." -ForegroundColor Red
    exit 1
}

$csv = Join-Path $resultsDir ("{0}.csv" -f $Label)
$allRows | Export-Csv -NoTypeInformation -Encoding utf8 $csv
Write-Host "`nWrote $($allRows.Count) rows -> $csv" -ForegroundColor Green

Write-Host "`nPath distribution:" -ForegroundColor Cyan
$allRows | Group-Object path | Sort-Object Count -Descending | ForEach-Object {
    Write-Host ("  {0,-16} {1}" -f $_.Name, $_.Count)
}

$direct = @($allRows | Where-Object { $_.direct })
$pctDirect = [math]::Round(100.0 * $direct.Count / $allRows.Count, 1)
Write-Host ("`nDirect: {0}/{1} ({2}%)" -f $direct.Count, $allRows.Count, $pctDirect) -ForegroundColor Cyan

$withEstablish = @($allRows | Where-Object { $null -ne $_.establish_ms })
if ($withEstablish.Count -gt 0) {
    $sorted = @($withEstablish.establish_ms | Sort-Object)
    $median = $sorted[[math]::Floor($sorted.Count / 2)]
    Write-Host ("Median establish time: {0} ms" -f $median) -ForegroundColor Cyan
}
