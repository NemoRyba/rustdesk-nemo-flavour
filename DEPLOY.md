# Deploying TBFDesk

What produces a shippable artifact, and what to run where. Companion to
`TOPOLOGY-DEPLOYMENT.md` (which describes the network) and `DECISIONS-2026-09-21.md`
(which describes why things are the way they are).

Nothing here has been fielded yet. Where something is untested, it says so.

---

## The short version

| | artifact | produced by | tested |
|---|---|---|---|
| Workstations (Windows) | `dist\tbfdesk-<version>-x64-install.exe` | `scripts/package-windows-client.ps1` on the Windows build host | **no** — needs a Windows host |
| Server (hbbs + hbbr) | `localhost/nemo-hbbs:<version>` container, or a native build + the systemd units | `scripts/build-server-container.sh` / `scripts/build-ubuntu-server-release.sh` | container build: yes |
| Technician clients | same Windows installer, or a native Linux build | as above | — |

---

## 1. Version first

`rustdesk-client-nemo/Cargo.toml` drives `src/version.rs`, the update manifest and what
the updater compares. **Fork versions must be numeric-only.** `get_version_number()`
splits on `-` and parses the suffix with `unwrap_or(0)`, so `1.4.6-tbf1` scores
*identically* to `1.4.6` and the updater would never offer it. Use `1.4.7`, `1.4.8`, or a
numeric fourth part.

Currently **1.4.16** (client); the server is **1.1.15**. Signed, ready-built installers for every
platform are published as a GitHub release — latest `release-2026-10-26`: Windows
`tbfdesk-1.4.16-x64-install.exe`, Debian/Ubuntu `.deb`, Arch `.pkg.tar.zst`, a generic Linux client
tarball, and the hardened server tarball (`hbbs`+`hbbr` 1.1.15), each with a `.sha256`. (The
`.deb`/generic Linux client are VP8/VP9/AV1 only — no hwcodec H.264/H.265 yet; see OPEN-TODOS #42.)

## 2. Windows workstations

```powershell
# on the Windows build host
.\scripts\package-windows-client.ps1
# or with the licence baked into the outer filename:
.\scripts\package-windows-client.ps1 -License "host=tbfdesk.example.com,key=<b64>"
```

Produces one double-clickable `.exe` plus its `.sha256`. On a workstation:

```
tbfdesk-1.4.19-x64-install.exe                  interactive
tbfdesk-1.4.19-x64-install.exe --silent-install  unattended (GPO / RMM)
tbfdesk-1.4.19-x64-install.exe --silent-install --import-setup C:\deploy\pc1.tbfsetup
                                                 unattended AND provisioned, no GUI (§4)
```

**Why a packer and not a renamed exe.** `install_me` copies the folder by filename and
never renames the executable, while the service, shortcuts and UninstallString it
registers all point at `RustDesk.exe`. Running `rustdesk-host=…,.exe --silent-install`
directly therefore yields an install directory with no `RustDesk.exe` in it. The packer
extracts its payload as `rustdesk.exe` and passes its own outer filename through
`RUSTDESK_APPNAME`, which is what `get_license_from_exe_name` reads — so the locked name
goes on the **packer**, not on the inner binary.

**sciter.dll is vendored**, at `downloads/sciter-x64/` with its SHA-256. It is not
downloaded at package time on purpose: a step that fetches a binary off the internet is
neither reproducible nor offline-capable, and it means the bytes that ship are not the
bytes anyone reviewed. The committed copy is byte-identical to the official sciter-sdk
`bin.win/x64` build *and* to the copy the QA lab has been running, so it is the same
engine everything was tested against. Without it the installed client does not start, and
the build only *warns* — which is how the old four-file ZIP was so easy to get wrong.

Its redistribution terms are the one thing left for you: see
`downloads/sciter-x64/README.md`.

### Signing

**Let's Encrypt cannot sign code.** It issues TLS *server* certificates only; there is no
free public CA for Authenticode. Three options:

| | cost | UAC prompt on your fleet | SmartScreen elsewhere |
|---|---|---|---|
| OV/EV certificate | paid, annual | trusted | EV clears immediately, OV builds reputation |
| **self-signed + Trusted Publishers GPO** | **free** | **trusted** | still warns |
| unsigned | free | "unknown publisher" | warns |

For ~15 domain-joined workstations plus a few technician machines, the middle row is the
right answer and it is what `scripts/make-codesign-cert.ps1` sets up:

```powershell
.\scripts\make-codesign-cert.ps1 -Password (Read-Host -AsSecureString)
# then once, on the DC: import dist\tbfdesk-codesign.cer into the workstation GPO under
#   Computer Config > Policies > Windows Settings > Security Settings > Public Key Policies
#   -> Trusted Publishers  AND  -> Trusted Root Certification Authorities
# (both: a self-signed cert is its own root, so without the second it chains to nothing)
.\scripts\package-windows-client.ps1 -SignWith dist\tbfdesk-codesign.pfx -SignPassword <pw>
```

Verify on a workstation: `Get-AuthenticodeSignature <installer>` → `Valid`.

The `.pfx` holds the private key. Treat it like the server signing key: offline, backed
up, never committed.

Note the trust anchor for **updates** is neither of these — the manifest is Ed25519-signed
by the server key and the updater verifies the sha256 before installing. Authenticode is
about the first install and about what the UAC prompt says.

**Publishing an update** is the same file: `POST` it to `/nemo/api/update` with its
sha256. Note that MSI and exe installs are not interchangeable at update time
(`updater.rs` routes on `is_msi_installed()`), so pick one and stay with it. The packer
path is the cheap one and matches the fork's sciter build.

## 3. Server

### Container (what the lab uses)

```bash
cd rustdesk-server-nemo && SODIUM_LIB_DIR=/usr/lib SODIUM_SHARED=1 \
    ZSTD_SYS_USE_PKG_CONFIG=1 cargo build --release
cd .. && scripts/build-server-container.sh        # -> nemo-hbbs:<version> and :latest
```

`PROFILE=debug scripts/build-server-container.sh` for a lab image. It used to take
`target/debug` and tag an unversioned `nemo-hbbs`, so every build silently replaced the
last one and what shipped carried debug symbols.

### Native + systemd (what a real server should use)

`rustdesk-server-nemo/systemd/` now carries the units that match the topology:

- `rustdesk-hbbs-nemo.service`
- `rustdesk-hbbr-nemo.service`
- `rustdesk-hbbr-nemo.service.d/override.conf` — the relay bandwidth caps

The upstream `rustdesk-hbbs.service` / `rustdesk-hbbr.service` are kept for reference but
**will not start**: empty `User=`/`Group=` (systemd rejects that) and a bare
`ExecStart=/usr/bin/hbbs` with none of the TBFDesk flags. Until now the production
configuration existed only in one machine's shell history, so a rebuild would have lost
the relay caps and the whole management-API setup.

```bash
# binaries from the release build (rustdesk-server-nemo/target/release)
install -m 0755 target/release/hbbs target/release/hbbr /usr/bin/
useradd --system --home /var/lib/rustdesk-server --shell /usr/sbin/nologin rustdesk
install -d -o rustdesk -g rustdesk -m 0750 /var/lib/rustdesk-server /var/log/rustdesk-server
install -d -m 0750 /etc/tbfdesk
cat > /etc/tbfdesk/hbbs.env <<'EOF'
NEMO_API_TOKEN=<the admin token>
TBFDESK_RELAY=<server>:21117
TBFDESK_MASK=192.168.0.0/16
EOF
chmod 0600 /etc/tbfdesk/hbbs.env && chown root:rustdesk /etc/tbfdesk/hbbs.env
# the signing key, shared by hbbs and hbbr. Put it in place BEFORE the first start:
# with `-k _` and no id_ed25519 both services refuse to start. A brand-new install with
# no key yet: run `hbbs -k _ --generate-key Y` once in /var/lib/rustdesk-server as the
# rustdesk user, stop it, and never pass that flag again. Back this file up.
install -o rustdesk -g rustdesk -m 0600 id_ed25519 /var/lib/rustdesk-server/
systemctl enable --now rustdesk-hbbs-nemo rustdesk-hbbr-nemo
```

The token goes in `EnvironmentFile`, never inline in `ExecStart` — argv is world-readable
through `/proc` (SEC-11).

**Clean teardown / fresh keys.** To reset a server, the uninstaller
`rustdesk-server-nemo/scripts/uninstall/tbfdesk-uninstall.sh server` (GUI checklist, or headless
`COMPONENTS=svc,bins,keys,db,tls,policy,updates ASSUME_YES=1 DATA_DIR=/var/lib/rustdesk-server
tbfdesk-uninstall.sh server`) stops/removes the services and binaries and wipes the signing keys,
DB, TLS cert and policy state. The `--generate-key Y` step above then mints a brand-new identity.
**New signing keys mean every provisioned client must be re-provisioned** (they fail closed against
the new rendezvous key) — verified end-to-end on the lab.

### TLS for the management API — this is where Let's Encrypt belongs

Since SEC-12 the management API serves **HTTPS by default on any routable bind**, and
refuses plaintext there. With no certificate supplied it generates a self-signed one, which
the client accepts on first use without authenticating it unless `nemo-api-cert-fingerprint`
is pushed to it, and means a browser warning on the admin
dashboard every time.

If the server has a DNS name reachable from the internet — which it will if you follow the
split-horizon DNS recommendation in `TOPOLOGY-DEPLOYMENT.md` — use Let's Encrypt and point
hbbs at the result:

```bash
certbot certonly --standalone -d tbfdesk.example.com
# then in /etc/tbfdesk/hbbs.env (env form: upper case, underscores):
#   NEMO_API_TLS_CERT=/etc/letsencrypt/live/tbfdesk.example.com/fullchain.pem
#   NEMO_API_TLS_KEY=/etc/letsencrypt/live/tbfdesk.example.com/privkey.pem
# or as ExecStart args: --nemo-api-tls-cert ... --nemo-api-tls-key ...
```

The hbbs user needs read access to those files (LE's `live/` is root-only by default), and
the renewal hook needs to restart hbbs — it reads the certificate once at boot.

`--mask` decides which peers count as "same intranet"; set it to cover every internal
network or cross-subnet pairs are forced to relay.

### Relayed-byte metrics (TODO 7)

The dashboard's **Relayed bytes** panel is how you prove sessions are going direct rather
than taking your word for it. hbbs reads the counters from hbbr over hbbr's **loopback**
admin channel, so the default works as-is when both run on the same host, which the
shipped unit does:

```bash
# defaults; set them only to change or disable this
#   NEMO_RELAY_METRICS=127.0.0.1:21117     # "" or N turns it off
#   NEMO_RELAY_METRICS_INTERVAL=5          # seconds
```

Two consequences of that channel being loopback-only: a relay on **another** host shows no
bytes unless you tunnel its port to the hbbs host, and nothing but a hash of the relay
grant crosses it — hbbr never learns a peer id, and the live grant (a 60-second capability
to join a session) never leaves hbbs. A session row with **no bytes** is the good outcome:
the relay was offered, the two machines went direct, the grant expired unused.

**hbbr needs the same signing key as hbbs.** Since the relay control-frame encryption
landed, hbbr offers a signed KeyExchange of its own and the client verifies it against
the server key it already trusts.

**hbbr treats any loopback connection as its command port**, so a relay address of
`127.0.0.1` can never pair. Always hand clients a routable address.

## 3b. Transport and performance defaults

Three defaults changed and none of them is in the unit file — they are compiled in, so a
deployment inherits them without anyone passing a flag.

**`--udp-registration=N` (server) and `disable-udp=Y` (client).** UDP registration has no
key exchange and no device-key proof, so it bypassed both `--key-exchange` and
`require-device-key`. Off by default now, which means every client→server message is
encrypted. A client that is *not* on `disable-udp=Y` will retry forever and never come
online; the server logs a throttled warning naming it. This does **not** disable UDP hole
punching — that is `enable-udp-punch`, a separate switch on a separate path.

**`--key-exchange=require` (server).** Upstream never implemented the server half of this
handshake at all; TBFDesk defaults it to `require`, so every rendezvous TCP connection is
encrypted and carries the client's device-key proof. The modes are `off | offer |
require`. **`off` is a debugging option only** — it sends no offer, which means the channel
is plaintext *and* no client can present a device key, so `require-device-key` is not
enforced on this transport even though the config and the admin API still report it as on
(the management-API login gate is a separate check and does still enforce it). TBFDesk
clients fail closed on an unsecured rendezvous, so `off` also takes the whole fleet offline
— the only thing that can still connect is a stock upstream client, in the clear and
unauthenticated. `require` needs the server signing key, which `-k _` plus `id_ed25519` in
the working directory already gives the unit. Without an `id_ed25519` there, hbbs and hbbr refuse to start
(`Fatal error: no id_ed25519 ...`) rather than minting a key no client trusts.

**Websocket rendezvous and relay (21118/21119) are refused.** They carried no key exchange
and no device auth. Do not forward those ports; there is nothing behind them.

### Tuning: these are OPERATOR settings, not workstation settings

The crux, and the thing an earlier version of this document got wrong: `image_quality`,
`custom_image_quality`, `custom-fps`, `codec-preference` and `i444` all live in the
**controller's** per-peer `PeerConfig` and travel to the workstation in the login message.
They are set on the machine the *operator sits at*. That is good news — a LAN operator and
a technician on a constrained uplink can and should carry different values.

Two consequences that are easy to miss:

- **Managed policy does not reach an existing peer.** `PeerConfig` only falls back to the
  managed default when the stored string is empty, and every save rewrites every field. So
  policy sets the value for *new* peers and greys out the UI; it does not retro-fit a peer
  the operator has already connected to. Set it on the operator machine, or delete the peer
  entry.
- **The workstation runs ONE encoder for all viewers.** Quality follows whoever logged in
  last, fps is the *minimum* across viewers, ABR uses the *worst* delay, and the codec is
  whichever preference is most common (with a nondeterministic tie-break at two viewers).
  **While a technician on a slow link and a LAN operator are both connected, the technician
  drags the whole stream.** Plan around that; it is not tunable.

#### LAN operators (bandwidth is free)

| key | value |
|---|---|
| `image_quality` | `custom` |
| `custom_image_quality` | `300` (~12 Mbps at 1080p on VP9) — `200` on a contended 1 GbE |
| `custom-fps` | `60` — **only takes effect with `image_quality=custom`**; it is not sent otherwise |
| `codec-preference` | `vp9` for CAD line-work, or `h264` if the workstation CPU matters more |
| `i444` | `Y` — only meaningful on VP9/AV1, and only if *every* connected viewer also wants it |

#### Technician on the internet (bandwidth is scarce, CPU is not)

| key | value | why |
|---|---|---|
| `image_quality` | `balanced` or `best` | both have real ABR floors. **Do not** use `custom` with a big number here: the target is a hard ceiling *and* the session starts at it, so it congests before ABR backs off |
| `custom_image_quality` | if you use `custom` at all, size it to the **site uplink**, not to the screen | |
| `codec-preference` | `vp9` (or `av1` if the laptop decodes it comfortably) | the fork's own model charges **hardware H.264 ~2x** the bitrate for the same quality ratio. On a scarce link that is the wrong trade even though the workstation could encode H.264 for free |
| `i444` | `N` | it doubles the chroma planes at an unchanged bitrate, so it costs luma detail exactly where you have none to spare |
| `custom-fps` | leave at 30 | VP9 runs CBR with frame dropping; more frames at a fixed bitrate means fewer bits per frame and smeared line-work |

Encode runs on the strong workstation and **decode runs on the technician's laptop** — that
asymmetry is why the codec choice is the laptop's constraint, not the workstation's.

**VAAPI caveat:** on a Linux workstation using VAAPI, `support_changing_quality` is false,
which disables ABR entirely and pins the ratio at the raw target. A large
`custom_image_quality` there is a permanent demand, not a ceiling ABR will walk down.

Leave **adaptive bitrate on** — it is the one controlled-side key here, read once per
connection, so turning it off for the LAN operators also turns it off for the technician
hitting the same workstation.

While tuning, push `show_quality_monitor=Y` and read the per-session `used preference: …
encoder: …` line to confirm what was actually negotiated. Turn it off afterwards.

Encryption is not a lever: the media path carries one XSalsa20-Poly1305 layer end-to-end,
the relay drops its key after the control frame, and the cipher costs under 0.2% of a core
against 5–20 ms of encode per keyframe.

## 4. Provisioning a workstation

Installing is not the same as provisioning. After H5, a client also needs a **device key**
before hbbs will let it register at all (when `require_device_key` is on, which is the
default):

1. Admin dashboard → Device Keys → generate one, bound to that machine's id — or unbound
   for a machine whose id you do not know yet (first-use claim: it shows up as "key claim
   pending", you Approve it; `DEVICE-KEY-CLAIM.md`). **Download file** gives a `.tbfsetup`:
   the device key plus the server settings, in one value.
2. On the workstation: client → Import device key — or unattended, below.

### Unattended (GPO / RMM / remote PowerShell), 1.4.19+

Install and provisioning in one call; nobody opens the client:

```powershell
$p = Start-Process .\tbfdesk-1.4.19-x64-install.exe -PassThru `
       -ArgumentList '--silent-install', '--import-setup', 'C:\deploy\pc1.tbfsetup'
$null = $p.Handle; $p.WaitForExit(); $p.ExitCode   # 0 done · 1 failed · 2 bad setup value
Remove-Item C:\deploy\pc1.tbfsetup                   # it holds the device key
```

cmd / a batch file: `start "" /wait tbfdesk-1.4.19-x64-install.exe --silent-install
--import-setup C:\deploy\pc1.tbfsetup` then `echo %ERRORLEVEL%`.

Re-provisioning a client that is already installed (new key, moved server), from a pipe:

```powershell
Get-Content C:\deploy\pc1.tbfsetup | & 'C:\Program Files\TBFDesk\TBFDesk.exe' --import-setup - | Out-String
$LASTEXITCODE
```

- **Validated before anything is installed.** A truncated paste or a typo exits 2 and
  leaves the machine untouched; nothing half-provisioned.
- **Lands in the service**, the process that takes incoming sessions — not in the console
  user's (possibly roaming) profile. The installer waits up to 120 s for the fresh service,
  writes, reads back and prints what it set; the key only ever as `device key: imported`.
- **Repeatable:** a setup string without a key plus a separately handed-out bare device
  key works too (`--import-setup srv.tbfsetup --import-setup pc1.key`).
- **Pass a file or `-` (stdin), not the string itself.** A literal setup string on the
  command line still works but warns: it carries the device key, and every process on the
  machine can read another's command line (H26). The installer hands it on to the installed
  client over stdin, never on a command line.
- **Why `$p.Handle` and not `-Wait`:** `-Wait` also waits for every process the install
  starts, so it never returns; without touching `.Handle`, Windows PowerShell 5.1 reports
  an empty `ExitCode`.

`--option nemo-device-key` stays refused in both directions (H26), and the licence name
still has no `devkey=` field — `--import-setup` is the one CLI way in.

Staged rollout: a fresh install has `require_device_key` **on**. Switch it off in the
dashboard first, install and provision, then turn it back on.
The server names every un-provisioned client in its log while it is off.

---

## 5. Upgrading (2026-09-27/28 builds)

Client and server move together. Before an upgrade, copy `/var/lib/rustdesk-server`
(`id_ed25519`, `nemo_integration.json`, `nemo_sessions.json`, `nemo-api-cert.pem`,
`nemo-api-key.pem`, the `nemo_*` state files). Things that break across versions:

- **Port forwarding / RDP** needs both clients on the same build: the tunnel is now
  encrypted, and an older peer still drops the cipher.
- **Relay grants and sealed rendezvous (tag 30)**: an older client against this server,
  or the reverse, cannot relay or cannot register.
- **Sealed login**: fresh servers refuse unsealed logins; current clients never send one.
- **API certificate pin**: hbbs pushes its self-signed certificate's fingerprint in the
  signed policy. If `nemo-api-cert.pem` is regenerated, every pinned client refuses the
  API until the pin is cleared on it. Restore the backed-up cert instead.
- **No backward compatibility for an unstamped policy (2026-09-28):** a client now
  refuses any management policy response with `issued_ts == 0` outright, instead of
  accepting it. Every current server has always stamped this field, so this changes
  nothing between current builds; it matters only if a much older, pre-anti-rollback
  server is ever reintroduced into the fleet, which this fork explicitly does not support.

Rollback is the same list in reverse: restore the state directory and the previous binaries
on the server and on every client.

## What is not done

- The Windows **packaging/installer** script (`package-windows-client.ps1`) has never
  been run. A raw cross-build (`cargo build --release --features
  inline,hwcodec,vram`, no packaging) *was* verified in this environment on 2026-09-28,
  built and run inside the project's own Windows VM (`vm/scripts/vmctl.sh`) — it compiled
  clean and the resulting `rustdesk.exe` launched and rendered correctly. What remains
  unverified is only the packaging step itself (the installer `.exe`, its licence-name
  baking, and `install_me`'s folder-rename behaviour), not "no Windows host exists".
- The Windows build itself is not reproducible outside that one prepared VM:
  `build-run-windows-client.ps1` needs `tools\vcpkg-120deac` and `tools\llvm-15.0.6`,
  which are gitignored and undocumented. A packaging wrapper on a non-reproducible build
  gives a reproducible *wrapper*, not a reproducible artifact.
- No `.deb`/`PKGBUILD` for a Linux client. `res/rpm.spec` is the sound template if one is
  ever wanted; `res/PKGBUILD` is broken for the sciter build (it only installs a binary
  under `if [[ ${FLUTTER} ]]`, leaving `/usr/bin/rustdesk` a dangling symlink). Note
  `src/ui.rs` hardcodes `/usr/share/rustdesk/libsciter-gtk.so`, so that path must stay
  literally `rustdesk` whatever the package is called.
- Branding stays split on purpose: user-visible text is TBFDesk, `APP_NAME` remains
  `RustDesk` so the config dir, service name, registry keys and URI scheme do not move.
  See `RENAMING-PLAN.md`. Only cosmetic winres strings are safe to change.
