#!/usr/bin/env python3
"""#43 cross-repo contract: the client and the server must agree on the policy report.

The two halves live in different crates, so no single `cargo test` sees both. This reads
both source trees and checks:
  1. every refusal code the client can emit is one the server accepts
     (otherwise it is silently shown as "other");
  2. both sides sign / verify the same message domain ("nemo-policy-report");
  3. the report fields the client writes are the ones the server parses.
Exit 0 = contract holds.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
client = (ROOT / "rustdesk-client-nemo/src/nemo_management_client.rs").read_text()
client_common = (ROOT / "rustdesk-client-nemo/src/common.rs").read_text()
server = (ROOT / "rustdesk-server-nemo/src/nemo_management.rs").read_text()
fail = []

emitted = set(re.findall(r'note_policy_refused\(\s*"([a-z-]+)"', client))
emitted |= set(re.findall(r'^\s*"([a-z-]+)"\s*$', client.split("fn freshness_refusal_code")[1].split("\n}\n")[0], re.M))
m = re.search(r"const POLICY_REFUSAL_CODES: &\[&str\] = &\[(.*?)\];", server, re.S)
accepted = set(re.findall(r'"([a-z-]+)"', m.group(1))) if m else set()
emitted.discard("other")
missing = sorted(emitted - accepted)
if not accepted:
    fail.append("server: POLICY_REFUSAL_CODES not found")
if missing:
    fail.append(f"client emits refusal codes the server does not accept: {missing}")

for name, src in (("client", client_common), ("server", server)):
    if '"nemo-policy-report' not in src and "nemo-policy-report:" not in src:
        fail.append(f"{name}: signature domain 'nemo-policy-report' not found")

client_fields = set(re.findall(r'"(role|ref|applied_at|refused|overridden)"\s*:', client))
server_block = server.split("struct PolicyReport {")[1].split("\n}")[0]
server_fields = set(re.findall(r"^\s*(\w+):", server_block, re.M)) | {"ref"}  # applied_ref is renamed "ref"
for f in sorted(client_fields - server_fields - {"ref"}):
    fail.append(f"client writes report field '{f}' that the server does not parse")

print(f"refusal codes emitted by the client: {sorted(emitted)}")
print(f"accepted by the server:              {sorted(accepted)}")
print(f"report fields written by the client: {sorted(client_fields)}")
if fail:
    print("CONTRACT BROKEN:\n  - " + "\n  - ".join(fail))
    sys.exit(1)
print("contract OK")
