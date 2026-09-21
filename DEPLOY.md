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

Currently **1.4.7** (bumped from upstream's 1.4.6 as the fork's first shippable).

## 2. Windows workstations

```powershell
# on the Windows build host
.\scripts\package-windows-client.ps1
# or with the licence baked into the outer filename:
.\scripts\package-windows-client.ps1 -License "host=tbfdesk.example.com,key=<b64>"
```

Produces one double-clickable `.exe` plus its `.sha256`. On a workstation:

```
tbfdesk-1.4.7-x64-install.exe                  interactive
tbfdesk-1.4.7-x64-install.exe --silent-install  unattended (GPO / RMM)
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
useradd --system --home /var/lib/rustdesk-server --shell /usr/sbin/nologin rustdesk
install -d -o rustdesk -g rustdesk -m 0750 /var/lib/rustdesk-server /var/log/rustdesk-server
install -d -m 0750 /etc/tbfdesk
cat > /etc/tbfdesk/hbbs.env <<'EOF'
NEMO_API_TOKEN=<the admin token>
TBFDESK_RELAY=<server>:21117
TBFDESK_MASK=192.168.0.0/16
EOF
chmod 0600 /etc/tbfdesk/hbbs.env && chown root:rustdesk /etc/tbfdesk/hbbs.env
# the signing key, shared by hbbs and hbbr
install -o rustdesk -g rustdesk -m 0600 id_ed25519 /var/lib/rustdesk-server/
systemctl enable --now rustdesk-hbbs-nemo rustdesk-hbbr-nemo
```

The token goes in `EnvironmentFile`, never inline in `ExecStart` — argv is world-readable
through `/proc` (SEC-11).

### TLS for the management API — this is where Let's Encrypt belongs

Since SEC-12 the management API serves **HTTPS by default on any routable bind**, and
refuses plaintext there. With no certificate supplied it generates a self-signed one, which
works (the client caches the choice on first use) but means a browser warning on the admin
dashboard every time.

If the server has a DNS name reachable from the internet — which it will if you follow the
split-horizon DNS recommendation in `TOPOLOGY-DEPLOYMENT.md` — use Let's Encrypt and point
hbbs at the result:

```bash
certbot certonly --standalone -d tbfdesk.example.com
# then in /etc/tbfdesk/hbbs.env, or as extra ExecStart args:
#   --nemo-api-tls-cert /etc/letsencrypt/live/tbfdesk.example.com/fullchain.pem
#   --nemo-api-tls-key  /etc/letsencrypt/live/tbfdesk.example.com/privkey.pem
```

The hbbs user needs read access to those files (LE's `live/` is root-only by default), and
the renewal hook needs to restart hbbs — it reads the certificate once at boot.

`--mask` decides which peers count as "same intranet"; set it to cover every internal
network or cross-subnet pairs are forced to relay.

**hbbr needs the same signing key as hbbs.** Since the relay control-frame encryption
landed, hbbr offers a signed KeyExchange of its own and the client verifies it against
the server key it already trusts.

**hbbr treats any loopback connection as its command port**, so a relay address of
`127.0.0.1` can never pair. Always hand clients a routable address.

## 3b. Transport and performance defaults

Two defaults changed and neither is in the unit file — they are compiled in, so a
deployment inherits them without anyone passing a flag.

**`--udp-registration=N` (server) and `disable-udp=Y` (client).** UDP registration has no
key exchange and no device-key proof, so it bypassed both `--key-exchange` and
`require-device-key`. Off by default now, which means every client→server message is
encrypted. A client that is *not* on `disable-udp=Y` will retry forever and never come
online; the server logs a throttled warning naming it. This does **not** disable UDP hole
punching — that is `enable-udp-punch`, a separate switch on a separate path.

**Websocket rendezvous and relay (21118/21119) are refused.** They carried no key exchange
and no device auth. Do not forward those ports; there is nothing behind them.

### Tuning for CAD

The defaults are safe, not optimal. Per-site, push via managed policy:

| key | value | why |
|---|---|---|
| `image_quality` | `custom` | the preset ceilings are hard caps — ABR can only go *down* |
| `custom_image_quality` | `300` | ~12 Mbps at 1080p. Use `200` on a contended 1 GbE, `400` for 4K |
| `custom-fps` | `60` | now actually works — it used to be inert in this (Sciter) build |
| `codec-preference` | `h264` **or** `vp9` | per machine: `h264` where there is NVENC/QSV/VAAPI, `vp9` otherwise. Do **not** leave it on `auto` — on a GPU-less box `auto` lands on AV1, the most expensive software encoder |
| `i444` | `Y` | only on the `vp9` machines. It is a no-op on H.264/H.265. For CAD it is the difference between readable dimension text and smeared edges |
| `view_style` | `original` | already the desktop default; pin it so nobody resamples line-work client-side |

Leave **adaptive bitrate on**. It is a controlled-side global read once per connection, so
switching it off for the LAN operators also switches it off for the technician on the
internet hitting the same workstation — and with `MAX_BR_MULTIPLE = 1.0` it can never
exceed your target anyway.

While tuning, push `show_quality_monitor=Y` and read the per-session line from
`libs/scrap/src/common/codec.rs` (`used preference: … encoder: …`) to confirm what each
machine actually negotiated. Turn it off afterwards.

Encryption is not a lever here: the media path carries one XSalsa20-Poly1305 layer
end-to-end, the relay drops its key after the control frame, and the cipher costs under
0.2% of a core against 5–20 ms of encode per keyframe.

## 4. Provisioning a workstation

Installing is not the same as provisioning. After H5, a client also needs a **device key**
before hbbs will let it register at all (when `require_device_key` is on, which is the
default):

1. Admin dashboard → Device Keys → generate one, bound to that machine's id.
2. On the workstation: client → Import device key.

There is no CLI path for this on purpose (`--option nemo-device-key` is refused in both
directions, H26) and the licence name has no `devkey=` field. So an installer alone does
not yet equal unattended fleet provisioning — that gap is real and tracked.

Staged rollout: leave `require_device_key` off, install and provision, then turn it on.
The server names every un-provisioned client in its log while it is off.

---

## What is not done

- The Windows packaging script has **never been run** — there is no Windows host in this
  environment. Expect to iterate on it the first time.
- The Windows build itself is not reproducible: `build-run-windows-client.ps1` needs
  `tools\vcpkg-120deac` and `tools\llvm-15.0.6`, which are gitignored and undocumented. A
  packaging wrapper on a non-reproducible build gives a reproducible *wrapper*, not a
  reproducible artifact.
- No `.deb`/`PKGBUILD` for a Linux client. `res/rpm.spec` is the sound template if one is
  ever wanted; `res/PKGBUILD` is broken for the sciter build (it only installs a binary
  under `if [[ ${FLUTTER} ]]`, leaving `/usr/bin/rustdesk` a dangling symlink). Note
  `src/ui.rs` hardcodes `/usr/share/rustdesk/libsciter-gtk.so`, so that path must stay
  literally `rustdesk` whatever the package is called.
- Branding stays split on purpose: user-visible text is TBFDesk, `APP_NAME` remains
  `RustDesk` so the config dir, service name, registry keys and URI scheme do not move.
  See `RENAMING-PLAN.md`. Only cosmetic winres strings are safe to change.
