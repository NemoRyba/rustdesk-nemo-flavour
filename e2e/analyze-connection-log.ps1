<#
.SYNOPSIS
    Parse a RustDesk (Nemo) client log and extract per-connection performance
    facts: which path was taken (direct vs relay), how long the punch and the
    connection establishment took.

.DESCRIPTION
    Layer 4 of the TDD strategy. This is the measurement primitive behind the
    before/after numbers that gate every performance decision in the roadmap
    (direct-connection work, relay tuning, WireGuard evaluation).

    It keys off two log lines the client emits per outgoing connection, in the
    controlling-side core `Client`:

      1. Punch timing (src/client.rs):
         "<n> ms used to <TCP|UDP> punch hole, relay_server: <addr>, <tail>"
         where <tail> is "is_local: true" (same-LAN) or "nat_type: <NatType>".

      2. Connection establishment (src/client.rs), the definitive path line:
         "<dur> used to establish <typ> connection with <TCP|UDP|IPv6> punch"
         where <typ> is "Relay" for a relayed session, else "TCP"/"UDP"/"IPv6"
         for a direct session.

    Each establishment line is paired with the most recent preceding punch line
    (they are emitted in that order for one connection) and classified into a
    single `path`:
        local          - direct, same-LAN (is_local: true)
        direct-tcp      - direct TCP hole punch
        direct-udp-kcp  - direct UDP/KCP hole punch
        direct-ipv6     - direct IPv6/KCP
        relay           - fell back to the relay server

    Output is objects (pipe to Export-Csv / Format-Table). Runtime details that
    depend on your build (log file location, how the session is launched) live
    in measure-connection.ps1, not here - this script only parses text, so it is
    correct regardless of platform and is exercised by -SelfTest.

.PARAMETER Path
    Path to a client log file. If omitted, reads from stdin.

.PARAMETER SelfTest
    Parse a built-in sample covering every path and assert the classification.
    Verifies the parser with no client/VM needed. Exit code 0 = pass.

.EXAMPLE
    ./analyze-connection-log.ps1 -Path rustdesk.log | Format-Table
.EXAMPLE
    ./analyze-connection-log.ps1 -Path rustdesk.log | Export-Csv -NoTypeInformation results/run1.csv
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Pin invariant culture so numeric output (establish_ms etc.) always uses a
# '.' decimal separator regardless of the host locale; a German locale would
# otherwise emit "1013,607", which corrupts the CSV on round-trip.
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

# Rust Duration Debug format -> milliseconds. Examples: "1.2345s", "567.8ms",
# "12.3µs" / "12.3us", "800ns", "2m 3.4s" (rare for our sub-minute durations).
function Convert-DurationToMs {
    param([string]$Text)
    $totalMs = 0.0
    $matched = $false
    foreach ($m in [regex]::Matches($Text, '([\d.]+)\s*(µs|us|ns|ms|s|m|h)')) {
        $matched = $true
        $v = [double]$m.Groups[1].Value
        switch ($m.Groups[2].Value) {
            'ns' { $totalMs += $v / 1e6 }
            'us' { $totalMs += $v / 1e3 }
            'µs' { $totalMs += $v / 1e3 }
            'ms' { $totalMs += $v }
            's'  { $totalMs += $v * 1e3 }
            'm'  { $totalMs += $v * 60e3 }
            'h'  { $totalMs += $v * 3600e3 }
        }
    }
    if (-not $matched) { return $null }
    return [math]::Round($totalMs, 3)
}

# Leading flexi_logger timestamp, if present (best-effort; not required).
$tsRegex = [regex]'^\[?(?<ts>\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
$punchRegex = [regex]'(?<ms>\d+) ms used to (?<ptype>\w+) punch hole, relay_server:\s*(?<relay>\S*?),\s*(?<tail>.*)$'
$establishRegex = [regex]'(?<dur>[\d.]+\s*(?:µs|us|ns|ms|s|m|h)(?:\s+[\d.]+\s*(?:µs|us|ns|ms|s))*)\s+used to establish\s+(?<typ>\w*)\s*connection with\s+(?<punch>\w+)\s+punch'

function Get-ConnectionEvents {
    param([Parameter(ValueFromPipeline)][string]$Line)
    begin {
        $pending = $null
    }
    process {
        if ([string]::IsNullOrEmpty($Line)) { return }

        $ts = $null
        $tsm = $tsRegex.Match($Line)
        if ($tsm.Success) { $ts = $tsm.Groups['ts'].Value }

        $pm = $punchRegex.Match($Line)
        if ($pm.Success) {
            $tail = $pm.Groups['tail'].Value
            $pending = [ordered]@{
                punch_ms      = [int]$pm.Groups['ms'].Value
                punch_type    = $pm.Groups['ptype'].Value
                relay_server  = $pm.Groups['relay'].Value
                is_local      = [bool]($tail -match 'is_local:\s*true')
                peer_nat_type = if ($tail -match 'nat_type:\s*(\w+)') { $Matches[1] } else { '' }
                punch_ts      = $ts
            }
            return
        }

        $em = $establishRegex.Match($Line)
        if ($em.Success) {
            $typ = $em.Groups['typ'].Value
            $establishMs = Convert-DurationToMs $em.Groups['dur'].Value

            $isLocal = $false
            $punchMs = $null
            $punchType = $em.Groups['punch'].Value
            $relay = ''
            $peerNat = ''
            if ($pending) {
                $isLocal = $pending.is_local
                $punchMs = $pending.punch_ms
                $relay = $pending.relay_server
                $peerNat = $pending.peer_nat_type
            }

            $path =
                if ($typ -eq 'Relay') { 'relay' }
                elseif ($isLocal)     { 'local' }
                elseif ($typ -eq 'TCP')  { 'direct-tcp' }
                elseif ($typ -eq 'UDP')  { 'direct-udp-kcp' }
                elseif ($typ -eq 'IPv6') { 'direct-ipv6' }
                else { "direct-$typ" }

            [pscustomobject][ordered]@{
                timestamp     = $ts
                path          = $path
                direct        = ($path -ne 'relay')
                establish_ms  = $establishMs
                punch_ms      = $punchMs
                punch_type    = $punchType
                is_local      = $isLocal
                peer_nat_type = $peerNat
                relay_server  = $relay
            }
            $pending = $null
        }
    }
}

if ($SelfTest) {
    $sample = @(
        '[2026-08-25 12:00:00.100 +02:00] INFO [src/client.rs:637] 123 ms used to TCP punch hole, relay_server: , is_local: true',
        '[2026-08-25 12:00:00.900 +02:00] INFO [src/client.rs:781] 812.5ms used to establish TCP connection with TCP punch',
        '[2026-08-25 12:00:05.000 +02:00] INFO 456 ms used to TCP punch hole, relay_server: 198.51.100.50:21117, nat_type: ASYMMETRIC',
        '[2026-08-25 12:00:07.500 +02:00] INFO 2.5s used to establish Relay connection with TCP punch',
        '88 ms used to UDP punch hole, relay_server: , is_local: true',
        '45.6ms used to establish UDP connection with UDP punch',
        '900 ms used to TCP punch hole, relay_server: 198.51.100.50:21117, nat_type: SYMMETRIC',
        '1.2345678s used to establish UDP connection with UDP punch'
    )
    $rows = @($sample | Get-ConnectionEvents)
    $fail = 0
    function Check($cond, $msg) {
        if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green }
        else { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:fail++ }
    }
    Write-Host "analyze-connection-log self-test:"
    Check ($rows.Count -eq 4) "parsed 4 connection events (got $($rows.Count))"
    Check ($rows[0].path -eq 'local') "row 0 path=local (is_local TCP) -> got '$($rows[0].path)'"
    Check ([math]::Abs($rows[0].establish_ms - 812.5) -lt 0.001) "row 0 establish_ms=812.5 -> got $($rows[0].establish_ms)"
    Check ($rows[0].punch_ms -eq 123) "row 0 punch_ms=123 -> got $($rows[0].punch_ms)"
    Check ($rows[1].path -eq 'relay') "row 1 path=relay -> got '$($rows[1].path)'"
    Check ([math]::Abs($rows[1].establish_ms - 2500) -lt 0.001) "row 1 establish_ms=2500 -> got $($rows[1].establish_ms)"
    Check ($rows[1].relay_server -eq '198.51.100.50:21117') "row 1 relay_server captured -> got '$($rows[1].relay_server)'"
    Check ($rows[2].path -eq 'local' -and $rows[2].punch_type -eq 'UDP') "row 2 path=local, punch_type=UDP -> '$($rows[2].path)','$($rows[2].punch_type)'"
    Check ($rows[3].path -eq 'direct-udp-kcp') "row 3 path=direct-udp-kcp (WAN UDP direct) -> got '$($rows[3].path)'"
    Check ([math]::Abs($rows[3].establish_ms - 1234.568) -lt 0.01) "row 3 establish_ms~1234.568 -> got $($rows[3].establish_ms)"
    if ($fail -eq 0) { Write-Host "self-test: ALL PASS" -ForegroundColor Green; exit 0 }
    else { Write-Host "self-test: $fail FAILED" -ForegroundColor Red; exit 1 }
}

if ($Path) {
    if (-not (Test-Path $Path)) { throw "log file not found: $Path" }
    Get-Content -LiteralPath $Path | Get-ConnectionEvents
}
else {
    $input | Get-ConnectionEvents
}
