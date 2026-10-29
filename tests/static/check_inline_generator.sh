#!/usr/bin/env bash
# Regression: the Windows release embeds the UI via res/inline-sciter.py. Two 1.4.16 bugs
# lived there: (1) Python read the .tis in the platform code page (cp1252 on the Windows
# build host) -> mojibake; (2) every page packed all its scripts into ONE block -> Sciter's
# per-block limit -> dead "..." menu and no status polling.
# This runs the REAL generator with a non-UTF-8 platform default and checks its output;
# a negative control proves the check catches the old generator.
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

# A non-UTF-8 platform default, like cp1252 on Windows: C locale, no coercion, no UTF-8 mode.
NOUTF8=(env LC_ALL=C LANG=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0)

gen() {  # <generator.py> <outdir> -> runs it on a copy of the UI tree
  mkdir -p "$2/res" "$2/src/ui"
  cp "$1" "$2/res/inline-sciter.py"
  cp "$TBF_CLIENT"/src/ui/*.{tis,html,css} "$2/src/ui/" 2>/dev/null
  (cd "$2" && "${NOUTF8[@]}" python3 res/inline-sciter.py) >"$2/gen.log" 2>&1
}

# 1. current generator: must succeed and produce correct UTF-8 + one block per file
if gen "$TBF_CLIENT/res/inline-sciter.py" "$T/new"; then
  ok "generator runs with a non-UTF-8 platform default"
  python3 - "$T/new/src/ui/inline.rs" <<'PY' || fail=1
import re, sys, codecs
rs = open(sys.argv[1], encoding="ascii").read()     # the generated file itself is pure ASCII
def lit(name):
    m = re.search(r'const %s: &\[u8; \d+\] = b"(.*?)";\n' % name, rs, re.S)
    return codecs.escape_decode(m.group(1).encode("latin-1"))[0].decode("utf-8")
idx, rem = lit("_INDEX"), lit("_REMOTE")
ok = True
if "…" not in idx:
    print("    FAIL _INDEX lost the non-ASCII literal … (mojibake)"); ok = False
if "â€" in idx:
    print("    FAIL _INDEX contains cp1252 mojibake (â€...)"); ok = False
for name, page, want in (("_INDEX", idx, 3), ("_REMOTE", rem, 7)):
    # common.tis is substituted at runtime, so it is still an include here
    blocks = page.count('<script type="text/tiscript">')
    if blocks < want:
        print(f"    FAIL {name}: {blocks} script blocks, expected >= {want} (one per file)"); ok = False
print("    OK   generated pages: correct UTF-8, one script block per file" if ok else "")
sys.exit(0 if ok else 1)
PY
else
  bad "current generator FAILED under a non-UTF-8 default:"; sed 's/^/      /' "$T/new/gen.log" | tail -5; fail=1
fi

# 2. negative control: the 1.4.16 generator must FAIL here, or this check proves nothing
git -C "$TBF_CLIENT" show 2578fb861:res/inline-sciter.py > "$T/old-gen.py" 2>/dev/null
if [ -s "$T/old-gen.py" ]; then
  if gen "$T/old-gen.py" "$T/old"; then
    bad "negative control: the 1.4.16 generator did NOT fail -- this check can no longer detect the bug"; fail=1
  else
    ok "negative control: the 1.4.16 generator fails under the same conditions"
  fi
fi
exit $fail
