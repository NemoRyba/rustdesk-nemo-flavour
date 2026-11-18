# Private devices: a controller-only device class (design proposal)

Status: DESIGN ONLY, nothing implemented. Written 2026-11-17; reviewed and corrected the same day
(see 0. below).
Base: client `nemo-tdd-flutter` @ `ea7e32da8` (1.4.24), server `nemo-tdd` @ `965a1bd` (1.1.19, not released).
All `file:line` references are to those two commits.

## 0. Review summary (2026-11-17, independent review against the code)

The direction (Option C) stands. The review checked the cited code and changed the design where the
code says otherwise. The changes, most important first:

1. **New key group K4: "forced closed".** A private device now *receives* `nemo-require-control-ticket=Y`
   instead of having it withheld. On every client version this refuses every TBFDesk login that comes
   without a ticket, before any password is checked (`connection.rs:2356-2369`). No ticket ever lists a
   private device. So even a 1.4.24 client refuses incoming sessions itself, the stale fleet password
   becomes useless, and phase 1 no longer depends on "provisioned as private from the start" (3, 5.6).
   Before the review this key was in K2. That was a mistake, because withholding it also switches the
   ticket requirement *off*.
2. **Endpoints and per-peer knock keys are not filtered by the user ACL.** The draft said they were.
   `direct_endpoint_map` and `knock_key_map` (`nemo_management.rs:2002-2016`, `:2138-2151`) filter only
   by blocked ids and the policy's `nemo-outbound-targets`. A private device with nobody signed in
   would get the SPA keys of every workstation. Fix: deliver them to a private device only while a user
   is signed in, and only for that user's targets (3, 5.1).
3. **Operator-edited named, user and admin policies are NOT sanitized.** The draft assumed they were.
   `put_policies` → `integration::set_policies` stores them as they arrive (`:5662-5675`,
   `nemo_integration.rs:1649-1655`). So the server must always *remove* `nemo-device-class` from the
   options before it inserts its own value (5.1).
   - The same applies to every server-computed key. `nemo-logged-in-user` is even a legal *global*
     policy key (`:298`), and nothing removes it on the no-user path, while the ticket reads the user
     back from the options (`:7648`).
   - So a policy-sourced copy would give a signed-out device a user ticket. The private allowlist
     therefore drops all server-computed keys and re-inserts them from server state (3, 5.1).
   - This is a pre-existing defect for company devices too.
4. **"Block" does not end a controller's running sessions.** `block_peer` stamps the blocked id only as
   a *target* (`:7807-7810`), and targets check `nemo-blocked-ids` only at logon (`connection.rs:1568`).
   A private device is never a target, so for a lost laptop Block would end nothing. Fix: on a private
   device, Block must also call `terminate_sessions_from_controllers(&[id])`, as deleting a device key
   already does (`:4396-4399`) (5.1, 5.4).
5. **Switch sides bypasses the ticket check.** On Flutter desktop, the `SwitchSidesResponse` arm
   authorises a connect-back without passing `apply_management_authorization`
   (`connection.rs:2824-2849`). The server's refusal of private targets still blocks it, because the
   connect-back is brokered by hbbs. The client adds this arm as a refusal point and hides "Switch
   Sides" for private controllers (5.2, 5.3).
6. **The class must follow the device key, not the peer row.** `delete_peer_ids` (`:8219-8238`) does
   not remove the bound `DeviceKey`. If deleting the peer also deleted its class, the same machine
   would re-register as *company* (5.1).
7. **The one-shot password clear could never fire after an upgrade.** A 1.4.24 client already caches
   `nemo-device-class=private` in its last policy (`policy_for_storage` keeps unknown keys), so after
   the upgrade to 1.4.25 there is no "company → private" change left to see. The clear is now the
   rule "while private, keep the permanent password empty" (5.2).
8. **UI: `outgoing_only` cannot simply be extended.** In Sciter it also hides the account bar
   (`index.tis:2110`, `:2117`) and ConnectStatus (`:2164`), and the settings menu only stays reachable
   through the outgoing-only fallbacks at `:2127` and `:2130`. The sites are now listed one by one
   (5.3).
9. Smaller corrections:
   - The rendezvous private check keys off the resolved controller identity, not only the proven one.
   - The inline policy's outgoing keys are kept, so the ticket and the rendezvous gate agree.
   - `nemo-peer-keys` is filtered for private devices.
   - Presence queries are covered.
   - The K1/K2/K3 completeness test now has an explicit "unlisted = withheld" rule.
   - Controller preferences moved to K3, because they would be *locked* on the employee's own PC.
   - The one-file-installer route is not an authz path.
   - Explicit-list tickets are not new: they already occur whenever any peer is blocked.
   - New Option D: an outgoing-only build.
   - Questions Q11-Q14 added.

User request (deferred earlier, now requested):

> "can we have a no-policy for devices which are private of the users, which they use to connect to
> company computers ... so we don't have to apply any global policy to them"

---

## 1. Problem

A **private device** is a computer or phone that belongs to an employee, not to the company. The
employee uses it **only to control company computers**, for example from a home office or while on
call. It needs three things that TBFDesk cannot give it today:

1. **Not configured like a workstation.** The company must not push its workstation settings to it:
   the fleet's incoming access password, the incoming permissions, the approval mode, the direct-access
   listener, UI lock-down, automatic installs.
2. **Not controllable by the company.** No company admin or technician may open a session *to* it.
   This is a privacy and works-council question as much as a security one.
3. **Still a full member for outgoing sessions.** It must keep everything that lets it control company
   computers safely: its device key, the signed policy poll, the control ticket, the peer-key map, the
   direct endpoints and knock keys, the user ACL, block and revoke.

The literal ask ("no policy, no global policy") cannot be met as stated. Point 3 travels in the **same
signed policy** as everything else: the ticket, the peer keys, the endpoints, the knock keys, the
sign-in flag, the epoch and the revocation stamp are all options of that one payload. What is actually
needed is **no workstation policy**: a controller-only profile.

---

## 2. How policies work today, and why this cannot be configured (root cause)

### 2.1 Every poll starts from the global policy, and nothing can take a key away

`client_policy` (server `src/nemo_management.rs:7394`) builds each response in this order:

| Step | Code | Effect |
|---|---|---|
| 1 | `let mut policy = global_policy();` `:7494` | **Every** device starts from the full global policy. No code path skips it. |
| 2a | signed-in user: `policy.options.extend(up.options)` `:7520-7528` | The user's policy (admin policy / assigned named / default named / inline, `nemo_integration.rs:926-960`) is **added on top**. It *replaces* the device policy. |
| 2b | no user: inline per-peer policy, then the assigned named device policy, both via `extend` `:7535-7547` | Added on top. |
| 3 | `nemo-require-login` set or removed `:7556-7562` | From the server-wide `require_login` only. |
| 4 | server-computed keys: `nemo-clock-tolerance-secs`, `nemo-ab-version`, `nemo-blocked-ids`, `nemo-peer-keys`, `nemo-direct-endpoints`, `nemo-knock-keys`, `nemo-control-epoch`, `nemo-update-version`, `nemo-control-ticket` `:7565-7664` | The outgoing-session chain. |
| 5 | `direct-server=Y` (+ `direct-access-port`) injected when the peer has an endpoint `:7675-7699` | Listener for incoming direct sessions. |
| 6 | blocked peer: `nemo-outbound-enabled=N`, override off `:7700-7705` | |
| 7 | secrets stripped if the response cannot be sealed `:7714-7723` | `SECRET_POLICY_KEYS` `:8376-8389` |

`HashMap::extend` can add or overwrite a key but can **never remove** one. So:

- An **empty named policy** assigned to a device leaves the device with exactly the global policy.
- When a user is signed in, the device policy is not consulted at all, so it has no effect either.

There is no per-device way to *withhold* a global key.

### 2.2 A signed-in user's policy lands on the device as incoming configuration

The same key names mean two things:

- **On the server**, `enable-keyboard`, `enable-clipboard`, `enable-file-transfer`, ... in a *user's*
  policy are turned into the ControlPermissions bits for that user's sessions to other machines
  (`CONTROL_PERMISSION_KEYS` `:6195-6209`, `control_bits_for_user` `:6252-6270`). Those bits are read
  from `integration::user_policy()` on the server, **not** from the options sent to the client.
- **On the client**, the same keys arrive in the policy and are applied by `apply_policy`
  (client `src/nemo_management_client.rs:1162-1176` → `apply_policy_option` `:1332-1362`) as **this
  machine's incoming permissions**.

So when an admin signs in on a private laptop, the admin policy (all `enable-*` = `Y`, delivered as
defaults with `allow_user_override` forced on, `nemo_integration.rs:937-940`) switches on every
incoming permission **on the laptop**. A named user policy such as "Techniker" can also carry
`nemo-permanent-password` and `direct-access-port` (dashboard `userPolicyOptions`,
`nemo_admin.html:3843-3868`), and those are applied to whatever machine the user signs in on.

### 2.3 What the client keeps when keys stop coming

- Managed keys live in the in-memory DEFAULT/OVERWRITE maps and are **cleared on omit**: each poll
  first clears the previous policy's keys (`clear_policy_maps(&previous)`, `:1097`, `:1324-1330`).
- The incoming access password is the exception. `apply_permanent_password` (`:1272-1284`) **sets** it
  when `nemo-permanent-password` is present and **does nothing** when it is absent. A device that
  ever received the fleet password keeps it as its stored permanent password after the key stops
  coming. This matters for migration (section 5.6).
- `api-server` and `allow-insecure-tls-fallback` are written to the config file and never cleared
  (`:1109-1118`). That is fine here, because a private device needs both.

### 2.4 Can a private device be controlled today? Yes, in several ways

| Path | Gate today | Private device |
|---|---|---|
| Punch or relay through hbbs | Target gate `is_peer_allowed` (`:6072-6074` → `peer.rs:255-265`): blocked (0) = no, allowed (1) = yes, unset = `!company_only`. Called at `rendezvous_server.rs:724` (relay) and `:1356` (punch). | Controllable unless *company network only* is on **and** the device was never set to "Allowed". |
| Control ticket | `ticket_targets` returns `["*"]` when nothing restricts the controller (`:6380-6382`). The target accepts it (`nemo_control.rs:220`). | `"*"` covers private devices. |
| Address book | `api_ab_get` lists every registered peer the user may target (`:3370-3394`). Admins and `"*"` users see all peers. | Shown to admins as a target. |
| Direct, LAN or published endpoint | Only the target's own settings and ticket rules (`connection.rs:2337-2393`). | Accepted with the local or pushed password, unless `nemo-require-control-ticket` is set. A ticket with `"*"` is then valid anyway. |
| Switch sides (Flutter desktop only) | The `SwitchSidesResponse` arm (`connection.rs:2824-2849`) authorises the connect-back through `send_logon_response_and_keep_alive` **without** `apply_management_authorization` (no ticket, no password). The private device's own user starts it from their outgoing session (`toolbar.dart:288-296`). The connect-back is an ordinary outgoing connection of the workstation and is brokered by hbbs. | Controllable when the employee clicks "Switch Sides". |
| Presence | `OnlineRequest` (`rendezvous_server.rs:1981` → `handle_online_request` `:1605-1627`) answers for any id, with no gate. | Online/offline visible to anyone who knows the id. Not control, but a privacy item (Q8). |

### 2.5 What a private device really needs (the outgoing chain)

- **Registration with hbbs.** The poll answers 404 for an unregistered id (`:7411-7416`). The punch and
  relay refuse an unregistered controller: "controller is not registered by TBF policy" (`:6484-6486`).
- **Device key + signed, sealed poll.** Sealing applies because `require_device_key` is on by default
  (`nemo_integration.rs:210-211`).
- `nemo-control-ticket`. It is built only when a device key is proven (`:6409`), the device is not
  blocked, outgoing connections are not `N`, and a user is signed in if sign-in is required (`:6416`).
- `nemo-peer-keys` (direct SignedId verification), `nemo-direct-endpoints` and `nemo-knock-keys`
  (`:7597-7612`), plus the knock settings `nemo-knock-*`.
  - **Correction (review):** these are *not* filtered by the user's ACL. `direct_endpoint_map` and
    `knock_key_map` (`:2002-2016`, `:2138-2151`) drop only blocked ids and ids outside the policy's
    `nemo-outbound-targets`; they never look at the signed-in user or at whether anyone is signed in.
  - `peer_key_map` (`:6057-6066`) lists every registered peer.
  - Today a controller with no `nemo-outbound-targets` therefore receives the endpoint and the per-peer
    SPA key of every workstation that has one.
- The infrastructure keys: `custom-rendezvous-server`, `relay-server`, `api-server`, `key`,
  `nemo-management-*`, `nemo-api-cert-fingerprint`, `allow-insecure-tls-fallback`.
- The keys that protect the controller itself: `nemo-require-encrypted-session`,
  `nemo-require-secure-rendezvous`, `nemo-sealed-request`, `nemo-company-network-only`.

### 2.6 Why stock "outgoing-only" cannot be reused

RustDesk has `conn-type=outgoing` (hbb_common `config.rs:2920-2926`). It is used by Sciter
(`index.tis:9`, `:2110-2135`), Flutter desktop (`desktop_home_page.dart:82`, `:96-97`) and Android
(`mobile/pages/home_page.dart:61-64`). It cannot be used here, for two reasons:

- `RendezvousMediator::start_all` then **never registers** with hbbs (`rendezvous_mediator.rs:86-90`).
  The poll would get 404 and every punch would be refused as an unregistered controller (2.5).
- It lives in `HARD_SETTINGS`, which is set only from the embedded custom-client config
  (`common.rs:3570-3576`). The server cannot set it, change it or audit it.

Its **UI branches** are worth reusing (section 5.3).

### 2.7 Side finding (not part of this item; should be logged)

The rendezvous controller gate reads **only the inline per-peer policy**
(`controller_policy_rejection`, `:6500` → `:6501-6512`). A `nemo-outbound-enabled=N` or
`nemo-outbound-targets` value that comes from the **global** policy, a **named device** policy or a
**user** policy is not enforced at the punch or relay.

It *is* used elsewhere:
- in the ticket (`:6413`, `:6429`),
- in the endpoint and knock maps (`:7597`, `:7607`),
- by the cooperating client (`client.rs:204-227`).

So a modified controller is held back by those values only at targets that require tickets.

The dashboard makes this worse. The only list that offers `nemo-outbound-*` is `managementOptions`
(`nemo_admin.html:1422-1483`), and it is defined but **never rendered**. The peer detail computes
`advancedOptions` (`:3115-3116`) and never shows it either. So the inline policy that the rendezvous
gate does read can only be set through `PUT /nemo/api/peers/:id/management-policy`
(`nemo_management.rs:7332`), not from the GUI.

The consequence for this design: "private" must be enforced **from the device class**, never from a
policy blob. The gap should be logged as its own item in `OPEN-TODOS.md`; I could not do that here
because the file is outside my output directory.

### 2.8 Further facts the design depends on (added by the review, verified in code)

- **Withheld is not "off".** `option2bool` (hbb_common `config.rs:2965-2977`) treats an absent
  `enable-*` key as **on**, and `allow-*` / `direct-server` as off. Withholding a K2 key returns the
  device to its *own* stored setting or to the stock default, which for `enable-keyboard`,
  `enable-file-transfer`, `enable-lan-discovery` and the other `enable-*` keys is "allowed". Clear-on-omit
  removes only the managed copy; anything the user or an earlier version stored locally stays.
- **`nemo-require-control-ticket=Y` closes every login before any password.** `on_message` runs
  `apply_management_authorization` first for every `LoginRequest` kind (`connection.rs:2540-2544`).
  - No ticket while the key is required: refused with "This computer only accepts sessions authorized
    by your TBFDesk server..." (`:2356-2369`).
  - A ticket that does not list this machine: always refused as `Denied`, required or not
    (`nemo_control.rs:220-228`, `connection.rs:2370-2385`).
  - The key is in `NEMO_CONTROL_SETTINGS`, so it is always applied locked, whatever
    `allow_user_override` says (`nemo_management_client.rs:1347-1348`).
  - 1.4.24 already has all of this.
- **Named, user and admin policies are stored unsanitized.**
  - `sanitize_management_policy` runs only on the global policy (`:5698`, `:5738`) and the inline
    per-peer policy (`:7339`).
  - `put_policies` (`:5662-5675`) → `integration::set_policies` (`nemo_integration.rs:1649-1655`) and
    `put_permissions` (`:3750-3770`) store whatever keys they receive.
- **Block ends sessions *to* the peer only.** `block_peer` (`:7790-7820`) calls
  `set_peer_terminate(id)` and drops connections where `target_id == id`. A running session *from*
  the blocked peer goes on, because a target checks `nemo-blocked-ids` only at logon
  (`connection.rs:1568`). `delete_device_key` does end the controller's sessions
  (`terminate_sessions_from_controllers`, `:4396-4399`).
- **Deleting a peer keeps its device key.** `delete_peer_ids` (`:8219-8238`) deletes the peer row and
  its stats. The bound `DeviceKey` stays, so the same machine re-registers with the same id and key.
- **Explicit ticket lists already happen.** `ticket_targets` returns `"*"` only when `blocked` is
  empty as well (`:6380-6382`). Any fleet with one blocked peer already ships explicit lists.
- **The ticket reads the user back from the options.** `build_control_ticket` takes the username
  from `policy.options["nemo-logged-in-user"]` (`:7648`). The private allowlist must keep that key.
- **Switch sides** (Flutter desktop only; Sciter's `switch_sides` is an empty stub,
  `ui_session_interface.rs:1513-1514`) authorises without the ticket check (see 2.4).
- **Session lifetime** for a signed-in user is a fixed 12 h (`nemo_integration.rs:31`,
  `SESSION_TTL_SECS`).

---

## 3. Classifying the policy keys (concrete)

The private profile works by an **allowlist**, so it fails closed: a key added to
`CLIENT_MANAGEMENT_POLICY_KEYS` (`:195-412`) later does **not** reach private devices until someone
classifies it. **Rule: a key that is not in K1, in a ticked K3 entry or in K4 is withheld.** That
covers the rest of `CLIENT_MANAGEMENT_POLICY_KEYS` and every other hbb_common key a policy may carry
(`is_management_policy_key` also accepts all of `KEYS_SETTINGS` / `KEYS_LOCAL_SETTINGS` /
`KEYS_DISPLAY_SETTINGS`, `:8508-8513`). The groups below are therefore K1, K2, K3, K4 and
"withheld, unclassified".

A server unit test asserts that every key in `CLIENT_MANAGEMENT_POLICY_KEYS` is named in exactly one
of the five lists, so that a new key needs a conscious decision. The draft's lists did not cover the
whole table. The review diffed them against the table and lists the rest under K2b.

**K1: always delivered to a private device** (taken from the global or the user policy; the server
still adds its own computed keys):

- Infrastructure: `custom-rendezvous-server`, `relay-server`, `api-server`, `key`,
  `nemo-management-enabled`, `nemo-management-server`, `nemo-management-public-key`,
  `nemo-api-cert-fingerprint`, `allow-insecure-tls-fallback`, `allow-websocket`, `disable-udp`,
  `enable-udp-punch`, `enable-ipv6-punch`, `ice-servers`, `use-raw-tcp-for-api`.
- Controller protection: `nemo-require-encrypted-session`, `nemo-require-secure-rendezvous`,
  `nemo-sealed-request`, `nemo-company-network-only`.
- Outgoing: `nemo-outbound-enabled`, `nemo-outbound-targets`, `nemo-direct-timeout-ms`,
  `nemo-knock-enabled`, `nemo-knock-port`, `nemo-knock-delay-ms`, `nemo-knock-user`,
  `nemo-knock-source-ip` (knock **keys**: see K3).
  - On a private device these two outgoing keys come from the global or user policy **and** from the
    device's own inline or named device policy, merged stricter-wins:
    - `N` from any source wins.
    - Target lists are intersected.
  - Reason: `controller_policy_rejection` enforces the *inline* copy at the rendezvous (2.7). If the
    poll dropped it, the ticket (which reads the final options) would allow what the rendezvous refuses.
- Computed by the server: `nemo-clock-tolerance-secs`, `nemo-ab-version`, `nemo-control-epoch`,
  `nemo-control-ticket`, `nemo-logged-in-user`.
  - **Rule (review): a server-computed key is never taken from a policy.** The allowlist retain drops
    all of them, and the server then inserts its own values. `nemo-logged-in-user` is inserted only
    from the resolved session.
  - Reason: `nemo-logged-in-user` is in `CLIENT_MANAGEMENT_POLICY_KEYS` (`:298`), so even the
    sanitized global policy may carry it. Nothing removes it on the no-user path (it is only inserted
    at `:7527`), and the ticket reads the user back from the options (`:7648`).
  - A policy-sourced `nemo-logged-in-user=alice` would therefore give a **signed-out** device a ticket
    as alice, with her ACL and permissions. That is a pre-existing defect for company devices too;
    log it.
  - Likewise, `nemo-direct-endpoints`, `nemo-knock-keys`, `nemo-peer-keys` and `nemo-blocked-ids` are
    only overwritten when the computed value is non-empty (`:7579-7612`; "a map typed by hand into the
    global policy still works"). So for a private device "not sent" must be an explicit removal.

  Changed for private devices:
  - `nemo-require-login` is **always `Y`** (5.1).
  - `nemo-direct-endpoints` and `nemo-knock-keys` are sent only while a user is signed in, and only
    for ids the ticket lists (the user's ACL ∩ outbound ∩ not blocked ∩ not private). Without a user,
    neither key is sent (2.5 correction).
  - `nemo-peer-keys` is cut down to the same id list. It is a public-key map, but on an unmanaged
    machine it is also a full inventory of the fleet.
- New: `nemo-device-class=private` (5.2).
- *Moved to K3 by the review:* the controller-side session preferences. `policy.allow_user_override`
  is one flag for the whole policy (5.1). With a normal user's policy (flag off) every delivered
  preference would be **locked** on the employee's own PC. None of them is security-relevant: what a
  session may do is enforced by the *target* through ControlPermissions and the ticket.

**K2: never delivered to a private device** (its incoming side):

`nemo-permanent-password`, `verification-method`, `approve-mode`, `temporary-password-length`,
`allow-numeric-one-time-password`, `access-mode`, `enable-keyboard`, `enable-clipboard`,
`enable-file-transfer`, `enable-camera`, `enable-terminal`, `terminal-persistent`, `enable-audio`,
`enable-tunnel`, `enable-remote-restart`, `enable-record-session`, `enable-block-input`,
`enable-privacy-mode`, `enable-remote-printer`, `enable-perm-change-in-accept-window`,
`allow-remote-config-modification`, `allow-remote-cm-modification`, `one-way-file-transfer`,
`one-way-clipboard-redirection`, `direct-access-port`, `whitelist`,
`allow-auto-disconnect`, `auto-disconnect-timeout`, `allow-only-conn-window-open`,
`allow-auto-record-incoming`, `allow-remove-wallpaper`, `allow-linux-headless`,
`allow-logon-screen-password`, `enable-trusted-devices`, `keep-awake-during-incoming-sessions`,
`pre-elevate-service`, `allow-hostname-as-id`, `disable-change-permanent-password`,
`nemo-lock-after-session-end`, and the server-computed `nemo-blocked-ids` (used only by a target)
together with the `direct-server` injection (`:7675-7699`). (`nemo-require-control-ticket`,
`direct-server` and `enable-lan-discovery` were here in the draft; they are now **forced** in K4.)

Withholding the user's `enable-*` keys does **not** change what that user may do on company computers.
Those bits come from `control_bits_for_user` on the server (2.2). Withholding does not switch the
incoming features *off* either (2.8, `option2bool`). The device falls back to its own settings, which
is harmless only because K4 refuses every incoming login first.

**K2b: withheld, unclassified** (the rest of `CLIENT_MANAGEMENT_POLICY_KEYS`, diffed by the review;
withheld by the allowlist rule; to be confirmed key by key at implementation):
`allow-auto-update` (also refused by the client, `POLICY_DENIED_KEYS`), `enable-abr`,
`allow-always-software-render`, `enable-directx-capture`, `enable-android-software-encoding-half-scale`,
`av1-test`, `enable-flutter-http-on-rust`, `file-transfer-max-files`, `allow-https-21114`,
`allow-ask-for-note`, `allow-deep-link-password`, `allow-deep-link-server-settings`, `display-name`,
`avatar`, `remove-preset-password-warning`, `sync-ab-with-recent-sessions`, `sync-ab-tags`,
`filter-ab-by-intersection`, `hideAbTagsPanel`, `current-ab-name`, `remote-menubar-drag-left`,
`remote-menubar-drag-right`, `remoteMenubarState`, `peer-sorting`, `peer-tab-index`, `peer-tab-order`,
`peer-tab-visible`, `peer-card-ui-type`, `printer-incomming-job-action`, `allow-printer-auto-print`,
`printer-selected-name`, `disable-floating-window`, `floating-window-size`,
`floating-window-untouchable`, `floating-window-transparency`, `floating-window-svg`, `keep-screen-on`,
`disable-group-panel`, `disable-discovery-panel`.

**K3: the operator decides** (default **not** delivered; each can be ticked on in the dashboard):

- Updates: `nemo-auto-update` and `nemo-update-version`. Should the company install software
  automatically, with a privileged installer, on a private PC?
- UI lock-down: `hide-security-settings`, `hide-network-settings`, `hide-server-settings`,
  `hide-proxy-settings`, `hide-remote-printer-settings`, `hide-websocket-settings`, `hide-stop-service`,
  `hide-tray`, `hide-username-on-card`, `hide-help-cards`, `hide-powered-by-me`,
  `main-window-always-on-top`, `disable-change-id`, `disable-unlock-pin`.
- Secrets: `nemo-knock-key` / `nemo-knock-hmac-key` (the fleet-wide SPA key),
  `default-connect-password`, `proxy-url` / `proxy-username` / `proxy-password`.
  - The per-peer `nemo-knock-keys` stay in K1, but only with a signed-in user and filtered to that
    user's ticket targets.
  - The draft said they were "ACL-filtered" already. Today they are filtered only by
    `nemo-outbound-targets` (2.5).
- Recording and identity: `allow-auto-record-outgoing`, `video-save-directory`, `nemo-alias`,
  `preset-*`, `register-device`, `enable-check-update`.
- Controller-side session preferences (moved here from K1 by the review; one tick for the whole
  group, delivered only if the operator wants a fleet look on private PCs): `view_only`,
  `show_monitors_toolbar`, `collapse_toolbar`, `show_remote_cursor`, `follow_remote_cursor`,
  `follow_remote_window`, `zoom-cursor`, `show_quality_monitor`, `disable_audio`,
  `enable-file-copy-paste`, `disable_clipboard`, `lock_after_session_end`, `privacy_mode`, `touch-mode`,
  `i444`, `reverse_mouse_wheel`, `swap-left-right-mouse`, `displays_as_individual_windows`,
  `use_all_my_displays_for_the_remote_session`, `view_style`, `scroll_style`,
  `edge-scroll-edge-thickness`, `image_quality`, `custom_image_quality`, `custom-fps`,
  `codec-preference`, `sync-init-clipboard`, `enable-confirm-closing-tabs`,
  `enable-open-new-connections-in-tabs`, `use-texture-render`, `allow-d3d-render`, `enable-hwcodec`,
  `trackpad-speed`, `show-virtual-mouse`, `show-virtual-joystick`,
  `keep-awake-during-outgoing-sessions`, `theme`, `lang`.
  - A multi-monitor note: `displays_as_individual_windows` and
    `use_all_my_displays_for_the_remote_session` change how a 2-monitor controller shows a 2-monitor
    workstation.
  - If they are withheld, the employee's local choice applies. That is the intent, but it must be in
    the multi-monitor regression run (5.7, E2E 8).

**K4: forced closed on a private device** (new, added by the review). The server *sets* these values
after the allowlist, whatever any policy says:

| Key | Forced value | Why |
|---|---|---|
| `nemo-require-control-ticket` | `Y` | Every TBFDesk login without a ticket is refused before any password check (2.8). No ticket lists a private id (5.1), so **every** incoming session is refused by the device itself. This already works on 1.4.24 and needs no client change. The key is in `NEMO_CONTROL_SETTINGS`, so it stays locked even when an admin is signed in. |
| `direct-server` | `N` | No direct listener, even if the user or an earlier company policy stored `Y` locally. Locked because 5.1 sends private devices `allow_user_override=false`. Without that, an admin sign-in (admin policy forces the flag on, `nemo_integration.rs:937-940`, OR-ed in at `:7523`) would turn it into a default the user could change. The ticket requirement still refuses whatever reaches the listener. |
| `enable-lan-discovery` | `N` | Privacy. The LAN pong carries id, hostname, username and MAC (`lan.rs:36-60`). It gates only *answering*; the device can still discover others. Locked the same way as `direct-server`. |

K4 matches the intent of "no workstation policy". It configures nothing the employee uses. It only
locks the incoming side, which a private device must not offer anyway. On conversion back to company
the forced values disappear by clear-on-omit.

---

## 4. Options

### Option A: an empty named policy (or "invert the model"). Zero code.

**What.** Create a named policy "Privat" with no settings and assign it to the device. A variant
inverts the model: keep only K1 in the global policy, move all workstation settings into a named
policy "Arbeitsplatz", and assign that to every company computer.

**What it really does.**
- The empty named policy has **no effect**. Global stays the base (2.1), and a signed-in user's policy
  replaces the device policy anyway.
- The inverted model removes the global workstation keys from private devices, but:
  - The user and admin policy still lands on the private device (2.2), with all incoming permissions on.
  - The device is still controllable (2.4): a ticket with `"*"`, the address book, and the punch when
    company-network-only is off or the device is "Allowed".
  - Without a user, it gets a ticket when sign-in is not required (`:6416`).
  - A stale fleet password stays on a converted device (2.3).
  - There is **no default device policy** (`default_policy_name` is for users only,
    `nemo_integration.rs:188-192`). A new workstation is therefore unhardened until someone assigns
    "Arbeitsplatz". `nemo-require-control-ticket` and `nemo-lock-after-session-end` are missing on it.
    That is a fail-open in the workstation direction.
  - Workstation settings would disappear from a workstation whenever someone signs in on it (user
    policy replaces device policy, `:7516-7528`). This is the effect documented at `:7680-7688`.

**Security.** Gets worse for workstations, only cosmetic for private devices. **Rejected.**

### Option B: a per-device "skip global policy" flag (the literal request)

**What.** A server flag per peer. Its poll starts from an empty policy plus the K1 infrastructure keys
instead of `global_policy()`. Everything else stays as it is.

**What it does.** The global workstation keys no longer reach the device. But:
- the user and admin policy still applies incoming keys to it;
- it can still be controlled through every path in 2.4;
- no sign-in is required;
- there is no permission cap;
- the stale password stays.

To decide which global keys are "infrastructure" you need the K1 allowlist anyway. So B is the first
quarter of C, without the part that protects the employee. **Not recommended on its own.** It is a
possible phase 0.

### Option C: a "private (controller-only)" device class. RECOMMENDED

**What.** The operator, and only the operator, marks a device **private**. From then on the server and
the client treat it as a pure controller:

1. **Filtered policy.** The poll carries only K1, the K3 items the operator ticked, and the forced K4
   values. Global, user and admin policy pass through the same allowlist. Inline and named **device**
   policies contribute only their outgoing keys, stricter-wins (K1). `allow_user_override` is always
   `false`.
2. **Sign-in always required.** With no LDAP user, there is no ticket and the rendezvous refuses the
   device as a controller, whatever the server-wide `require_login` says. The device has no rights of
   its own; it only carries a signed-in user's rights.
3. **Never a target.** The server refuses it at the punch and relay, leaves it out of tickets, the
   address book, endpoint maps, knock maps and peer-key maps, and will not store a direct endpoint or
   knock key for it.
   - Every client version refuses every ticketless or unlisted login itself, through the forced
     `nemo-require-control-ticket=Y` (K4).
   - A 1.4.25+ client also refuses with its own wording, covers the switch-sides path, does not answer
     punch, relay or LAN discovery, and runs no direct listener. On Android it offers no screen sharing.
4. **Optional permission cap for private controllers.** For example no file transfer, no clipboard, no
   terminal, no tunnel. This is merged "stricter wins" with the user's permissions, both at the
   rendezvous and in the ticket.
5. **Migration clean-up.** On conversion, the server drops all sessions to the device. While the
   device is private, a 1.4.25+ client keeps its stored permanent password empty (a rule, not a
   one-shot action, 5.2).
6. **Block and revoke reach a controller.** Blocking a private device also ends its running outgoing
   sessions (2.8). Today Block ends only sessions *to* the blocked peer.

**Security result.** See the matrix in 5.5. Nobody can control the private device through TBFDesk. It
can control exactly what its signed-in user may, minus the cap.

**Effort.** Rough estimate: server about 400 lines plus tests; client about 150 lines of Rust plus
three UIs and translations. It can be split into a server-only phase 1 and a client phase 2.
- Phase 1 works with 1.4.24 clients. Thanks to K4 the devices refuse incoming sessions themselves,
  including devices converted from company.
- Phase 2 adds the client's own wording and the switch-sides arm, takes away the incoming UI, and
  clears the password.

### Option D: an outgoing-only build plus server-side "controller-only" enrolment (added by the review)

**What.** Private devices get a separate installer with `conn-type=outgoing` in `HARD_SETTINGS` (the
stock outgoing-only mode, 2.6). The server learns to accept a controller that proves a bound device
key but never sends `RegisterPeer`:
- the poll accepts a device-key-proven id that has no peer row (today a 404, `:7411-7416`);
- `controller_policy_rejection` accepts it (today "controller is not registered", `:6484-6486`);
- the class lives on the `DeviceKey`.

**For.**
- "Never a target" holds by construction. The device never registers (`rendezvous_mediator.rs:86-90`),
  so hbbs cannot broker a session to it.
- The stock UI hides every incoming element in all three UIs; no new UI predicate is needed.
- It is a one-way setting the server cannot undo (the Q3 ratchet for free).
- The server is not released yet, so the protocol change is cheap now.

**Against.**
- A second installer and build per platform, which the employee can swap for the normal one. That
  is harmless, because the server still classifies by key, but it is confusing.
- Several server paths key on "registered" and must be reviewed one by one: the poll, both
  rendezvous arms, the address book, `peer_key_map`, stats and the hostname record.
- The client's own direct listener and LAN code still exist in the binary. They are off, but they
  are not removed.
- A user cannot switch a device between classes without reinstalling.

**Verdict.** A credible long-term alternative to C, and the cleanest answer if Q3 is "one-way". It
can be added after C: C's server-side class, allowlist and cap are needed by D as well.

*Not pursued:* no TBFDesk on private devices at all. Employees would reach a company jump host or
VDI over VPN and control workstations from there. This keeps company data off unmanaged machines (5.5
risks), but it is an infrastructure decision outside TBFDesk.

---

## 5. Recommended design (Option C) in detail

### 5.1 Server

**Data model** (`IntegrationConfig`, `nemo_integration.rs:160-253`; every field `#[serde(default)]`,
so upgrading changes nothing):

```rust
/// Peer id -> device class. Absent = "company" (today's behaviour).
pub device_classes: HashMap<String, String>,          // "private"
/// Settings that apply to every private device.
pub private_policy: PrivateDevicePolicy,
pub struct PrivateDevicePolicy {
    /// Cap on what a private controller may do, using CONTROL_PERMISSION_KEYS names,
    /// value "N" only (a cap can forbid, never grant).
    pub cap: HashMap<String, String>,
    /// K3 keys the operator chose to deliver anyway.
    pub deliver: Vec<String>,
}
```

`DeviceKey` (`:280-301`) gets `kind: String` (`"" | "private"`) as a **provisioning hint**. When the key
is bound, by hand (`set_device_key_peer_id`) or by claim approval, the hint is copied into
`device_classes`. From then on the map is the single authority, editable in the dashboard.

**Correction (review): the class follows the device key, not the peer row.**
- `delete_peer_ids` (`:8219-8238`) leaves the bound `DeviceKey` in place, so the same machine
  re-registers with the same id. If deleting the peer also removed the class, it would come back as
  *company*, and fail open.
- So `delete_peer_ids` keeps the class entry.
- `delete_device_key` and a rebinding through `set_device_key_peer_id` move or remove it together
  with the binding. A rebind to a new id carries the class to the new id.

**API.** The class routes below sit under the `is_authz_path` prefixes (`:6316-6328`), so each change
bumps the control epoch and outstanding tickets are revoked. The claim approval
(`/nemo/api/device-keys/:id/claim/approve`) is under the `/nemo/api/device-keys` prefix too.
`POST /nemo/api/one-file-installer` is **not** an authz path. It needs no epoch bump, because it
only creates a key with a hint; the class takes effect at binding.

- `POST /nemo/api/peers/:id/device-class {"class":"private"|"company"}`. It writes the map, calls
  `set_peer_terminate(id)` (`:1651`, the same mechanism `block` uses at `:7807`), and records the event
  `device-class-changed`.
- `PUT /nemo/api/policies/private` for `private_policy`.
- `POST /nemo/api/device-keys` and `POST /nemo/api/one-file-installer` accept `kind`.
- `PeerResponse` (`:1328`) gets `device_class`.

**Poll** (`client_policy`, `:7394`):

```rust
let private = integration::device_is_private(&peer.id);
let require_login = integration::require_login() || private;       // replaces :7514
let mut policy = global_policy();                                   // :7494 unchanged
apply_api_tls_defaults(..);
match &user {                                                       // borrow: `user` is used again below
    Some(session) => { /* :7520-7528 unchanged: user policy on top */ }
    None if private => { policy_source = ("private", ..); }
    None => { /* :7535-7547 unchanged */ }
}
// Named, user and admin policies are stored unsanitized (2.8): never trust a class from a policy.
policy.options.remove("nemo-device-class");
if private {
    policy.options.retain(|k, _| private_key_allowed(k));           // K1 + ticked K3; drops EVERY server-computed
                                                                    // key, nemo-logged-in-user included
    if let Some(s) = user.as_ref() {                                // re-insert the user from the session only
        policy.options.insert("nemo-logged-in-user".into(), s.username.clone());
    }
    merge_outbound_stricter(&mut policy.options,                    // K1: inline + named device policy,
        &management_policy_from_peer(&peer.management_policy),      //     outgoing keys only
        integration::device_policy(&peer.id).as_ref());
    for (k, v) in PRIVATE_FORCED { policy.options.insert(k.into(), v.into()); }   // K4
    policy.options.insert("nemo-device-class".into(), "private".into());
    policy.allow_user_override = false;                             // everything sent is locked
}
// :7556 then inserts nemo-require-login=Y because require_login is now true.
// When private:
// - skip nemo-blocked-ids (:7579-7584) and the direct-server injection (:7675-7699);
// - send nemo-direct-endpoints / nemo-knock-keys only with a user, filtered to the ticket's
//   explicit target list (not to nemo-outbound-targets alone, 2.5);
// - filter nemo-peer-keys the same way;
// - an empty computed value means the key stays ABSENT: the retain above already removed any
//   policy-sourced copy, and the `if !x.is_empty()` inserts must not be the only writers.
// The `match user` above stays as it is: `user` is still needed after it, so the match borrows it
// (`match &user` / `user.as_ref()`) instead of moving it.
// Build the ticket before the endpoint/knock maps so they can reuse its target list. The maps are
// built at :7597-7612 today, before the ticket at :7643-7664.
```

`policy.allow_user_override` stays a single flag for the whole policy; per-key override is out of
scope. For a private device it is forced to `false`, so every K1/K3/K4 value is locked. The cost is
small: the controller preferences are no longer in K1, and an admin signing in on a private PC can no
longer loosen K4. The client's locked-key rule (`:1347-1348`) still covers the authorization keys on
company devices.

**Ticket.** `build_control_ticket(.., require_login, ..)` (`:6398`) receives the new `require_login`.
A private device with no user then gets **no ticket** (`:6416`). `perm` becomes
`cap_merge(control_bits_for_user(u), private_policy.cap)` when the controller is private. "N" from the
cap sets the two bits to `01`, the same encoding as `:6266`.

**Rendezvous** (`rendezvous_server.rs`, relay arm `:716-830`, punch arm `:1345-1500`):

- *Target:* before `is_peer_allowed` (`:724`, `:1356`), a separate check `device_is_private(target)`
  refuses with its own reason, "target is a private device and cannot be controlled by TBF policy". A
  private device ignores "Allowed" status as a target.
- *Controller:* `nemo_user_rejection_from_field` (`:6448`) gets the controller id. The relay arm
  already passes `authed.peer_id` to the controller gate at `:743`, and the punch arm does at `:1372`.
  `nemo_user_connection_rejection` (`:6146`) then treats "private controller, no user" exactly like
  `require_login()` (`:6178-6180`): "log in to TBFDesk to connect".
  - **Correction (review):** use the identity that `resolve_controller_identity` (`:6529-6560`)
    settles on, not only the proven one. With `require_device_key` off, `authed` is `None` and a
    proven-only check would silently skip the private rule.
  - The resolved identity is the proven id, or the asserted id with its uuid checked against the
    registered one. An id that cannot be resolved is already refused by the controller gate.
  - Private-class enforcement on the controller side is only as strong as the device-key proof.
    `require_device_key` is on by default (2.5); see Q2.
- *Cap:* `control_permissions_for` (`:6230`) applies the cap when the resolved controller is private.
  It needs the identity as a new parameter, as above. The cap also takes effect when the user's policy
  sets no permissions at all (`:6240` returns None today when `bits == 0`).
  - The cap can only switch whole features off. "Download from company to the private PC: no; upload:
    yes" has no ControlPermissions bit.
  - `one-way-file-transfer` and `one-way-clipboard-redirection` are *target-side* built-in options
    (`connection.rs:2037`, `:2053`, `:3180`). They cannot be expressed per controller without a new
    bit, which would be a protocol change in hbb_common (Q4).

**Other server paths.**

- `ticket_targets` (`:6366`): private ids join `blocked` for the exclusion (`:6386`).
  - With any private device present, tickets become explicit lists instead of `"*"` (`:6380-6382`).
  - This is not a new cost: any fleet with one blocked peer already gets explicit lists (2.8).
  - Together with K4 this is the **main** client-side layer for old clients, not an extra one. A
    1.4.24 private device refuses a ticketless login (forced requirement) and a ticket that does not
    list it (`Denied`, `nemo_control.rs:220-228`).
  - It relies on every `"*"` ticket from before the classification being dead. Every class change and
    every claim approval is an authz path and bumps the epoch, so it is.
- `direct_endpoint_map` / `knock_key_map` (`:2002`, `:2138`):
  - skip private targets;
  - for a private *controller*, they are built from the ticket's target list rather than from
    `nemo-outbound-targets` (2.5 correction), and are empty when nobody is signed in.
  - Converting a company PC to private also deletes its stored endpoint and per-peer knock key. The
    operator must remove the edge router forward and the fwknop stanza by hand; the dashboard says so.
- `peer_key_map` (`:6057`): leave private ids out for everyone, and filter the map to the ticket's
  targets for a private controller.
- `set_peer_direct_endpoint` / `set_peer_knock_key_route` (`:7833`, `:7865`): `400` for a private peer.
- `api_ab_get` (`:3380-3383`): skip private peers.
- `handle_online_request` (`rendezvous_server.rs:1605`): report private ids as offline. Optional,
  for privacy only (Q8).
- **Block** (`block_peer`, `:7790`): for a private peer, also call
  `terminate_sessions_from_controllers(&[id], "private device blocked")`, as `delete_device_key` does
  (`:4396-4399`). Without it, a lost laptop keeps its running sessions (2.8).
  - The same gap exists for company controllers; it should be fixed for all and logged in
    `OPEN-TODOS.md`.
  - A class change to private and every edit of `private_policy.cap` also end the sessions *from*
    the affected private controllers, so the new cap applies at once. This is the same as the
    "permissions changed" path at `:3768-3769`.
- Policy source label: `"private"` (#43 report, `PolicyDelivered.source`).
- **Correction (review): policy editor keys.** `nemo-device-class` is not added to
  `CLIENT_MANAGEMENT_POLICY_KEYS`. That keeps it out of the **global** and **inline** policies, which
  are the only two that `sanitize_management_policy` (`:8486-8513`) sees.
  - Named, user and admin policies are stored unsanitized (2.8), so the key could still arrive through
    them. That is why the poll above always **removes** it before inserting the server's own value.
  - The class is set only through the class API.
  - A company device that got the key from a named policy would otherwise refuse all incoming
    sessions. That fails closed, but it is wrong.

### 5.2 Client (shared Rust; the UIs stay thin)

**New key** `nemo-device-class` in `src/nemo_control.rs`. Add it to `NEMO_CONTROL_SETTINGS` (`:53-58`).
That makes it:
- always applied **locked** (`nemo_management_client.rs:1347-1348`);
- **policy-only**, never stored from a settings save (`is_policy_only_key` `:457-462`);
- accepted by `option_scope` (`:1394-1406`).

```rust
pub const OPTION_DEVICE_CLASS: &str = "nemo-device-class";
pub fn is_private_device() -> bool { Config::get_option(OPTION_DEVICE_CLASS) == "private" }
```

It holds before the first poll. `restore_cached_policy` (`:594`) runs from
`nemo_management_client::start()` (`:621-622`), which `server::start_server` calls (`server.rs:629`)
before the IPC and listeners start. It also holds offline, by the existing "policy sticks until the
server replaces it" rule.

If Q3 is decided as a **one-way ratchet**, `NEMO_CONTROL_SETTINGS` is the wrong home. Its keys are
policy-only: they are cleared on omit and scrubbed from storage. The ratchet then needs a second,
durable copy that the policy can set but never clear, in the way `apply_policy` persists
`nemo-require-login` (`:1184-1191`), only without the clear. `is_private_device()` then reads
"policy says private OR ratchet set".

**Refusal points** (defence in depth: the server already refuses, and K4 already makes every client
version refuse ticketless or unlisted logins; these add the clear wording and the paths K4 misses):

1. `connection.rs` `on_message`, right where `LoginRequest` arrives and **before**
   `apply_management_authorization` (`:2541-2544`). This covers every login kind: desktop, file
   transfer, port forward, terminal, camera. If private: `send_login_error("This is a private device.
   It cannot be controlled through TBFDesk.")`, post a `client-audit-conn` record with
   `action: "refused", reason: "private device"`, and return false.
1b. **Switch sides** (review): the `SwitchSidesResponse` arm (`connection.rs:2824-2849`,
   `feature = "flutter"`, desktop only) authorises without `apply_management_authorization`, so
   neither K4 nor point 1 sees it.
   - Refuse there too when private.
   - Also refuse to *offer* the switch: no `insert_switch_sides_uuid` for `Data::SwitchSidesRequest`
     (`ipc.rs:986-994`).
   - Hide "Switch Sides" in the Flutter session toolbar (`common/widgets/toolbar.dart:288-296`).
     Sciter has no switch sides (`ui_session_interface.rs:1513-1514`).
   - The server-side target refusal already blocks the connect-back, because it is brokered by hbbs.
     This is the client half.
2. `rendezvous_mediator.rs` `handle_punch_hole` / `handle_request_relay` / `handle_intranet`
   (`:669`, `:485`, `:576`): return early when private, so no connection is opened at all. Registration
   (`RegisterPeer`) **stays**, because the server needs it (2.5).
3. `direct_server` (`:895-905`): add `|| is_private_device()` to the `disabled` condition.
4. `lan.rs:38-42`: do not answer discovery pings when private.
5. Android: the screen-sharing service must refuse to start when private (see 5.3).

**Migration action** in `apply_policy` (`:1095`). **Corrected by the review: a rule, not an edge
trigger.** On every applied policy that carries `nemo-device-class=private`, if a permanent password
is stored, clear it.
- In the service process use `Config::set_permanent_password("")`.
- In a UI process use the IPC path that `apply_permanent_password` already uses (`:1276-1283`).
- Log it and send an audit record the first time.

The draft's "previous policy without it, new policy with it" could never fire for a device converted
while it ran 1.4.24. `policy_for_storage` (`:1286-1296`) caches the whole policy, unknown keys
included, so after the upgrade to 1.4.25 the "previous" policy already says private.

Both the service and the UI process poll and apply (`server.rs:629` and `flutter_ffi.rs:59` both
call `start()`), so the rule must be idempotent anyway.

Clear-on-omit (2.3) removes only the *managed* copies of the withheld keys. Locally stored incoming
settings stay as they were (2.8); K4 makes that harmless.

**Outgoing** needs no change. `check_nemo_outbound_policy` (`client.rs:204-227`), the ticket
(`nemo_control::login_proof`) and the login gate (`nemo-require-login`, persisted at `:1184-1191`)
already do the right thing with the filtered policy.

### 5.3 UI: same key, same gating, same wording in all three

| | Sciter (`src/ui/index.tis`) | Flutter desktop | Flutter Android |
|---|---|---|---|
| Helper | `function nemoPrivateDevice() { return handler.get_option("nemo-device-class") == "private"; }`, defined **above `class App`** (no hoisting, cf. `:174-178`) | `bool nemoPrivateDevice()` in `flutter/lib/common/nemo_policy.dart` via `bind.mainGetOptionSync` (exists, **no codegen**) | same helper |
| Hide "Your desktop" ID + password | Use `var noIncomingUi = outgoing_only \|\| nemoPrivateDevice()` at `:2127` (the `#open-settings` link), `:2129` (tip text), `:2130` (hidden `MyIdMenu`), `:2131-2134` (ID card) and `:2135` (`PasswordArea`). See the note below. | `desktop_home_page.dart:85` (preset-password warning), `:96-97` (ID/password boards), `:155-158` (bottom-left settings button), `:521-555` (`buildTip`): `isOutgoingOnly \|\| nemoPrivateDevice()` | `mobile/pages/home_page.dart:61-64`: no ChatPage/ServerPage tab when private; `initPages()` must re-run when the class changes |
| Banner | new `.nemo-private-device` line under the policy-problem line (`:2160`) | same place as `nemoPolicyProblemText` (`connection_page.dart:652-679`) | `nemo_mobile.dart` badge area |
| Incoming settings greyed out with a tooltip | Security tRows (`:1761` `pEnable`, `MyIdMenu` `:896`) | `desktop_setting_page.dart` `_Safety.permissions()` / `password()` (`:1101`, `:1223`); the Security tab list is `static final tabKeys` (`:68-73`), evaluated once per process, so grey inside the tab rather than dropping the tab | `settings_page.dart` security section (`:266` already branches on `outgoingOnly`), `server_page.dart` `_DropDownAction` |
| Switch Sides | (not offered by Sciter) | hide in `common/widgets/toolbar.dart:288-296` when private | (not offered on Android) |
| Live update | `outgoing_only` is a **const** evaluated at page load (`index.tis:9`); `nemoPrivateDevice()` is a function, so the class sites re-evaluate on the existing re-render | rebuild on the existing option poll | as desktop |

**Do not alias `outgoing_only` / `bind.isOutgoingOnly()` wholesale** (review). Making the Rust wrappers
(`ui.rs:370-371`, `flutter_ffi.rs:2624-2625`) return true for private devices would look like one
thin change for both UIs, but:
- Sciter would hide the **account bar** (`index.tis:2110`, `:2117`), which is the sign-in a private
  device requires, and ConnectStatus (`:2164`).
- Flutter would switch the stored window-size keys (`common.dart:1791`, `:2133-2137`) and several
  settings-page sections (`desktop_setting_page.dart:464`, `:641`, `:703`, `:783-819`, `:1845`).
- Sciter's settings menu lives inside `MyIdMenu` in the ID card. Hiding the card without also taking
  the outgoing-only fallbacks at `:2127`/`:2130` would make Settings unreachable while signed in.

So use the per-site list above. `rendezvous_mediator.rs:86` (registration) and
`platform/windows.rs:1795`, `:3904`, `:3921` keep calling `config::is_outgoing_only()` unchanged.

The remaining outgoing-only sites are left **unchanged** by default, to be confirmed at
implementation:
- `desktop_home_page.dart:585-622` (install, permission and SELinux cards);
- `connection_page.dart:334`;
- `tabbar_widget.dart:172`;
- mobile `settings_page.dart:266`, apart from the security section above.

The class is readable from both UIs: `get_option_for_ui` / `main_get_option_sync` and Sciter's
`get_option` blank only `NEMO_SCRIPT_SECRET_OPTIONS = ["nemo-device-key"]`
(`ui_interface.rs:1864`, `:2027-2031`; `flutter_ffi.rs:966-967`).

**Wording** (`src/lang/en.rs`, `src/lang/de.rs`):

| Key | en | de |
|---|---|---|
| `nemo_private_device_banner` | Private device: this computer can connect to company computers, but it cannot be controlled through TBFDesk. | Privates Gerät: Dieser Computer kann sich mit Firmencomputern verbinden, kann aber über TBFDesk nicht ferngesteuert werden. |
| login error sent to the controller | This is a private device. It cannot be controlled through TBFDesk. | Dies ist ein privates Gerät. Es kann über TBFDesk nicht ferngesteuert werden. |
| rendezvous refusal | Target is a private device and cannot be controlled by TBF policy | Das Ziel ist ein privates Gerät und kann laut TBF-Richtlinie nicht ferngesteuert werden |
| setting tooltip | Not available on a private device | Auf einem privaten Gerät nicht verfügbar |

The sign-in gate reuses the existing require-login texts.

Notes on the wording (review):
- **Case.** The server sends the reason in lower case ("target is a private device and cannot be
  controlled by TBF policy", 5.1). The translation key is the capitalised form, as for the existing
  pair "Target is not allowed by TBF policy" (`de.rs:947`).
- **Controllers on 1.4.24** have no entry for the new server string and show it in English.
- **In phase 1**, a 1.4.24 *private* device refuses with the existing, translated K4 texts: "This
  computer only accepts sessions authorized by your TBFDesk server. ..." or "Not authorized: the
  connecting computer is not permitted to control this computer" (`de.rs:963`, `:965`).

### 5.4 Dashboard UX (`nemo_admin.html`)

- **Peers table:** a "Class" badge, *Company* or *Private: controller only*, with a filter chip.
- **Peer detail → Management** (`:3192-3204`): a "Device class" select. When it is *private*:
  - the "Device policy" select (`:3195-3200`) stays enabled, with the note "On a private device only
    the outgoing settings (Outgoing connections, Allowed target IDs) of this policy apply; everything
    else is ignored". This matches the stricter-wins outbound merge in K1 (corrected by the review;
    the draft disabled the select);
  - the "Direct connection" panel (`:3139-3190`) is disabled, with "A private device cannot be
    reached";
  - "Allow" is relabelled *not applicable (controller only)*.
  - "Block" stays, meaning "may not connect anywhere". It now also **ends the device's running
    outgoing sessions** (5.1). The button tooltip says so, and it points to "Revoke device key" for a
    lost or stolen device.
  - Switching asks for confirmation: "Sessions to this device end now; its incoming settings and
    stored access password are removed on its next poll (within 30 s)". When the device had a direct
    endpoint or knock key, add: "Its direct endpoint and knock key are deleted. Remove the port
    forward and the router stanza by hand."
- **Applied policy line:** source `private` (`policySourceText`, `:2478`).
- **Settings → Device keys:** "Generate device key" (`:1109-1112`) and the one-file installer get a
  **Kind** choice, *Company computer* or *Private device (controller only)*. The pending-claim row and
  the Approve button show the kind, so the operator sees what approval will create.
- **ACL & Policy → new "Private devices" card:**
  1. the permission cap: the `CONTROL_PERMISSION_KEYS` controls with *No cap* / *Deny* only;
  2. "Sign-in required: always" shown fixed;
  3. the K3 tick-list ("also deliver to private devices");
  4. a live preview of which Global-defaults keys reach private devices and which are withheld.
- **Global client defaults** text (`:1007`): add "Private devices receive only the connection settings
  from here."
- **Connections / Log:** controller badge *private*; event `device-class-changed`.

### 5.5 Security: who can control what

| Actor → action | Today (private PC registered like any device) | Option C |
|---|---|---|
| Company admin → **control the private PC** | Possible: AB lists it, ticket `"*"`, punch when company-only is off or the PC is "Allowed", direct/LAN with the pushed or stale fleet password | **Refused**: rendezvous (server), not in AB, ticket or endpoints (server). Every client version refuses a ticketless or unlisted login before any password (K4). 1.4.25+ also: own wording, no listener, no punch/relay answer. |
| Anyone with the fleet password → private PC | Works when the global or user policy delivered `nemo-permanent-password` | Password never delivered. A stale copy is useless for TBFDesk logins (K4 refuses before the password check) and is cleared by 1.4.25+ (5.2). |
| Employee on the private PC clicks **Switch Sides** in a session to a workstation | The workstation connects back and is authorised without ticket or password (`connection.rs:2824-2849`) | **Refused**: the connect-back is a hbbs-brokered session to a private target (server); 1.4.25+ also refuses in that arm and hides the button (5.2 1b) |
| Private PC with nobody signed in **receives** workstation endpoints and per-peer SPA keys | Yes, for every workstation not excluded by `nemo-outbound-targets` (2.5) | **No**: sent only with a user, and only for the user's ticket targets |
| Lost or stolen private laptop, operator presses **Block** | Running outgoing sessions continue; only new ones are refused (2.8) | Block also ends its outgoing sessions (5.1); revoking the device key already does |
| Private PC with **nobody signed in** → company PC | Allowed when the server does not require sign-in (ticket with `user=""`, `:6416`) | **Refused**: no ticket, rendezvous "log in to TBFDesk to connect" |
| Signed-in user on private PC → company PC | User ACL ∩ outbound ∩ not blocked, with the user's permissions | Same, **∧ private cap**, and never another private device |
| Modified client on private PC, direct to a workstation **without** `nemo-require-control-ticket` | Workstation's local settings apply (no ticket checked) | Unchanged. **Recommend `nemo-require-control-ticket=Y` on workstations once private devices are admitted.** The cap is enforced on direct sessions only through the ticket. |
| Server (hbbs) compromise | Controls all policy | Can flip the class back to company. See question Q3 (one-way ratchet). |

Risks that come with admitting private controllers at all, whichever option is chosen:

- The endpoint is unmanaged. A keylogger or screen grabber sees everything typed into and shown in the
  session; clipboard and file transfer can move data off company machines. This is what the cap
  addresses.
- The LDAP password is typed on an unmanaged machine. The session token is bound to the device key
  (TASK #19, `:6159-6168`), but the password itself is exposed.
- The owner can copy their own device key. It authenticates only that peer id, and sign-in is still
  required.

- A signed-in session lasts a fixed 12 h (`SESSION_TTL_SECS`, 2.8). On a laptop that may be lost,
  that is a long window (Q12).

What the company learns about the private device:
- hostname (`:7455`), client version, and the applied-policy report;
- audit records of outgoing sessions;
- **its public IP address**, i.e. roughly where the employee is. `record_peer_seen` stores
  `last_public_addr` on every registration (`:6590-6597`), and the connection rows keep
  `source_addr`.
- whether it is online, which anyone who knows the id can query (2.4).

That is data minimisation material for the works council (Q8).

### 5.6 Migration and rollout

- **Server upgrade:** the new fields default to empty, so no device is private and nothing changes.
- **Phase 1 (server only; works with 1.4.24 clients):** filtered poll, forced sign-in, target refusal,
  maps/AB/ticket exclusion, cap, dashboard.
  - Old clients drop the unknown `nemo-device-class` (`option_scope`) and still enforce outgoing
    correctly.
  - **Corrected by the review:** old clients *do* refuse incoming locally, through the forced K4
    `nemo-require-control-ticket=Y`. No ticket lists a private id, so a ticketless login is refused and
    a ticket login is `Denied`, both before any password is checked (2.8).
  - That holds for converted company devices too: the stale fleet password stays stored but cannot
    open a TBFDesk session.
  - What phase 1 leaves undone:
    - the device's own wording (controllers see the existing "only accepts sessions authorized..." or
      "not permitted to control this computer" texts);
    - the switch-sides arm (still blocked by the server);
    - clearing the stored password;
    - hiding the incoming UI;
    - not answering LAN pings and not listening, which K4 covers as forced `N` values.
  - The dashboard shows "client older than 1.4.25: private mode enforced by the server and the ticket
    requirement only" (`client_version`, `:1385`).
- **Phase 2 (client 1.4.25+, all three UIs):** own refusal wording, the switch-sides refusal, password
  rule, banner and greying.
- **Converting company → private:**
  - At the dashboard click, the epoch bumps (old tickets are dead) and sessions to the device are
    terminated (≤ 30 s, at the device's next poll).
  - Its stored endpoint and knock key are deleted (5.1).
  - On the next poll, clear-on-omit removes the managed incoming settings, K4 locks the incoming side,
    and a 1.4.25+ client clears the stored password.
- **Converting private → company:** depends on Q3.
- **Data files touched:** `nemo_integration.json` only. Peer DB and `nemo_global_policy.json` are
  unchanged.

### 5.7 Test plan

**Server unit tests** (host: `cargo test --release` in a server worktree):

1. A private poll carries only allowlisted keys.
   - Setup: global holds `nemo-permanent-password`, `enable-keyboard`, `direct-server=Y`, `hide-tray`,
     `approve-mode`, `theme`.
   - None of `nemo-permanent-password`, `enable-keyboard`, `hide-tray`, `approve-mode` or `theme` is
     present.
   - `api-server`, `key`, `nemo-outbound-targets` and `nemo-require-encrypted-session` are present.
   - These are set: `nemo-device-class=private`, `nemo-require-login=Y`, and the K4 values
     `nemo-require-control-ticket=Y`, `direct-server=N`, `enable-lan-discovery=N`.
   - `allow_user_override` is `false` even with an admin signed in.
2. An admin signed in on a private device: no `enable-*` keys in the options, but the ticket `perm`
   equals the admin bits ∧ cap.
3. A private device with no user: no ticket, and `nemo_user_connection_rejection` refuses it even with
   `require_login=false`.
4. `device_is_private(target)` refuses at both rendezvous arms, even with status `Some(1)` and
   company-only off.
5. `ticket_targets` leaves out private ids and no longer collapses to `"*"` when one exists.
6. AB, `direct_endpoint_map`, `knock_key_map` and `peer_key_map` skip private peers; endpoint and
   knock-key routes return 400 for one.
7. A class change bumps the epoch, sets the terminate stamp and records an event.
8. Classification completeness: every key in `CLIENT_MANAGEMENT_POLICY_KEYS` is named in exactly one
   of K1/K2/K2b/K3/K4, and a key named nowhere is withheld.
9. `nemo-device-class` placed in a **named user policy**, the **admin policy** and the **global**
   policy never reaches a company device. The poll removes it; the global copy is also dropped by
   `sanitize_*`.
10. Cap merge: user `Y` + cap `N` gives off; user unset + cap `N` gives off; no cap gives the user's value.
11. A private device with nobody signed in gets no `nemo-direct-endpoints`, no `nemo-knock-keys` and
    no ticket. Signed in as a user allowed only A, it gets the endpoint, knock key and peer key of A
    and of nothing else, even with `nemo-outbound-targets` empty.
12. Block of a private device stamps `terminate` on every target it has a session to
    (`terminate_sessions_from_controllers`). Editing the cap does the same for all private
    controllers.
13. `delete_peer_ids` of a private peer whose device key is still bound keeps the class. After
    re-registration the poll is still private.
14. With `require_device_key` off, a private controller identified only by its marker (uuid checked)
    and no user is refused at both arms.
15. Inline `nemo-outbound-targets=A` on a private device plus a user allowed `A,B` gives a ticket for
    A only, matching the rendezvous gate.
16. Server-computed keys from a policy are ignored on a private device.
    - Setup: global holds `nemo-logged-in-user=alice`, a hand-typed `nemo-direct-endpoints` and
      `nemo-knock-keys`; a named policy holds `nemo-control-ticket`.
    - A signed-out private device gets **no** ticket and none of these values.
    - Signed in as bob, it gets `nemo-logged-in-user=bob`.

**Client unit tests** (container toolchain):

- `nemo-device-class` is locked and policy-only, and survives restart via `restore_cached_policy`.
- The login refusal decision as a pure function, used by both the `LoginRequest` arm and the
  `SwitchSidesResponse` arm.
- The password rule: with a cached last policy that already says private (the 1.4.24 → 1.4.25
  upgrade case) and a stored permanent password, the next apply clears it. A second apply is a no-op.
- `direct_server` stays disabled when private.

**Lab E2E** (integrator; Ubuntu 26.04 GNOME Wayland with Sciter under XWayland and Flutter native,
Win11 VM, Android emulator Pixel 7a; both ends with ≥ 2 monitors):

1. Provision a private laptop through the one-file installer with Kind = private. Check the banner,
   the hidden ID/password card and the greyed security settings in Sciter **and** Flutter desktop. On
   Android, check that the Share-screen tab is gone.
2. With nobody signed in, the login gate appears and Connect is refused with the sign-in wording.
3. Sign in as a normal user and connect to an allowed workstation by relay, then by direct endpoint
   with knock. A forbidden target is refused. With the cap on file transfer, the file-transfer button
   is refused.
4. From a company workstation with an admin signed in, connect to the private device by ID: refused
   with the private-device wording. By LAN IP direct: refused by the device itself.
4b. Flutter desktop on the private device: "Switch Sides" is not offered. With a 1.4.24 private client,
   where it is offered, the connect-back is refused by the server.
5. Convert a company PC to private while a session to it runs: the session drops within 30 s, the
   stored password is gone, and its settings are no longer shown as managed.
6. Mark a 1.4.24 client private:
   - the server-side refusals hold, and the dashboard shows the old-client warning;
   - with the old fleet password still stored and `direct-server` stored `Y` locally, a direct or LAN
     login with that password from a company PC is refused by the device itself with the ticket
     wording (K4).
6b. Block a private device while it controls a workstation: that session ends within 30 s.
7. Restart the private device with hbbs down: it is still private and still refuses incoming.
8. Regression: a private controller with 2 monitors controls a 2-monitor workstation in all, span and
   windows modes, unchanged.

---

## 6. Questions the operator must decide

1. **Default class for unknown devices.** Stay *company* (today; the recommendation), or *private until
   approved as company*? The second is the safest for privacy, but it changes how every workstation is
   onboarded.
2. **Sign-in on private devices.** Always enforced, whatever the server-wide setting (recommended,
   and what this design assumes)?
3. **Who can undo "private".** Can the server switch a device back to company by itself, or should
   private be a **one-way ratchet** on the device (like the seal ratchet) that only re-provisioning on
   the device can undo? The ratchet protects the employee even against a server compromise or a
   mis-click.
4. **Permission cap defaults** for private controllers: which of file transfer, clipboard, terminal,
   tunnel, recording, remote restart, camera are denied by default?
5. **Updates:** deliver `nemo-auto-update` to private devices (company-installed software on employee
   PCs), only offer updates (`nemo-update-version`), or neither?
6. **Secrets:** may the fleet-wide knock key (`nemo-knock-key`/`-hmac-key`) go to private devices, or
   per-peer knock keys only? Is `default-connect-password` ever delivered?
7. **UI lock-down:** may `hide-*` / `disable-change-id` reach an employee's own machine?
8. **Works council / data minimisation:** which data from private devices is kept (hostname, outgoing
   session audit, applied-policy report), and for how long?
9. **Scope:** are Android phones included? Is a Windows service install allowed on private PCs, or
   only a user-mode install?
10. **Out of scope or not:** should an employee ever reach their *own* private PC from the office?
    This design forbids it.
11. **Ticket requirement on workstations** (review): once private controllers are admitted, set
    `nemo-require-control-ticket=Y` on every workstation? Without it, a modified client on a private
    PC that connects directly skips the cap and the user ACL (5.5). Recommended.
12. **Sign-in lifetime on private devices:** keep the fixed 12 h (`SESSION_TTL_SECS`), or a shorter,
    separate lifetime for sessions bound to a private device key?
13. **Switch Sides from a private device:** forbid it (this design), or allow it as the employee's
    explicit consent to one session? Allowing it would need an exception in the server's private-target
    refusal, tied to the switch uuid.
14. **Direction-only caps:** is "no file download to the private PC, upload allowed" needed? It has no
    ControlPermissions bit today, so it would be a protocol change in hbb_common (5.1, Cap).

---

## 7. What this document did not verify

- Nothing was built or run. All behaviour is read from source at the base commits. No lab, VM or
  emulator was used.
- Live UI refresh when the class changes, in particular Flutter `initPages()` on Android and Sciter
  re-render, is assumed from the existing policy-problem line and needs checking during
  implementation.
- That every `LoginRequest` variant passes through `on_message` before
  `apply_management_authorization` (`connection.rs:2540-2544`) was read, not tested.
  - The review found one path that does **not** pass there: `SwitchSidesResponse` (`:2824-2849`,
    5.2 1b).
  - Other non-`LoginRequest` messages before login were not audited one by one.
- The size of explicit ticket lists for large fleets was not measured. Explicit lists already occur
  today whenever any peer is blocked (2.8), so a lab with one blocked peer already exercises the path.
- The K1/K2/K3 split of the less common keys (`register-device`, `file-transfer-max-files`,
  `allow-https-21114`, `enable-abr`, and the K2b list) still needs confirming against how the client
  uses each key. Section 3 errs toward withholding them.
- Review: what a controller does when `nemo-peer-keys` has **no** entry for a target it dials
  directly was not traced. It should not matter, because private ids are never dialled. Check it
  before relying on the peer-key filter as a security layer rather than as data minimisation.
- Review: K4 on a 1.4.24 device is a reading of `connection.rs:2337-2390` and `nemo_control.rs`
  at the base commit, not a lab result. It is lab E2E 6.
- Review: the server-side `merge_outbound_stricter` and the ordering change (ticket before the
  endpoint/knock maps) are design, not checked for borrow or ordering conflicts in `client_policy`.
