# Device-key first-use binding, with operator confirmation

**Status 2026-10-16: IMPLEMENTED on the server and in the Sciter client. Server suite green —
96 passed / 0 failed, and the TASK #14 canary is green again without the assertion being touched
(see [The canary](#the-canary)). NOT deployed: the live server on the lab VM still runs `0747b0b`,
which contains none of this.**

## The problem this solves

Provisioning deadlocked:

1. the operator generates a device key in the dashboard, which wants the **TBFDesk id** to bind it to;
2. but a client shows no id until it is past the **provisioning gate**;
3. and it cannot pass the gate without an imported device key.

So the id could not be known at the moment the key was created. The only way out was
`--allow-unbound-device-keys Y`, which is strictly worse than the thing it works around: it makes
*every* unbound key a fleet-wide skeleton key, permanently. Meanwhile an unprovisioned machine was
invisible — nothing in the dashboard said "a client is here, holding key X, calling itself id Y".

## The design

An unbound pinned key is a **one-shot provisioning token**. The first client that *proves* it does
**not** get in — it files a **pending claim** that the operator confirms or denies in the dashboard.
Only that confirmation writes the binding; afterwards the key authenticates that id and nothing else.

The operator confirmation is the user's explicit requirement, and it is also what makes the feature
sound: a peer id is **self-reported** (machine-derived, client-side), so no signature can attest that
id *belongs* to that machine. The signature proves possession of the key; only a human can attest the
pairing. Hence: prove → **ask** → bind.

Two properties fall out of the ordering, and both are load-bearing:

- **The claim is filed only after the signature verifies**, so claiming requires holding the private
  half. Naming someone else's unclaimed key cannot take it, or even raise a request against it.
- **A pending claim grants nothing.** With `require_device_key` on, the client stays refused — and
  therefore sits in its provisioning gate — until the operator approves. The pending row *is* the
  "unverified client" view that was asked for.

### Precedence, so no existing deployment changes behaviour silently

1. a **bound** key authenticates exactly its peer — unchanged;
2. `--allow-unbound-device-keys Y` still means "unbound authenticates anything", and files no claim:
   an operator who asked for the loose rule keeps it, including the one-key-many-machines workflow;
3. otherwise an unbound key may **request** a binding, if `claim_unbound_device_keys` is on (default);
4. otherwise it authenticates nothing — the original TASK #14 fail-closed rule.

## What the server does

`rustdesk-server-nemo`, branch `nemo-tdd`.

### Config and state (`nemo_integration.rs`)

- **`DeviceKey.claimed_at`** — when a binding was taken by a confirmed claim, so the dashboard can
  tell "the operator typed this id" from "a client asked for it and was approved".
- **`IntegrationConfig.claim_unbound_device_keys`** — `default_true`, with the same upgrade rule as
  `require_device_key` (an omitted field reads as a fresh install; a stored `false` survives).
- **`pending_device_key_claims`** + **`PendingDeviceKeyClaim`** — persisted, so a request filed
  overnight is still there in the morning and a restart does not forget a denial. Carries `key_id`,
  `public_key`, `peer_id`, `first_seen`, `last_seen`, `attempts`, `via`, `denied`.
- **`device_key_binding_decision()`** — the one rule both enforcement points apply, with the
  `ClaimOnProof` arm. Pure, therefore directly testable. It **replaced** `device_key_binding_check()`,
  which is gone; its test now asserts the four arms of the decision in precedence order.
- **`register_pending_claim()`** → `New` / `Repeat` / `Denied` / `Full` / `Rejected`, plus
  `pending_device_key_claims()`, `pending_claim_for_peer()`, `pending_device_key_claim_count()`,
  `approve_device_key_claim()`, `deny_device_key_claim()`, `forget_device_key_claim()`.
  Caps: `MAX_PENDING_PER_KEY = 5`, `MAX_PENDING_CLAIMS = 200`. A request costs a valid signature over
  a pinned key, so this is not an open flood — but one key must not fill a *persisted* table with ids.
  The global cap evicts the oldest row that is merely waiting and **never a denied one**: dropping a
  denial would let that client re-raise its request on the next poll.
  A `Repeat` does not write the config file, so a client re-polling every 30 s while it waits does not
  rewrite it every 30 s.
- **`claim_device_key_in()`** — the binding mutation, re-checked under the lock that writes it, so two
  ids racing one token cannot both win (and two browser tabs cannot both approve).
- **`valid_peer_id()`**, **`set_device_key_peer_id()`** — the editable "Bound to ID" field: bind after
  the fact, or clear to re-arm the key as a claimable token. Both paths **drop that key's pending
  rows**, denials included, so a stale denial cannot refuse the first client that proves a re-armed
  key. Deleting a key drops its rows too.
- **`normalize_peer_id()`** — the operator-typed id is accepted the way the **client displays** it:
  `456 456 456` is stored as `456456456`. All whitespace goes, `is_whitespace` rather than `== ' '`, so
  a non-breaking space pasted out of a GUI works too. It runs on exactly two paths, the editable field
  and the generate form, and **not** on the approve path or anywhere on the request path: a pending
  claim holds the id the *client* reported and has to keep matching byte-for-byte — which is why
  `valid_peer_id()` still refuses an id containing a space.
- **`device_key_for_peer()`**, **`unclaimed_device_key_count()`** — provisioning state read from the
  pinned registry, so unlike the poll-derived auth mode it survives a restart.

### Enforcement (`nemo_management.rs`, `rendezvous_server.rs`)

Both points are **decision → verify signature → file a request → refuse**:

- `verify_device_signature_proof()` (management API: poll, address book, audit, login) returns
  `DeviceProof { ok: false, claim: Some(outcome) }` for a proved-but-unbound key. The `via` label of
  the row is derived from the verified signature domain, so it cannot disagree with what was checked.
- `nemo_client_auth_open()` (rendezvous handshake) files the request and `bail!`s with a reason that
  names the wait rather than a bare failure.
- `client_policy()` answers 403 with **`device key is awaiting operator confirmation`** (or
  `… claim was denied by the operator`) instead of "a provisioned device key is required", which is
  what lets the client say something true.
- Audit: `device-key-claim-pending` when a request is first filed, `device-key-claimed` when the
  operator approves, plus `device-key-claim-denied` / `-forgotten` / `device-key-binding`.

### API

- `GET /nemo/api/device-key-claims` → `{ claims, claim_unbound_device_keys }`
- `POST /nemo/api/device-keys/:id/claim/approve` · `/deny` · `/forget` — body `{ peer_id }`
  (required: one key can have several ids waiting, so "the pending one" would be a guess)
- `POST /nemo/api/device-keys/:id/peer-id` — body `{ peer_id }`, empty clears
- `claim_unbound_device_keys` in `PolicyRequest` (PUT `/nemo/api/policy`) and in the health/policy
  response, alongside `pending_device_key_claims` (the waiting count)
- `PeerResponse` gains `provisioned`, `device_key_id`, `device_key_label` and the
  `pending_claim_*` fields.

### Dashboard (`nemo_admin.html`)

- **Peers panel** — the `Key auth` column shows **unverified — key claim pending** (or
  *key claim denied*) ahead of the poll-derived mode, with **Approve key / Deny key** on the row and
  in the detail panel, which also shows the bound key and the claim's age, endpoint and retry count.
  A machine with a key bound but no poll since boot reads *provisioned, not polled* rather than
  *unknown*.
- **Device keys panel** — the `claim_unbound_device_keys` checkbox; a pending section listing every
  request with Approve / Deny / Clear (the peers table cannot show them all: the rendezvous handshake
  precedes `register_pk`, so a claim can name an id this server has never registered); the editable
  **Bound to ID** cell; and a claim-state column per key (*awaiting first use* / *bound by hand* /
  *claimed &lt;when&gt;*).
- The boot warning no longer advises `--allow-unbound-device-keys Y`: unbound is now the *normal*
  provisioning state, so it says how many tokens are waiting and how many claims want a decision.

## What the client does

`rustdesk-client-nemo`, branch `nemo-tdd`.

A client whose claim is pending holds a valid, genuinely-issued key, so it passes its own provisioning
gate, shows an id — and then fails everything, because the server refuses both the poll and the
handshake. Previously the poll's 403 fell into the "your key is not the one pinned for this id" branch,
which sends the user to re-import the one thing that is not broken.

- `nemo_management_client.rs` recognises the two refusal strings and reports them: a throttled
  (once-per-minute) log line that says an administrator has to approve this machine, and nothing to fix
  here; `Ok(())` rather than `bail!`, because waiting is a normal provisioning step.
- `common.rs` keeps the live status (`nemo_claim_status()` → `"" | "pending" | "denied"`),
  process-global on purpose: it is a report about the last poll, not a setting, and a stale value on
  disk would outlive the approval it describes. A poll the server accepts clears it.
- `ui/index.tis` renders a gate card — **"Waiting for approval by your administrator"**, or "This
  device was not approved" — in place of the main window, on the same 3 s transition check as the other
  gates, so it clears by itself within a minute of the operator pressing Approve. The pending card
  deliberately does not push the user toward re-importing the key.

## Tests

`cargo test --features nemo-management-api` → **96 passed, 0 failed**. The new ones:

- `first_use_files_a_claim_and_only_approval_binds` — proving an unbound key does not authenticate; the
  row is visible with its attempt count; approval binds and marks `claimed_at`; the key then refuses
  every other id.
- `an_unbound_key_files_a_claim_and_is_still_refused` (at the enforcement point) — a valid fresh
  signature over an unbound key is refused and files a row labelled with the endpoint; a client that
  does **not** hold the key files nothing; with claiming off nothing is filed at all; approval then
  makes it an ordinary bound key.
- `one_token_binds_one_machine_even_with_two_claims` — two ids may ask, one wins, the loser is refused
  rather than overwriting it, and the winner re-polling is not a second claim.
- `a_denied_claim_is_not_re_raised_until_it_is_forgotten` — a denial is not re-raised by the next poll;
  forgetting it lets the client ask again.
- `pending_claims_are_capped_per_key`, `the_global_pending_cap_evicts_the_oldest_waiting_row_not_a_denial`.
- `a_claim_needs_a_real_peer_id_and_a_pinned_key` — junk ids and unpinned keys never reach the table.
- `editing_the_binding_clears_the_keys_pending_rows`.
- `device_key_binding_decision_covers_the_four_arms_in_order` — the precedence rule itself.

### The canary

```
nemo_management::tests::verify_device_signature_checks_pin_binding_domain_and_freshness
```

asserts TASK #14: *a pinned but unbound key is refused even with a valid fresh signature.* The
half-converted WIP broke it because it **granted** the binding on first use. It is green again with the
assertion untouched, which is the design's own proof: under pending claims a first use is still a
refusal.

### The test hazard, fixed

Reaching a persisting mutation from a test used to **write `nemo_integration.json` into the repo
checkout** (observed once: a real file with the test keys in it; it is gitignored, so it was never
committed). `pin_device_key_for_test` only covers pinning, and a test entering through an enforcement
point reaches the locking wrapper and so `persist()`. **`persist()` is now a no-op under
`#[cfg(test)]`** — one place, every present and future test. The pure `*_in` halves are still the right
shape for testing the rules, but they cannot help a test that enters through an enforcement point.

## Operating it

1. Generate a key in **Settings → Device keys** with the ID field **empty**, and import the private
   half into the client. (A key generated *with* an id behaves exactly as before.)
2. The client reports *Waiting for approval by your administrator*.
3. The dashboard shows the request — in **Peers** on that machine's row, and in the Device keys panel's
   pending section if the id is not registered yet. Check the id is the machine you handed the key to,
   then **Approve**.
4. The client clears within a minute (its next poll).

**Deny** if the id is not what you expect, and consider deleting the key as well: something that holds
its private half is using it. A denial sticks across restarts and the client stops asking; **Clear**
lets it ask again.

To go back to the old rule entirely, untick *Let an unbound key be claimed on first use* — an unbound
key then authenticates nothing and files nothing, and every key must be bound by hand.

## Not done

- **Flutter client** — the gate card is Sciter only (`src/ui/index.tis`). The Flutter UI has no
  provisioning gate at all today, so there is nothing there to extend yet; the log line and the API
  are shared.
- **Deployment** — none of this is on the lab VM. The server still has to be built and rolled out, and
  the flow verified live (generate an unbound key → import → approve → connect).
- The address-book and login endpoints file claims like the poll does, but only the poll's refusal is
  worded for the user; the other two still answer the generic 403. Harmless (the poll is the gate a
  client actually waits on), worth tidying if those paths ever become a client's first contact.
