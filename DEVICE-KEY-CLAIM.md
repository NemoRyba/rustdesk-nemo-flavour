# Device-key first-use binding, with operator confirmation — WIP

**Status 2026-10-16: INCOMPLETE, committed mid-conversion. Compiles; `cargo test` is 87 passed / 1 failed,
and that one failure is expected at this point (see [Known breakage](#known-breakage)). NOT deployed —
the live server on the lab VM is still `0747b0b`, which does not contain any of this.**

## The problem this solves

Provisioning deadlocks today:

1. the operator generates a device key in the dashboard, which wants the **TBFDesk id** to bind it to;
2. but a client shows no id until it is past the **provisioning gate**;
3. and it cannot pass the gate without an imported device key.

So the id cannot be known at the moment the key is created. The only way out today is
`--allow-unbound-device-keys Y`, which is strictly worse than the thing it works around: it makes
*every* unbound key a fleet-wide skeleton key, permanently. Meanwhile an unprovisioned machine is
invisible — nothing in the dashboard says "a client is here, holding key X, calling itself id Y".

## The design (as instructed 2026-10-16)

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

## What is implemented (committed)

`rustdesk-server-nemo`, 3 files, +397/-27:

- **`DeviceKey.claimed_at`** — when a binding was taken by first use, so the dashboard can tell
  "the operator typed this id" from "a client asked for it and was approved".
- **`IntegrationConfig.claim_unbound_device_keys`** — `default_true`, with the same upgrade rule as
  `require_device_key` (an omitted field reads as a fresh install; a stored `false` survives).
- **`IntegrationConfig.pending_device_key_claims`** + **`PendingDeviceKeyClaim`** — persisted, so a
  request filed overnight is still there in the morning and a restart does not forget a denial. Carries
  `key_id`, `public_key`, `peer_id`, `first_seen`, `last_seen`, `attempts`, `via`, `denied`.
- **`device_key_binding_decision()`** — replaces `device_key_binding_check()` as the one rule both
  enforcement points apply, now with the `ClaimOnProof` arm. Pure, therefore directly testable.
- **`claim_device_key_in()` / `claim_device_key()`** — the binding mutation, split pure/locking.
  Re-checks the binding under the lock that writes it, so two ids racing one token cannot both win.
- **`valid_peer_id()`**, **`set_device_key_peer_id_in()` / `set_device_key_peer_id()`** — the editable
  "Bound to ID" field: bind after the fact, or clear to re-arm the key as a claimable token.
- **`device_key_for_peer()`**, **`unclaimed_device_key_count()`** — provisioning state read from the
  pinned registry, so unlike the poll-derived auth mode it survives a restart.
- **Both enforcement points restructured to decision → verify signature → act**:
  `verify_device_signature_proof()` (management API: poll, address book, audit, login) and
  `nemo_client_auth_open()` (rendezvous handshake). `DeviceProof`/`AuthedDevice` now report the
  outcome outward, because the check is sync and the audit sink is async.
- **`record_device_key_claim()`** — audits the binding in the dashboard event ring, not just the log.

## What is still open

**The three call sites still *take* the binding instead of filing a request.** The conversion to
pending claims stopped half-way, which is the whole of the remaining work:

1. **`nemo_integration.rs`** — add `register_pending_claim(public_key, peer_id, via) -> PendingOutcome`
   (`New` / `Repeat` / `Denied` / `Full`), `pending_device_key_claims()`, `pending_claim_for_peer()`,
   `approve_device_key_claim()` (→ `claim_device_key`, then drop that key's other pending rows),
   `deny_device_key_claim()` (sets `denied`, so the next poll 30 s later does not re-raise it) and
   `forget_device_key_claim()` (lets a denied client ask again). Cap the list:
   `MAX_PENDING_PER_KEY` ≈ 5 and a global cap, oldest dropped. A request needs a valid signature over a
   pinned key, so this is not an open flood — but one key must not be able to fill the table with ids.
2. **`verify_device_signature_proof()` / `nemo_client_auth_open()`** — on `ClaimOnProof`, verify the
   signature, then `register_pending_claim(...)` and **refuse**, with a reason that says
   "awaiting operator confirmation" rather than a bare 403.
3. **Routes** — `GET /nemo/api/device-key-claims`, `POST /nemo/api/device-keys/:id/claim/approve`,
   `.../deny`, `.../forget`, and `POST /nemo/api/device-keys/:id/peer-id` for the editable field.
   `claim_unbound_device_keys` into `PolicyRequest` + the health response.
4. **`PeerResponse`** — `provisioned` / `device_key_id` / `device_key_label` / pending-claim fields.
5. **Dashboard** (`nemo_admin.html`) — the confirm/deny UI **in the peers panel**, as asked: an
   "unverified — key claim pending" badge with Approve / Deny on the peer row and in the detail panel.
   Plus, in the Device keys panel: a pending section, the editable "Bound to ID" cell, the
   `claim_unbound_device_keys` checkbox, and claim state per row ("awaiting first use" / "claimed
   <when>"). A pending claim can name an id that is not registered yet (the rendezvous handshake
   precedes `register_pk`), so the Device keys panel must list claims the peers table cannot show.
6. **Startup warning** (`nemo_management.rs:1323-1338`) — it currently tells the operator to use
   `--allow-unbound-device-keys Y`; that advice is obsolete once claiming exists.
7. **Tests** — first-use files a claim and does not authenticate; approval binds and a second id is
   then refused; deny survives a restart and is not re-raised; the race (two ids, one token) leaves
   one winner; `valid_peer_id` rejects junk; claiming off restores the TASK #14 rule exactly.
8. **Client side** — a client whose claim is pending is refused like any unprovisioned client, so it
   sits in the gate with no explanation. It should say "waiting for approval by your administrator".
   Needs a distinguishable refusal from the server (see 2).

## Known breakage

```
test result: FAILED. 87 passed; 1 failed
nemo_management::tests::verify_device_signature_checks_pin_binding_domain_and_freshness
  panicked at src/nemo_management.rs:6292
```

That test asserts TASK #14: *a pinned but unbound key is refused even with a valid fresh signature.*
It fails because the committed half-state **grants** the binding on first use. It is the correct
canary: under the pending-claim design a first use is still refused, so finishing step 2 above must
turn this test green again **without editing the test**. If it only passes after the assertion is
weakened, the design was not implemented.

## Hazard found while testing — fix before writing the claim tests

Reaching a persisting mutation from a test **writes `nemo_integration.json` into the repo checkout**
(observed: a real file with the test keys in it; removed; it is gitignored, so it was never committed).
`pin_device_key_for_test` exists precisely to avoid this, but it only covers pinning — the test entered
through `verify_device_signature`, which reaches the locking wrapper and so `persist()`.

Recommended fix, before step 7: make **`persist()` a no-op under `#[cfg(test)]`**. That protects every
present and future test in one place. Keeping the pure/locking split (`*_in` functions) is still right,
but it cannot help a test that enters through an enforcement point.
