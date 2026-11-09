#!/usr/bin/env python3
"""Sciter -> Flutter parity inventory: every menu entry, input field, setting/option key and
Rust binding of the Sciter UI, with its Flutter counterpart.

Operator requirement (2026-11-06): every menu entry, every input field and every setting must
be present AND working in Flutter (desktop + Android). This script makes the list
mechanically from the source, so nothing is forgotten, and keeps it current: a Sciter
element with no Flutter line (automatic match or a line in overrides.csv) fails the run.

    inventory.py [--client <rustdesk-client-nemo>] [--out <dir>] [--check]

Writes <out>/FLUTTER-PARITY-ELEMENTS.md and <out>/flutter-parity-elements.csv
(default out = the superproject root). --check: exit 1 if any element is unaccounted for.

Automatic match (= PRESENT candidate, "works" still has to be verified):
  option key  -> the literal "key" in flutter/lib, or a Dart constant whose value is the key
  label       -> the same translate() string in flutter/lib
  binding     -> main_<name> / session_<name> / <name> in src/flutter_ffi.rs
overrides.csv (id,flutter,works_desktop,works_android,verified_by,note) supplies what the
script cannot know: the Flutter location for elements matched by hand, the "works" verdicts
from the lab, and operator decisions ("n/a: ...", "decision: ...").
"""
import argparse
import csv
import os
import re
import sys
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
SUPER = os.path.dirname(os.path.dirname(HERE))

AREA = {
    'index.tis': 'Main window / settings', 'index.html': 'Main window / settings',
    'ab.tis': 'Address book', 'remote.tis': 'Remote window', 'header.tis': 'Remote toolbar',
    'remote.html': 'Remote window', 'file_transfer.tis': 'File transfer',
    'port_forward.tis': 'Port forward', 'cm.tis': 'Connection manager', 'cm.html': 'Connection manager',
    'install.tis': 'Install', 'install.html': 'Install', 'update.html': 'Update prompt',
    'msgbox.tis': 'Dialogs', 'common.tis': 'Common', 'chatbox.html': 'Chat', 'grid.tis': 'Peer grid',
    'printer.tis': 'Printer', 'ui.rs': 'Main bindings', 'remote.rs': 'Session bindings',
}

TR = re.compile(r"""translate\(\s*(['"])((?:(?!\1).)+)\1""")
LI = re.compile(r"<li\b([^>]*)>")
BUTTON = re.compile(r"<button\b([^>]*)>")
INPUT = re.compile(r"<(input|select|textarea)\b([^>]*)>")
ID_ATTR = re.compile(r"""(?:#([A-Za-z0-9_-]+)|\bid=['"]?([A-Za-z0-9_-]+))""")
NAME_ATTR = re.compile(r"""\bname=['"]?([A-Za-z0-9_-]+)""")
CHECKBOX = re.compile(r"\|(checkbox|radio|switch)\(([A-Za-z0-9_-]+)\)")
TYPE_ATTR = re.compile(r"<input\|?([a-z-]+)")
OPTION_CALL = re.compile(
    r"""\b(?:get|set)_(?:local_|peer_|user_default_)?option2?\(\s*(['"])([A-Za-z0-9_.-]+)\1""")
OPTION_CONST = re.compile(r"""\bconst\s+OPTION_[A-Z0-9_]+\s*=\s*(['"])([A-Za-z0-9_.-]+)\1""")
DISPATCH_FN = re.compile(r"^\s*fn\s+([a-z0-9_]+)\s*\(")


def norm(s):
    return re.sub(r"\s+", " ", s.strip())


def sciter_elements(client):
    ui = os.path.join(client, 'src', 'ui')
    out = OrderedDict()

    def add(kind, key, file, line, label=''):
        eid = f"{kind}:{key}"
        e = out.setdefault(eid, {'id': eid, 'kind': kind, 'key': key, 'label': label,
                                 'area': AREA.get(file, file), 'sciter': []})
        loc = f"{file}:{line}"
        if loc not in e['sciter']:
            e['sciter'].append(loc)
        if label and not e['label']:
            e['label'] = label

    for fn in sorted(os.listdir(ui)):
        if not (fn.endswith('.tis') or fn.endswith('.html')):
            continue
        for n, line in enumerate(open(os.path.join(ui, fn), encoding='utf-8'), 1):
            labels = [m.group(2) for m in TR.finditer(line)]
            label = norm(labels[0]) if labels else ''
            for m in LI.finditer(line):
                ids = ID_ATTR.search(m.group(1))
                key = (ids.group(1) or ids.group(2)) if ids else None
                if key and '{' not in key:
                    add('menu', key, fn, n, label)
                elif label:
                    add('menu', 'label=' + label, fn, n, label)
            for m in BUTTON.finditer(line):
                attrs = m.group(1)
                cb = CHECKBOX.search('<button' + attrs)
                ids = ID_ATTR.search(attrs)
                if cb:
                    add('toggle', cb.group(2), fn, n, label)
                elif ids and (ids.group(1) or ids.group(2)):
                    add('button', ids.group(1) or ids.group(2), fn, n, label)
                elif label:
                    add('button', 'label=' + label, fn, n, label)
            for m in INPUT.finditer(line):
                attrs = m.group(2)
                nm = NAME_ATTR.search(attrs)
                ids = ID_ATTR.search(attrs)
                cb = CHECKBOX.search(attrs)
                key = cb.group(2) if cb else (nm.group(1) if nm else (
                    (ids.group(1) or ids.group(2)) if ids else None))
                if key:
                    add('input', key, fn, n, label)
            for m in OPTION_CALL.finditer(line):
                add('option', m.group(2), fn, n, label)
            for m in OPTION_CONST.finditer(line):
                add('option', m.group(2), fn, n, label)

    # Rust bindings the Sciter UI calls (main window + session window).
    for rel, kind in (('src/ui.rs', 'binding'), ('src/ui/remote.rs', 'session-binding')):
        path = os.path.join(client, rel)
        inside = False
        for n, line in enumerate(open(path, encoding='utf-8'), 1):
            if 'dispatch_script_call!' in line:
                inside = True
                continue
            if inside:
                if line.strip().startswith('}'):
                    inside = False
                    continue
                m = DISPATCH_FN.match(line)
                if m:
                    add(kind, m.group(1), os.path.basename(rel), n)
    return out


CALL = re.compile(r"\b([a-z_][a-z0-9_]*)\s*(?:::<[^>]*>)?\(")
GENERIC = set('''if while for match return fn some ok err into to_owned to_string clone map
unwrap unwrap_or unwrap_or_default unwrap_or_else and_then iter collect len is_empty push
format from new get set as_str as_ref lock read write vec value with contains starts_with
ends_with parse trim split join insert remove push_str eq ne default borrow borrow_mut
call call_method spawn sleep make_args println log info error warn debug allow_err
from_iter drain json encode64 decode64 serde_json to_lowercase replace chars any all
sync_return syncreturn into_iter filter find max min'''.split())


def fn_bodies(path, pattern):
    """name -> set of called function names, for every fn matching `pattern` in `path`."""
    src = open(path, encoding='utf-8').read()
    out = {}
    for m in re.finditer(pattern, src, re.M):
        name, start = m.group(1), src.find('{', m.end())
        if start < 0:
            continue
        depth, i = 0, start
        while i < len(src):
            if src[i] == '{':
                depth += 1
            elif src[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        calls = {c for c in CALL.findall(src[start:i]) if c not in GENERIC and c != name}
        out.setdefault(name, set()).update(calls)
    return out


def binding_matches(client):
    """Sciter binding -> Flutter FFI fn(s), paired by the Rust function both wrap."""
    sci = fn_bodies(os.path.join(client, 'src', 'ui.rs'), r"^\s{4}fn ([a-z0-9_]+)\s*\(")
    sci.update({('session:' + k): v for k, v in fn_bodies(
        os.path.join(client, 'src', 'ui', 'remote.rs'), r"^\s{4}fn ([a-z0-9_]+)\s*\(").items()})
    ffi = fn_bodies(os.path.join(client, 'src', 'flutter_ffi.rs'), r"^pub fn ([a-z0-9_]+)\s*\(")
    res = {}
    for sname, scalls in sci.items():
        bare = sname.split(':', 1)[-1]
        best, score = [], 0
        for fname, fcalls in ffi.items():
            s = len(scalls & (fcalls | {fname}))
            # the Sciter binding often calls the very function the FFI is named after
            if bare in fcalls or fname.endswith('_' + bare):
                s += 2
            if s > score:
                best, score = [fname], s
            elif s == score and s > 0:
                best.append(fname)
        if score > 0 and len(best) <= 3:
            res[sname] = best
    return res


def flutter_index(client):
    lib = os.path.join(client, 'flutter', 'lib')
    literals = {}     # string literal -> [file:line]
    consts = {}       # Dart const name -> value
    files = []
    for root, _, names in os.walk(lib):
        if 'generated' in root:
            continue
        for fn in names:
            if fn.endswith('.dart') and fn != 'generated_bridge.dart':
                files.append(os.path.join(root, fn))
    lit = re.compile(r"""(['"])((?:(?!\1)[^\\]|\\.)*)\1""")
    cdef = re.compile(r"""const\s+(?:String\s+)?([A-Za-z0-9_]+)\s*=\s*(['"])([^'"]+)\2""")
    for path in sorted(files):
        rel = os.path.relpath(path, os.path.join(client, 'flutter'))
        for n, line in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
            for m in cdef.finditer(line):
                consts[m.group(1)] = m.group(3)
            for m in lit.finditer(line):
                literals.setdefault(m.group(2), []).append(f"{rel}:{n}")
    # constant uses: kOptionX referenced -> counts as the literal value present
    uses = {}
    for path in sorted(files):
        rel = os.path.relpath(path, os.path.join(client, 'flutter'))
        text = open(path, encoding='utf-8', errors='replace').read()
        for name, value in consts.items():
            if re.search(r"\b" + re.escape(name) + r"\b", text):
                uses.setdefault(value, []).append(rel)
    ffi = set()
    for line in open(os.path.join(client, 'src', 'flutter_ffi.rs'), encoding='utf-8'):
        m = re.match(r"\s*pub fn ([a-z0-9_]+)\s*\(", line)
        if m:
            ffi.add(m.group(1))
    return literals, uses, ffi


def match(e, literals, uses, ffi, bmatch):
    k, key = e['kind'], e['key']
    if k in ('binding', 'session-binding'):
        for cand in ((f"main_{key}", f"{key}") if k == 'binding' else (f"session_{key}", key)):
            if cand in ffi:
                return f"flutter_ffi.rs: {cand}"
        via = bmatch.get(key if k == 'binding' else 'session:' + key)
        if via:
            return 'flutter_ffi.rs (same Rust call): ' + ', '.join(via)
        return ''
    if not key.startswith('label='):
        if key in literals:
            return '; '.join(literals[key][:3])
        if key in uses:
            return 'const: ' + '; '.join(sorted(set(uses[key]))[:3])
    if e['label'] and e['label'] in literals:
        return 'label: ' + '; '.join(literals[e['label']][:3])
    return ''


def load_overrides(path):
    ov = {}
    if os.path.exists(path):
        with open(path, newline='', encoding='utf-8') as f:
            for row in csv.DictReader(f):
                if row.get('id'):
                    ov[row['id']] = row
    return ov


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--client', default=os.path.join(SUPER, 'rustdesk-client-nemo'))
    ap.add_argument('--out', default=SUPER)
    ap.add_argument('--overrides', default=os.path.join(HERE, 'overrides.csv'))
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()

    els = sciter_elements(a.client)
    literals, uses, ffi = flutter_index(a.client)
    bmatch = binding_matches(a.client)
    ov = load_overrides(a.overrides)
    rows, missing = [], []
    for e in els.values():
        auto = match(e, literals, uses, ffi, bmatch)
        o = ov.get(e['id'], {})
        flutter = o.get('flutter') or auto
        row = {
            'id': e['id'], 'area': e['area'], 'kind': e['kind'], 'label': e['label'],
            'sciter': '; '.join(e['sciter'][:3]), 'flutter': flutter,
            'matched': 'override' if o.get('flutter') else ('auto' if auto else ''),
            'works_desktop': o.get('works_desktop', ''), 'works_android': o.get('works_android', ''),
            'verified_by': o.get('verified_by', ''), 'note': o.get('note', ''),
        }
        rows.append(row)
        # an override can also RECORD a gap ("MISSING ..."): still missing, with the reason
        if not flutter or flutter.strip().upper().startswith('MISSING'):
            missing.append(row)

    csv_path = os.path.join(a.out, 'flutter-parity-elements.csv')
    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    def count(pred):
        return sum(1 for r in rows if pred(r))
    md = [
        '# Flutter parity: every Sciter element\n',
        'Generated by `tests/parity/inventory.py` from the client source -- do not edit by hand;',
        'put Flutter locations, lab verdicts and decisions in `tests/parity/overrides.csv`.\n',
        f"Elements: **{len(rows)}** | Flutter counterpart found: **{len(rows) - len(missing)}** "
        f"(auto {count(lambda r: r['matched'] == 'auto')}, by hand {count(lambda r: r['matched'] == 'override')}) "
        f"| **missing: {len(missing)}** | works verified desktop: "
        f"{count(lambda r: r['works_desktop'].lower().startswith(('yes', 'n/a')))} "
        f"| Android: {count(lambda r: r['works_android'].lower().startswith(('yes', 'n/a')))}\n",
        '"Found" means the counterpart exists in the Flutter source; "works" columns are set only',
        'after the lab proved the effect (option written + read back, behaviour seen).\n',
    ]
    for area in sorted({r['area'] for r in rows}):
        md.append(f"\n## {area}\n")
        md.append('| Element | Label | Sciter | Flutter | Works desktop | Works Android | Verified by / note |')
        md.append('|---|---|---|---|---|---|---|')
        for r in rows:
            if r['area'] != area:
                continue
            fl = r['flutter'] or '**MISSING**'
            note = ' '.join(x for x in (r['verified_by'], r['note']) if x)
            md.append(f"| `{r['id']}` | {r['label']} | {r['sciter']} | {fl} | {r['works_desktop']} "
                      f"| {r['works_android']} | {note} |")
    with open(os.path.join(a.out, 'FLUTTER-PARITY-ELEMENTS.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(md) + '\n')
    print(f"{len(rows)} elements, {len(missing)} without a Flutter counterpart -> {csv_path}")
    if a.check and missing:
        for r in missing[:40]:
            print(f"  MISSING {r['id']} ({r['area']}, {r['sciter']}) {r['label']}")
        sys.exit(1)


if __name__ == '__main__':
    main()
