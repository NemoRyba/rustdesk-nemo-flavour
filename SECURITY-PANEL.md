# Security panel — operator guide

The admin dashboard (`https://<server>:31120/nemo/admin`, or `/nemo`) has a **Security** tab
that shows what the server's automatic abuse defences are doing right now and lets you lift a
block that caught a legitimate source. It is the operator face of the C1/C3/C4 hardening (see
`pentest/08-IMPROVEMENTS.md`). Added 2026-10-26.

## Opening it
Sign in to `/nemo/admin` with the admin token, then click **Security** in the top nav. It
auto-refreshes every ~4 s while open. Everything it shows is read from the live server; it
exposes no secret.

## What the blocks are (and why they self-lift)
All of these are **automatic and temporary** — each one lifts itself after a cooldown. The panel
just makes them visible and lets you lift one early.

| Defence | Trips when | Cooldown | What it does |
|---|---|---|---|
| **Per-IP spray block** | one source IP fails **>10 distinct usernames** in 5 min | 60 s | refuses that IP's directory binds (stops it walking the user list / locking AD accounts) |
| **Fleet spray tripwire** | **>30 distinct usernames** fail across all sources in 60 s | 120 s | refuses *all* directory binds briefly (a distributed spray) |
| **Login backoff** (per account) | consecutive failed logins for one account | grows 250 ms → **30 s** cap | delays that account's failed logins; a correct password clears it instantly, so real users are never locked out |
| **Unauth rate limit** (per IP) | a flood of unauthenticated requests (`/api/login`, `/api/login-key`, `/api/tls-cert-info`) | token bucket, **40 burst / ~2 req·s⁻¹** | sheds excess with HTTP 429 *before* any sealedbox open — a backstop when no edge proxy fronts the API |

A legitimate client — even many behind one office NAT — stays well under these; the thresholds
sit above what a whole site can plausibly fail by accident.

## The panel, section by section
- **Metrics row (since the server started):** Rate-limit sheds (429s), Per-IP spray trips,
  Fleet spray trips, Backoff caps (accounts that hit the 30 s ceiling), Pre-bind refusals, and
  **Active blocks now** (the live total of the three tables below).
- **Fleet-wide spray tripwire** banner (only shown while active) with **Clear tripwire**.
- **Blocked source IPs** — IP, distinct usernames seen, time remaining, **Unblock**.
- **Rate-limited sources** — IP, budget left, state (*shedding (429)* vs *under pressure*),
  **Reset**.
- **Accounts under login backoff** — account, consecutive failures (+ *at cap*), current delay,
  last failure, **Clear**.

## When to use Unblock / Reset / Clear
Use them when a **legitimate** source was caught — most often a shared office NAT egress that
tripped the per-IP gate because several real people mistyped passwords in the same window, or an
account a user locked themselves out of with repeated typos.

- **Unblock** (blocked IP) — lift that IP's spray cooldown now.
- **Reset** (rate-limited IP) — refill that source's request budget now.
- **Clear** (account) — reset that account's login backoff.
- **Clear tripwire** (fleet) — resume accepting directory binds immediately; it re-arms on its
  own if spraying continues.

**Safety property:** lifting a block only clears that limiter's own state. It can **never** grant
a peer access that admission policy (allow/block, device-key gate, require-login) would otherwise
deny. Every lift is written to the **Log** tab as a `security-unblock` event, so it is audited.

## Anomaly log
The discrete transitions are recorded in the **Log** tab (not every failed attempt, so the log
stays legible): `login-spray` (a spray tripwire fired), `login-backoff-cap` (an account hit the
30 s ceiling), and `security-unblock` (an admin lifted a block). Use these to tell a live
spray/flood from background noise.

## Automation / API
All of this is also available over the token-gated admin API (for scripting or an external SIEM):

- `GET /nemo/api/security` → a JSON snapshot: `counters`, `config` (the thresholds above),
  `global_tripwire`, `ip_blocks`, `throttled_ips`, `backoff_accounts`.
- `POST /nemo/api/security/unblock` with `{"scope":"ip|throttle|backoff|global","key":"<ip|username>"}`
  → lifts one block (`scope:"global"` ignores `key`).

Both require the admin bearer token (`Authorization: Bearer <token>` or `x-nemo-token`), checked
before any request body is parsed. Example:

```bash
curl -sk -H "Authorization: Bearer $TOKEN" https://SERVER:31120/nemo/api/security
curl -sk -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"scope":"ip","key":"203.0.113.7"}' https://SERVER:31120/nemo/api/security/unblock
```

Metrics + events are also the hook for alerting: scrape the counters or watch the `login-spray` /
`login-backoff-cap` events to page when a spray is in progress.
