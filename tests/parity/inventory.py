#!/usr/bin/env python3
"""Sciter <-> Flutter parity inventory, both directions, from the client source.

Operator requirement (2026-11-06): every menu entry, every input field and every setting must
be present AND working in Flutter (desktop + Android) -- and (2026-11-17, PARITY-GAPS P5) the
reverse: what Flutter has must be in Sciter too, with the same gating.

    inventory.py [--client <rustdesk-client-nemo>] [--out <dir>] [--check] [--strict]

Three passes:
  Sciter -> Flutter  every menu entry, input, toggle, option key and Rust binding of the Sciter
                     UI, with its Flutter counterpart          -> FLUTTER-PARITY-ELEMENTS.md / .csv
  Flutter -> Sciter  every option key Flutter reads or writes, and every settings row / menu
                     entry it builds (_OptionCheckBox, _Radio, _Card, _Button, TToggleMenu,
                     SettingsTile ...), with its Sciter counterpart -> FLUTTER-TO-SCITER-PARITY.md / .csv
  behaviour notes    for keys both UIs use: one UI greys the row when the administrator fixed
                     the option (is_option_fixed) and the other lets it be changed; the two UIs
                     store the key in different places (main / local / user-default / peer /
                     session toggle), or one UI also writes it to a store the other never
                     touches; an empty value means "on" in one UI and "off" in the other
                     -> parity-behaviour-notes.csv (+ a section in FLUTTER-TO-SCITER-PARITY.md)
(default out = the superproject root; the test stage writes to its artifact dir instead).

Automatic match (= PRESENT candidate, "works" still has to be verified):
  S->F option key  -> the literal "key" in flutter/lib, or a Dart constant whose value is the
                      key and that is USED somewhere other than its own definition line
  S->F label       -> the same translate() string in flutter/lib
  S->F binding     -> main_<name> / session_<name> / <name> in src/flutter_ffi.rs
  F->S option key  -> read/written by the Sciter UI (handler.*option* call, a helper such as
                      pEnable, a toggleMenuState loop over a menu's <li> ids, a get_options()
                      map), or an element #id in src/ui/*.tis|html. A bare string literal, the
                      same label on another key, or a hit only in src/ui.rs / src/ui/remote.rs
                      ("Rust only" -- no Sciter control) is a hint, not a match.
                      Settings rows / menu entries that carry an option key match on the key.
  F->S label       -> the same translate() string in src/ui/*.tis|html (case/punctuation folded)

Verdicts the script cannot know come from two CSV files (same mechanism, one per direction):
  overrides.csv      id,flutter,works_desktop,works_android,verified_by,note     (S->F ids)
  overrides-f2s.csv  id,sciter,verified_by,note                                  (F->S ids,
                     and behaviour-note ids "behaviour:<check>:<key>")
The counterpart column holds: a location (matched by hand) | "n/a: <reason>" | "decision: ..."
| "MISSING: P<n> ..." -- a gap logged in PARITY-GAPS.md. A MISSING row whose P<n> is in the
Open table there is KNOWN (printed every run; fails only with --strict or TBF_STRICT=1); a
MISSING row without an open P-number still fails. For behaviour notes: "ok: <reason>" (the
difference is intended / not real) or "MISSING: P<n>".

--check exits 1 if any element is unaccounted for (either direction), or if a behaviour note
has no valid verdict (none, or a MISSING: P<n> that is not open), 0 otherwise.
F->S elements found only under flutter/lib/mobile/ (Android-only) and F->S MENU entries
without an option key (matched on their label only) are listed but never fail the check
(report-only): Sciter has no Android build, and menu wording differs too often for a label to
prove absence. Settings rows without an option key (_Button, _Radio ...) do gate.
Exit 2 = the client source is missing (the test stage reports SKIP), 64 = usage error.
"""
import argparse
import bisect
import csv
import os
import re
import subprocess
import sys
from collections import Counter, OrderedDict

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


class UsageError(SystemExit):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):   # argparse would exit 2, which the test stage reads as SKIP
        self.print_usage(sys.stderr)
        print(f"{self.prog}: error: {message}", file=sys.stderr)
        raise UsageError(64)


def norm(s):
    return re.sub(r"\s+", " ", s.strip())


# =============================================================================================
# Sciter -> Flutter (unchanged logic since 2026-11-09, except the constant-use index below)
# =============================================================================================

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


def dart_files(client):
    lib = os.path.join(client, 'flutter', 'lib')
    files = []
    for root, _, names in os.walk(lib):
        if 'generated' in root:
            continue
        for fn in names:
            if fn.endswith('.dart') and fn != 'generated_bridge.dart':
                files.append(os.path.join(root, fn))
    return sorted(files)


def flutter_index(client):
    literals = {}     # string literal -> [file:line]
    consts = {}       # Dart const name -> value
    files = dart_files(client)
    lit = re.compile(r"""(['"])((?:(?!\1)[^\\]|\\.)*)\1""")
    cdef = re.compile(r"""const\s+(?:String\s+)?([A-Za-z0-9_]+)\s*=\s*(['"])([^'"]+)\2""")
    for path in files:
        rel = os.path.relpath(path, os.path.join(client, 'flutter'))
        for n, line in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
            defined = set()
            for m in cdef.finditer(line):
                consts[m.group(1)] = m.group(3)
                defined.add(m.group(3))
            for m in lit.finditer(line):
                # `const kOptionX = 'x';` is not an occurrence of 'x': it counts only through
                # a use of kOptionX (below). A const nobody reads is not a Flutter counterpart.
                if m.group(2) in defined:
                    continue
                literals.setdefault(m.group(2), []).append(f"{rel}:{n}")
    # constant uses: kOptionX referenced (not on its own definition) -> the value is present
    uses = {}
    for path in files:
        rel = os.path.relpath(path, os.path.join(client, 'flutter'))
        text = open(path, encoding='utf-8', errors='replace').read()
        tokens = Counter(re.findall(r"[A-Za-z0-9_]+", text))
        defined = Counter(m.group(1) for m in cdef.finditer(text))
        for name, value in consts.items():
            if tokens[name] > defined[name]:
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


# =============================================================================================
# Source scanner shared by the Flutter -> Sciter pass and the behaviour notes: comments
# blanked, string bodies masked (offsets kept), so brackets and commas can be counted.
# =============================================================================================

IDENT = r"[A-Za-z_$][A-Za-z0-9_$]*"
OPEN, CLOSE = '([{', ')]}'


class Src:
    def __init__(self, path, rel, dart):
        self.path, self.rel, self.dart = path, rel, dart
        self.text = open(path, encoding='utf-8', errors='replace').read()
        self.masked, self.strings = scan(self.text, dart)
        self.str_at = {s[0]: s for s in self.strings}
        self.nl = [i for i, c in enumerate(self.text) if c == '\n']
        self._defs = None
        self._calls = None
        self._functions = None

    def line(self, off):
        return bisect.bisect_left(self.nl, off) + 1

    def loc(self, off):
        return f"{self.rel}:{self.line(off)}"


def scan(text, dart):
    """-> (masked text, [(start, end, value)]). value is None for an interpolated Dart
    string. A '...' string may not span a line (TIScript markup text can hold a stray
    apostrophe); a backslash-newline continues it (TIScript)."""
    out = list(text)
    strings = []
    n = len(text)

    def read_string(i):
        raw = False
        if dart and text[i] == 'r':
            raw, i = True, i + 1
        q = text[i]
        triple = dart and text.startswith(q * 3, i)
        delim = q * 3 if triple else q
        i += len(delim)
        buf, interp = [], False
        while i < n:
            c = text[i]
            if text.startswith(delim, i):
                return i + len(delim), (None if interp else ''.join(buf))
            if c == '\n' and not triple:
                return None, None
            if c == '\\' and not raw:
                if i + 1 < n and text[i + 1] == '\n':
                    i += 2
                    continue
                buf.append(text[i + 1] if i + 1 < n else '')
                i += 2
                continue
            if dart and not raw and c == '$':
                interp = True
                if i + 1 < n and text[i + 1] == '{':
                    depth, i = 1, i + 2
                    while i < n and depth:
                        if text[i] in '\'"':
                            e, _ = read_string(i)
                            i = e if e else i + 1
                            continue
                        if text[i] == '{':
                            depth += 1
                        elif text[i] == '}':
                            depth -= 1
                        i += 1
                    continue
            buf.append(c)
            i += 1
        return None, None

    i = 0
    while i < n:
        c = text[i]
        if text.startswith('//', i) and not (i and text[i - 1] == ':'):   # not http://
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        elif c in '\'"' or (dart and c == 'r' and i + 1 < n and text[i + 1] in '\'"'
                             and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == '_'))):
            end, val = read_string(i)
            if end is None:
                i += 1
                continue
            q0 = i + (1 if text[i] == 'r' else 0)
            ql = 3 if (dart and text.startswith(text[q0] * 3, q0)) else 1
            for k in range(q0 + ql, end - ql):
                if out[k] != '\n':
                    out[k] = 'x'
            strings.append((i, end, val))
            i = end
        else:
            i += 1
    return ''.join(out), strings


def match_close(m, i):
    depth = 0
    for k in range(i, len(m)):
        ch = m[k]
        if ch in OPEN:
            depth += 1
        elif ch in CLOSE:
            depth -= 1
            if depth == 0:
                return k
    return len(m) - 1


def split_args(src, lp):
    """lp = offset of '(' -> ([(name-or-None, start, end)], offset of ')')."""
    m = src.masked
    rp = match_close(m, lp)
    spans, depth, a = [], 0, lp + 1
    for k in range(lp + 1, rp + 1):
        ch = m[k]
        if k == rp:
            if m[a:k].strip():
                spans.append((a, k))
            break
        if ch in OPEN:
            depth += 1
        elif ch in CLOSE:
            depth -= 1
        elif ch == ',' and depth == 0:
            spans.append((a, k))
            a = k + 1
    res = []
    for s, e in spans:
        nm = re.match(r"\s*(" + IDENT + r")\s*:(?!:)", m[s:e]) if src.dart else None
        res.append((nm.group(1), s + nm.end(), e) if nm else (None, s, e))
    return res, rp


def pick(args, spec):
    """spec: int = n-th positional argument, str = named argument."""
    if isinstance(spec, int):
        pos = [a for a in args if a[0] is None]
        return pos[spec] if spec < len(pos) else None
    for a in args:
        if a[0] == spec:
            return a
    return None


def trim(src, s, e):
    t = src.masked
    while s < e and t[s].isspace():
        s += 1
    while e > s and t[e - 1].isspace():
        e -= 1
    return s, e


def literal(src, s, e):
    s, e = trim(src, s, e)
    lit = src.str_at.get(s)
    return lit[2] if lit and lit[1] == e else None


DEF_RE = re.compile(r"\b(?:final|var|const|late|static|String\??)\s+(?:(?:final|const|static|String\??)\s+)*("
                    + IDENT + r")\s*=\s*(?=r?['\"])")


def local_defs(src):
    if src._defs is None:
        d = []
        for m in DEF_RE.finditer(src.masked):
            lit = src.str_at.get(m.end())
            if lit and lit[2] is not None:
                d.append((m.start(), m.group(1), lit[2]))
        src._defs = d
    return src._defs


def resolve(src, s, e, consts):
    """A key argument -> its string value: a literal, or an identifier bound to one (the
    nearest preceding definition in the file, then any in the file, then a global constant)."""
    v = literal(src, s, e)
    if v is not None:
        return v
    s, e = trim(src, s, e)
    m = re.fullmatch(r"(?:this\.|widget\.|self\.)?(" + IDENT + r")", src.masked[s:e])
    if not m:
        return None
    name, best = m.group(1), None
    for off, nm, val in local_defs(src):
        if nm == name and off < s:
            best = val
    if best is None:
        best = next((val for off, nm, val in local_defs(src) if nm == name), None)
    return best if best is not None else consts.get(name)


KEYWORDS = set('if for while switch catch on return await assert super this new else do try '
               'function event'.split())
CALL_RE = re.compile(r"(?<![\w$.])((?:this\.|self\.)?" + IDENT + r"(?:\." + IDENT + r")*)"
                     r"\s*(?:<[^()<>;]*(?:<[^()<>;]*>[^()<>;]*)*>)?\s*\(")


def calls(src):
    """[(name without this./self., start, '(' offset)] for every call-shaped token."""
    if src._calls is None:
        src._calls = [(re.sub(r"^(?:this|self)\.", '', c.group(1)), c.start(), c.end() - 1)
                      for c in CALL_RE.finditer(src.masked)]
    return src._calls


def definitions(src):
    """Function definitions -> (name, [(param, positional index or None)], body start, end)."""
    if src._functions is None:
        src._functions = _definitions(src)
    return src._functions


def _definitions(src):
    m = src.masked
    out = []
    for name, start, lp in calls(src):
        short = name.split('.')[-1]
        if short in KEYWORDS or '.' in name:
            continue
        rp = match_close(m, lp)
        r = re.match(r"\s*(?:async\*?|sync\*)?\s*(\{|=>)", m[rp + 1:rp + 41])
        if not r:
            continue
        inner = m[lp + 1:rp]
        pieces, depth, a = [], 0, 0
        for j, ch in enumerate(inner):
            if ch in OPEN:
                depth += 1
            elif ch in CLOSE:
                depth -= 1
            elif ch == ',' and depth == 0:
                pieces.append(inner[a:j])
                a = j + 1
        pieces.append(inner[a:])
        params, pos = [], 0
        for p in pieces:
            p = p.strip()
            if not p:
                continue
            if p[0] in '{[':
                named = p[0] == '{'
                body = p[1:].rstrip()
                if body and body[-1] in '}]':
                    body = body[:-1]
                sub, d2, a2 = [], 0, 0
                for j, ch in enumerate(body):
                    if ch in OPEN:
                        d2 += 1
                    elif ch in CLOSE:
                        d2 -= 1
                    elif ch == ',' and d2 == 0:
                        sub.append(body[a2:j])
                        a2 = j + 1
                sub.append(body[a2:])
                for q in sub:
                    q = re.split(r"\s*[=:]", q.strip(), maxsplit=1)[0]
                    nm = re.findall(IDENT, q)
                    if nm:
                        params.append((nm[-1], None if named else pos))
                        pos += 0 if named else 1
                continue
            q = re.split(r"\s*=", p, maxsplit=1)[0]
            nm = re.findall(IDENT, q)
            if nm:
                params.append((nm[-1], pos))
                pos += 1
        bs = rp + 1 + r.start(1)
        if r.group(1) == '{':
            be = match_close(m, bs)
        else:
            depth, be = 0, len(m) - 1
            for j in range(bs + 2, len(m)):
                ch = m[j]
                if ch in OPEN:
                    depth += 1
                elif ch in CLOSE:
                    if depth == 0:
                        be = j
                        break
                    depth -= 1
                elif ch in ';,' and depth == 0:
                    be = j
                    break
        out.append((short, params, bs, be))
    return out


# =============================================================================================
# Option accesses (both UIs): which key, which store, read / write / fixed-check, where.
# =============================================================================================

# name -> [(key argument, store, op)]. Store: main = Config options (RustDesk2.toml), local =
# LocalConfig, user-default = UserDefaultConfig, peer = PeerConfig.options of one peer,
# toggle = a session toggle (PeerConfig), buildin = build-time, flutter-ui = Flutter window /
# layout state. 'FILE' = depends on the Sciter window (main handler vs session handler).
DART_SINKS = {
    'bind.mainGetOption': [('key', 'main', 'get')], 'bind.mainGetOptionSync': [('key', 'main', 'get')],
    'bind.mainSetOption': [('key', 'main', 'set')],
    'bind.mainGetLocalOption': [('key', 'local', 'get')], 'bind.mainSetLocalOption': [('key', 'local', 'set')],
    'bind.mainGetUserDefaultOption': [('key', 'user-default', 'get')],
    'bind.mainSetUserDefaultOption': [('key', 'user-default', 'set')],
    'bind.mainGetPeerOption': [('key', 'peer', 'get')], 'bind.mainGetPeerOptionSync': [('key', 'peer', 'get')],
    'bind.mainSetPeerOption': [('key', 'peer', 'set')], 'bind.mainSetPeerOptionSync': [('key', 'peer', 'set')],
    'bind.sessionGetOption': [('arg', 'peer', 'get')], 'bind.sessionPeerOption': [('name', 'peer', 'set')],
    'bind.sessionGetPeerOption': [('name', 'peer', 'get')],
    'bind.sessionGetToggleOption': [('arg', 'toggle', 'get')],
    'bind.sessionGetToggleOptionSync': [('arg', 'toggle', 'get')],
    'bind.sessionToggleOption': [('value', 'toggle', 'set')],
    'bind.sessionGetFlutterOption': [('k', 'flutter-ui', 'get')],
    'bind.sessionSetFlutterOption': [('k', 'flutter-ui', 'set')],
    'bind.mainGetPeerFlutterOptionSync': [('k', 'flutter-ui', 'get')],
    'bind.mainSetPeerFlutterOptionSync': [('k', 'flutter-ui', 'set')],
    'bind.mainGetBuildinOption': [('key', 'buildin', 'get')], 'bind.mainGetHardOption': [('key', 'buildin', 'get')],
    'bind.mainIsOptionFixed': [('key', None, 'fixed')],
}
SCITER_SINKS = {
    'handler.get_option': [(0, 'FILE', 'get')], 'handler.set_option': [(0, 'FILE', 'set')],
    'handler.get_local_option': [(0, 'local', 'get')], 'handler.set_local_option': [(0, 'local', 'set')],
    'handler.get_peer_option': [(1, 'peer', 'get')], 'handler.set_peer_option': [(1, 'peer', 'set')],
    'handler.get_toggle_option': [(0, 'toggle', 'get')], 'handler.toggle_option': [(0, 'toggle', 'set')],
    'handler.get_builtin_option': [(0, 'buildin', 'get')],
    'handler.is_option_fixed': [(0, None, 'fixed')],
}
# Sciter windows: which handler `handler.get_option` talks to (ui.rs main vs ui/remote.rs session)
SCITER_SESSION_FILES = {'remote.tis', 'header.tis', 'file_transfer.tis', 'port_forward.tis', 'grid.tis',
                        'printer.tis', 'remote.html', 'chatbox.html'}
SCITER_MAIN_FILES = {'index.tis', 'ab.tis', 'install.tis', 'index.html', 'install.html', 'update.html'}


def polarity_after(src, rp):
    """`get(...) == "Y"` -> 'empty=off'; `!= "N"` -> 'empty=on'; else None."""
    m = re.match(r"\s*(==|!=)\s*(?=['\"])", src.masked[rp + 1:rp + 12])
    if not m:
        return None
    lit = src.str_at.get(rp + 1 + m.end())
    if not lit:
        return None
    op, v = m.group(1), lit[2]
    if (op, v) == ('==', 'Y') or (op, v) == ('!=', 'Y'):
        return 'empty=off'
    if (op, v) == ('!=', 'N') or (op, v) == ('==', 'N'):
        return 'empty=on'
    return None


def option2bool_polarity(key):
    """hbb_common config.rs option2bool / Flutter common.dart option2bool."""
    if key.startswith('enable-'):
        return 'empty=on'
    if key.startswith('allow-') or key in ('stop-service', 'direct-server', 'force-always-relay'):
        return 'empty=off'
    return 'empty=on'


class Access:
    __slots__ = ('ui', 'key', 'store', 'op', 'src', 'off', 'via', 'polarity', 'func', 'shared')

    def __init__(self, ui, key, store, op, src, off, via, polarity=None):
        self.ui, self.key, self.store, self.op = ui, key, store, op
        self.src, self.off, self.via, self.polarity = src, off, via, polarity
        self.func = None      # (name, body start) of the innermost enclosing function
        self.shared = True    # False: only an Android page reaches it

    @property
    def loc(self):
        return self.src.loc(self.off)


def annotate(accesses, srcs):
    """Enclosing function of every access; an access in lib/mobile/ counts as shared when its
    function is also called from outside lib/mobile/ (e.g. nemoManagementServerSettingsLocked,
    defined in mobile/widgets/dialog.dart, used by the desktop settings page)."""
    defs = {id(s): definitions(s) for s in srcs}
    called_outside, defined_outside = set(), set()
    for s in srcs:
        if not s.rel.startswith('lib/mobile/'):
            for name, _, _ in calls(s):
                called_outside.add(name.split('.')[-1])
            defined_outside.update(d[0] for d in defs[id(s)])
    # a name also defined outside lib/mobile/ (build, initState, onChanged ...) proves nothing
    called_outside -= defined_outside
    for a in accesses:
        best = None
        for name, params, bs, be in defs.get(id(a.src), []):
            if bs <= a.off <= be and (best is None or bs > best[1]):
                best = (name, bs, be)
        a.func = best
        if a.src.rel.startswith('lib/mobile/'):
            a.shared = bool(best) and best[0] in called_outside


def find_helpers(srcs, base, ui):
    """Functions that hand one of their parameters to an option sink (isOptionFixed,
    mainGetBoolOptionSync, _OptionCheckBox, pEnable ...), found to a fixpoint.
    -> name -> [(param spec, store, op, polarity, has_isServer)]."""
    sinks = {k: [(a, s, o, None, False) for a, s, o in v] for k, v in base.items()}
    helpers = {}
    defs = [(src, d) for src in srcs for d in definitions(src)]
    allcalls = {id(src): calls(src) for src in srcs}
    for _ in range(5):
        changed = False
        for src, (name, params, bs, be) in defs:
            if name in base:
                continue
            pnames = {p for p, _ in params}
            has_is_server = 'isServer' in pnames
            # option2bool(key, bind.mainGetOption(key: key)): the helper's read follows
            # option2bool's rule for the empty value
            o2b = bool(re.search(r"\boption2bool\s*\(", src.masked[bs:be]))
            for cname, cstart, lp in allcalls[id(src)]:
                if not (bs < cstart < be) or cname not in sinks:
                    continue
                args, rp = split_args(src, lp)
                for spec, store, op, pol, _hs in sinks[cname]:
                    a = pick(args, spec)
                    if not a:
                        continue
                    s, e = trim(src, a[1], a[2])
                    arg = src.masked[s:e]
                    if arg not in pnames:
                        continue
                    pspec = next(i if i is not None else p for p, i in params if p == arg)
                    if pol is None and op == 'get':
                        pol = polarity_after(src, rp) or ('option2bool' if o2b else None)
                    ent = (pspec, store, op, pol, has_is_server)
                    if ent not in helpers.setdefault(name, []):
                        helpers[name].append(ent)
                        changed = True
        sinks.update(helpers)
        if not changed:
            break
    return helpers


def menu_ids(srcs):
    """Sciter <menu #x> ... </menu> -> x -> [li ids] (nested menus included)."""
    out = {}
    for src in srcs:
        m = src.masked
        for t in re.finditer(r"<menu\b([^>]*)>", m):
            mid = re.search(r"#([A-Za-z][\w-]*)|\bid=['\"]?([\w-]+)", t.group(1))
            if not mid:
                continue
            depth, k = 1, t.end()
            for x in re.finditer(r"<(/?)menu\b", m[t.end():]):
                depth += -1 if x.group(1) else 1
                if depth == 0:
                    k = t.end() + x.start()
                    break
            ids = [y.group(1) for y in re.finditer(r"<li\b[^>]*?#([A-Za-z][\w-]*)", m[t.end():k])]
            out.setdefault(mid.group(1) or mid.group(2), []).extend(ids)
    return out


def list_items(src, lb, consts):
    """[a, kB, 'c'] at offset lb -> resolved string items."""
    args, _ = split_args_br(src, lb)
    return [v for v in (resolve(src, s, e, consts) for s, e in args) if v]


def split_args_br(src, lb):
    m = src.masked
    rb = match_close(m, lb)
    spans, depth, a = [], 0, lb + 1
    for k in range(lb + 1, rb + 1):
        ch = m[k]
        if k == rb:
            if m[a:k].strip():
                spans.append((a, k))
            break
        if ch in OPEN:
            depth += 1
        elif ch in CLOSE:
            depth -= 1
        elif ch == ',' and depth == 0:
            spans.append((a, k))
            a = k + 1
    return spans, rb


LIST_DEF = re.compile(r"\b(?:const|final|var|static)\s+(?:(?:const|final|static)\s+)*(?:List<String>\s+)?("
                      + IDENT + r")\s*=\s*(?:const\s*)?(?:<String>\s*)?\[")


def const_lists(srcs, consts):
    """Dart `const List<String> _kX = [kA, 'b'];` / TIScript `var x = ["a", "b"];` -> name -> items."""
    out = {}
    for src in srcs:
        for d in LIST_DEF.finditer(src.masked):
            items = list_items(src, d.end() - 1, consts)
            if items:
                out.setdefault(d.group(1), items)
    return out


def scopes_for(src, menus, lists, consts):
    """Loops and handlers that bind a variable to many keys at once -> [(var, [keys], body s, e)]:
    Sciter  for (var el in $$(menu#x>li)) / for (var id in ["a", "b"]) / event click $(menu#x li) (_, me)
    Dart    for (final k in kList) / kList.any((k) => isOptionFixed(k)) / .where / .forEach / .map"""
    m, out = src.masked, []

    def body_after(rp):
        r = re.match(r"\s*(\{|=>)", m[rp + 1:])
        if r and r.group(1) == '{':
            bs = rp + 1 + r.end() - 1
            return bs, match_close(m, bs)
        if r:
            bs = rp + 1 + r.end()
            depth = 0
            for j in range(bs, len(m)):
                if m[j] in OPEN:
                    depth += 1
                elif m[j] in CLOSE:
                    if depth == 0:
                        return bs, j
                    depth -= 1
                elif m[j] in ';,' and depth == 0:
                    return bs, j
            return bs, len(m) - 1
        e = m.find(';', rp + 1)
        return rp + 1, (e if e > 0 else len(m) - 1)

    def keys_of(expr_s, expr_e):
        expr = m[expr_s:expr_e].strip()
        mm = re.search(r"\$\$\(\s*menu#([\w-]+)\s*>?\s*li", expr)
        if mm and menus is not None:
            return menus.get(mm.group(1), [])
        if expr.startswith('['):
            lb = m.find('[', expr_s)
            return list_items(src, lb, consts)
        if re.fullmatch(IDENT, expr):
            return lists.get(expr, [])
        return []

    for f in re.finditer(r"\bfor\s*\(\s*(?:var|final|const|String)\s+(?:String\s+)?(" + IDENT + r")\s+in\s+", m):
        lp = m.rfind('(', f.start(), f.end())
        rp = match_close(m, lp)
        keys = keys_of(f.end(), rp)
        if keys:
            bs, be = body_after(rp)
            out.append((f.group(1), keys, bs, be))
    for f in re.finditer(r"(?<![\w$.])(" + IDENT + r")\s*\.\s*(?:any|every|where|forEach|map|firstWhere)\s*\(\s*\(\s*("
                         + IDENT + r")\s*\)", m):
        keys = lists.get(f.group(1), [])
        if keys:
            bs, be = body_after(f.end() - 1)
            out.append((f.group(2), keys, bs, be))
    for ev in re.finditer(r"\bevent\s+[\w-]+\s+\$\(\s*menu#([\w-]+)[^)]*\)\s*\(([^)]*)\)\s*\{", m):
        ps = [p.strip() for p in ev.group(2).split(',')]
        if len(ps) < 2 or not ps[1] or menus is None:
            continue
        bs = ev.end() - 1
        out.append((ps[1], menus.get(ev.group(1), []), bs, match_close(m, bs)))
    return out


def dynamic_keys(src, s, e, scopes):
    """`el.id` / `me.id` / `id` (var id = el.id) / `id` (loop over a literal list) -> keys."""
    arg = src.masked[s:e].strip()
    mm = re.fullmatch(r"(" + IDENT + r")\.id", arg)
    var = mm.group(1) if mm else None
    if var is None and re.fullmatch(IDENT, arg):
        alias = None
        for a in re.finditer(r"\bvar\s+" + re.escape(arg) + r"\s*=\s*(" + IDENT + r")\.id\b", src.masked[:s]):
            alias = a
        if alias and s - alias.start() < 600:
            var = alias.group(1)
        else:
            var = arg
    best = None
    for v, keys, bs, be in scopes:
        if v == var and bs < s < be and (best is None or bs > best[2]):
            best = (v, keys, bs, be)
    return best[1] if best else []


def collect_accesses(srcs, base, helpers, consts, ui, menus=None, lists=None):
    """Every option access in `srcs` (direct sink calls and helper calls)."""
    out = []
    sinks = {k: [(a, s, o, None, False) for a, s, o in v] for k, v in base.items()}
    sinks.update(helpers)
    for src in srcs:
        scopes = scopes_for(src, menus, lists or {}, consts)
        fname = os.path.basename(src.rel)
        for cname, cstart, lp in calls(src):
            if cname not in sinks:
                continue
            args, rp = split_args(src, lp)
            named = {a[0]: src.masked[a[1]:a[2]].strip() for a in args if a[0]}
            ents = sinks[cname]
            stores = {x[1] for x in ents if x[2] != 'fixed'}
            for spec, store, op, pol, has_is_server in ents:
                if has_is_server and {'main', 'local'} <= stores and store in ('main', 'local'):
                    want = 'local' if named.get('isServer') == 'false' else 'main'
                    if store != want:
                        continue
                if op in ('get', 'set') and ('optGetter' in named or 'optSetter' in named):
                    store = 'custom'
                if store == 'FILE':
                    store = 'peer' if fname in SCITER_SESSION_FILES else (
                        'main' if fname in SCITER_MAIN_FILES or fname == 'cm.tis' else None)
                a = pick(args, spec)
                if not a:
                    continue
                key = resolve(src, a[1], a[2], consts)
                keys = [key] if key is not None else (
                    dynamic_keys(src, *trim(src, a[1], a[2]), scopes) if scopes else [])
                if pol is None and op == 'get':
                    pol = polarity_after(src, rp)
                if pol == 'option2bool':
                    pol = None
                    pol_rule = True
                else:
                    pol_rule = False
                via = 'direct' if cname in base else cname
                if key is None and keys:
                    via += ' (loop/handler over a list or menu ids)'
                for k in keys:
                    if not k or '$' in k:
                        continue
                    p = option2bool_polarity(k) if pol_rule else pol
                    if key is None:
                        p = None   # a loop's branches filter ids by prefix: polarity not known per id
                    out.append(Access(ui, k, store, op, src, cstart, via, p))
    return out


def sciter_dict_accesses(srcs, consts):
    """var opts = handler.get_options(); opts["key"] / opts["key"] = v  (main store)."""
    out = []
    for src in srcs:
        m = src.masked
        holders = [(d.start(), d.group(1)) for d in re.finditer(
            r"\bvar\s+(" + IDENT + r")\s*=\s*handler\.get_options\s*\(\s*\)", m)]
        if not holders:
            continue
        names = {h[1] for h in holders}
        for x in re.finditer(r"(?<![\w$.])(" + IDENT + r")\s*\[", m):
            if x.group(1) not in names or not any(o < x.start() and n == x.group(1) for o, n in holders):
                continue
            lb = x.end() - 1
            rb = match_close(m, lb)
            key = resolve(src, lb + 1, rb, consts)
            if key is None:
                continue
            op = 'set' if re.match(r"\s*=(?!=)", m[rb + 1:rb + 4]) else 'get'
            out.append(Access('sciter', key, 'main', op, src, x.start(), 'handler.get_options() map'))
    return out


# ---- Flutter UI elements: settings rows and menu entries -----------------------------------

# constructor -> (where the label is, kind). int = positional argument, 'name' = named
# argument: its literal, else the first translate('...') INSIDE that argument (a later
# translate() in a callback -- a toast, an error -- is not the label).
# Section headings (_Card title, SettingsSection) are not elements: wording of a group, and a
# key inside belongs to the row that holds it.
LABEL_CTORS = {
    '_OptionCheckBox': (1, 'setting'), '_Radio': ('label', 'setting'),
    '_Button': (0, 'setting'), '_SubButton': (0, 'setting'), '_SubLabeledWidget': (1, 'setting'),
    'SettingsTile': ('title', 'setting'), 'SettingsTile.switchTile': ('title', 'setting'),
    'SettingsTile.navigation': ('title', 'setting'),
    'ListTile': ('title', 'setting'), 'CheckboxListTile': ('title', 'setting'),
    'SwitchListTile': ('title', 'setting'),
    'TTextMenu': ('child', 'menu'), 'TToggleMenu': ('child', 'menu'), 'TRadioMenu': ('child', 'menu'),
    'CkbMenuButton': ('child', 'menu'), 'RdoMenuButton': ('child', 'menu'),
    # two classes share the name: remote_toolbar.dart (label in child) and
    # desktop/widgets/menu_button.dart (icon child, label in tooltip)
    'MenuButton': (('child', 'tooltip'), 'menu'), '_SubmenuButton': ('child', 'menu'),
    '_IconMenuButton': ('tooltip', 'menu'), '_IconSubmenuButton': ('tooltip', 'menu'),
    'MenuEntryButton': ('childBuilder', 'menu'), 'MenuEntrySwitch': ('text', 'menu'),
    'MenuEntrySwitchSync': ('text', 'menu'), 'MenuEntrySwitch2': ('text', 'menu'),
    'MenuEntryRadios': ('text', 'menu'), 'MenuEntrySubRadios': ('text', 'menu'),
    'MenuEntrySubMenu': ('text', 'menu'),
}
TRANSLATE_AT = re.compile(r"\btranslate\s*\(\s*(?=r?['\"])")


def first_translate(src, s, e):
    for t in TRANSLATE_AT.finditer(src.masked, s, e):
        lit = src.str_at.get(t.end())
        if lit and lit[2]:
            return lit[2]
    return None


def flutter_ui_elements(srcs, accesses):
    """-> [(kind, label, src, start, end)] and assigns each access to its innermost element."""
    els = []
    for src in srcs:
        for name, start, lp in calls(src):
            spec = LABEL_CTORS.get(name)
            if not spec:
                continue
            args, rp = split_args(src, lp)
            where, kind = spec
            label = None
            for w in (where if isinstance(where, tuple) else (where,)):
                a = pick(args, w)
                if a:
                    label = literal(src, a[1], a[2]) or first_translate(src, a[1], a[2])
                if label:
                    break
            if not label or '${' in label or '{$' in label:
                continue
            els.append({'kind': kind, 'label': norm(label), 'src': src, 'start': start, 'end': rp,
                        'ctor': name, 'access': []})
    by_file = {}
    for e in els:
        by_file.setdefault(id(e['src']), []).append(e)
    for a in accesses:
        best = None
        for e in by_file.get(id(a.src), []):
            if e['start'] <= a.off <= e['end'] and (best is None or e['start'] >= best['start']):
                best = e
        if best:
            best['access'].append(a)
    return els


def tuple_settings(srcs, helpers, consts):
    """List<(String, String)> builders mapped onto a helper, e.g.
    otherDefaultSettings().map((e) => otherRow(e.$1, e.$2)) -> label/key rows + accesses."""
    lists = {}
    for src in srcs:
        for name, params, bs, be in definitions(src):
            head = src.masked[max(0, bs - 400):bs]
            if not re.search(r"List<\(\s*String\s*,\s*String\s*\)>\s*" + re.escape(name) + r"\s*\(", head):
                continue
            rows = []
            for t in re.finditer(r"\(\s*(?=r?['\"])", src.masked[bs:be]):
                o = bs + t.end()
                lit = src.str_at.get(o)
                if not lit or not lit[2]:
                    continue
                r = re.match(r"\s*,\s*(" + IDENT + r")\s*,?\s*\)", src.masked[lit[1]:lit[1] + 120])
                if not r:
                    continue
                key = consts.get(r.group(1))
                if key:
                    rows.append((lit[2], key, o))
            lists[name] = (src, rows)
    els, acc = [], []
    for src in srcs:
        for x in re.finditer(r"\b(" + IDENT + r")\(\)\s*\.map\(\s*\(\s*(" + IDENT + r")\s*\)\s*=>\s*("
                             + IDENT + r")\(\s*\2\.\$1\s*,\s*\2\.\$2\s*\)", src.masked):
            lst, helper = x.group(1), x.group(3)
            if lst not in lists or helper not in helpers:
                continue
            lsrc, rows = lists[lst]
            for label, key, o in rows:
                mine = []
                for spec, store, op, pol, _hs in helpers[helper]:
                    if spec not in (0, 1) or (label, key)[spec] != key:
                        continue           # e.$1 -> param 0 (label), e.$2 -> param 1 (key)
                    mine.append(Access('flutter', key, store, op, src, x.start(), helper + ' via ' + lst,
                                       pol if pol != 'option2bool' else option2bool_polarity(key)))
                acc += mine
                els.append({'kind': 'setting', 'label': norm(label), 'src': lsrc, 'start': o, 'end': o,
                            'ctor': lst, 'access': mine})
    return els, acc


def canonical_keys(hbb):
    """hbb_common config.rs keys::OPTION_* -> value, and which KEYS_* list holds it."""
    path = os.path.join(hbb, 'src', 'config.rs')
    if not os.path.exists(path):
        return {}, {}
    text = open(path, encoding='utf-8').read()
    names = dict(re.findall(r"pub const (OPTION_[A-Z0-9_]+): &str =\s*\"([^\"]+)\"", text))
    lists = {}
    for m in re.finditer(r"pub const (KEYS_[A-Z_]+): &\[&str\] = &\[(.*?)\];", text, re.S):
        for n in re.findall(r"OPTION_[A-Z0-9_]+", m.group(2)):
            if n in names:
                lists.setdefault(names[n], []).append(m.group(1))
    return {v: k for k, v in names.items()}, lists


def gaps_table(path):
    """PARITY-GAPS.md -> (open P-numbers, closed P-numbers)."""
    opened, closed, sect = set(), set(), None
    if not os.path.exists(path):
        return opened, closed
    for line in open(path, encoding='utf-8'):
        if line.startswith('## '):
            sect = line[3:].strip().lower()
            continue
        m = re.match(r"\|\s*(P\d+)\s*\|", line)
        if m and sect:
            (opened if sect.startswith('open') else closed if sect.startswith('closed') else set()).add(m.group(1))
    return opened, closed


def verdict(text, opened, closed):
    """override counterpart text -> ('ok'|'known'|'missing', reason)."""
    t = (text or '').strip()
    if not t:
        return 'missing', ''
    up = t.upper()
    if up.startswith('MISSING') or up.startswith('UNTRIAGED'):
        p = re.search(r"\bP(\d+)\b", t)
        if p and 'P' + p.group(1) in opened:
            return 'known', t
        if p and 'P' + p.group(1) in closed:
            return 'missing', f"{t} -- P{p.group(1)} is closed in PARITY-GAPS.md but the gap is still there"
        return 'missing', f"{t} -- no open PARITY-GAPS.md P-number"
    return 'ok', t


AREA_F = [
    ('desktop/pages/desktop_setting_page.dart', 'Settings (desktop)'),
    ('mobile/pages/settings_page.dart', 'Settings (Android)'),
    ('common/widgets/toolbar.dart', 'Remote toolbar menus (shared)'),
    ('desktop/widgets/remote_toolbar.dart', 'Remote toolbar (desktop)'),
    ('mobile/pages/remote_page.dart', 'Remote session (Android)'),
    ('common/widgets/peer_card.dart', 'Peer card menu'),
    ('common/widgets/setting_widgets.dart', 'Settings widgets (shared)'),
    ('desktop/pages/desktop_home_page.dart', 'Main window (desktop)'),
    ('mobile/pages/server_page.dart', 'Share screen (Android)'),
    ('desktop/pages/server_page.dart', 'Connection manager (desktop)'),
    ('common/widgets/', 'Shared widgets'), ('models/', 'Models (no UI)'),
    ('desktop/', 'Desktop (other)'), ('mobile/', 'Android (other)'), ('', 'Flutter (other)'),
]


def farea(rel):
    r = rel[len('lib/'):] if rel.startswith('lib/') else rel
    for prefix, name in AREA_F:
        if r.startswith(prefix):
            return name
    return 'Flutter (other)'


def flutter_to_sciter(client, hbb, consts_dart):
    lib = os.path.join(client, 'flutter')
    dsrcs = [Src(p, os.path.relpath(p, lib), True) for p in dart_files(client)
             if not os.path.relpath(p, lib).startswith('lib/web/')]
    ui = os.path.join(client, 'src', 'ui')
    ssrcs = [Src(os.path.join(ui, f), f, False) for f in sorted(os.listdir(ui)) if f.endswith(('.tis', '.html'))]

    # constants: Dart top-level/static const strings; TIScript top-level const/var strings
    dconsts = {}
    for s in dsrcs:
        for off, nm, val in local_defs(s):
            if re.match(r"k[A-Z_]", nm) or nm.isupper():
                dconsts.setdefault(nm, val)
    dconsts.update({k: v for k, v in consts_dart.items() if k not in dconsts})
    sconsts = {}
    for s in ssrcs:
        for off, nm, val in local_defs(s):
            sconsts.setdefault(nm, val)

    dhelpers = find_helpers(dsrcs, DART_SINKS, 'flutter')
    shelpers = find_helpers(ssrcs, SCITER_SINKS, 'sciter')
    menus = menu_ids(ssrcs)
    facc = collect_accesses(dsrcs, DART_SINKS, dhelpers, dconsts, 'flutter', None, const_lists(dsrcs, dconsts))
    sacc = collect_accesses(ssrcs, SCITER_SINKS, shelpers, sconsts, 'sciter', menus, const_lists(ssrcs, sconsts))
    sacc += sciter_dict_accesses(ssrcs, sconsts)
    tels, tacc = tuple_settings(dsrcs, dhelpers, dconsts)
    uiels = flutter_ui_elements(dsrcs, facc) + tels
    facc += tacc
    annotate(facc, dsrcs)
    annotate(sacc, ssrcs)

    # Sciter presence index
    s_lits, s_ids, s_labels = {}, {}, {}
    for s in ssrcs:
        for st, en, v in s.strings:
            if v:
                s_lits.setdefault(v, []).append(s.loc(st))
        for x in re.finditer(r"#([A-Za-z][\w-]*)", s.masked):
            s_ids.setdefault(x.group(1), []).append(s.loc(x.start()))
        for x in re.finditer(r"""\bid\s*=\s*['"]?([A-Za-z][\w-]*)""", s.text):
            s_ids.setdefault(x.group(1), []).append(s.loc(x.start()))
        for t in TRANSLATE_AT.finditer(s.masked):
            lit = s.str_at.get(t.end())
            if lit and lit[2]:
                s_labels.setdefault(fold(lit[2]), []).append(s.loc(t.start()))
    s_rust = {}
    for rel in ('src/ui.rs', 'src/ui/remote.rs'):
        p = os.path.join(client, rel)
        if os.path.exists(p):
            for n, line in enumerate(open(p, encoding='utf-8'), 1):
                for v in re.findall(r'"((?:[^"\\]|\\.)*)"', line):
                    s_rust.setdefault(v, []).append(f"{os.path.basename(rel)}:{n}")
    s_keys = {}
    for a in sacc:
        s_keys.setdefault(a.key, []).append(a)

    canon, canon_lists = canonical_keys(hbb)

    # ---- elements -------------------------------------------------------------------------
    els = OrderedDict()

    def element(eid, kind, key, label):
        return els.setdefault(eid, {'id': eid, 'kind': kind, 'key': key, 'labels': [], 'flutter': [],
                                    'access': [], 'ctors': set(), 'ctor_locs': []})

    for e in uiels:
        keys = []
        for a in e['access']:
            if a.store != 'flutter-ui' and a.key not in keys:
                keys.append(a.key)
        loc = e['src'].loc(e['start'])
        if keys:
            for k in keys:
                el = element('option:' + k, 'option', k, e['label'])
                if e['label'] not in el['labels']:
                    el['labels'].append(e['label'])
                if loc not in el['flutter']:
                    el['flutter'].append(loc)
                el['ctor_locs'].append(loc)
                el['ctors'].add(e['ctor'])
        elif e['kind'] != 'section' and not any(a.store == 'flutter-ui' for a in e['access']):
            el = element(e['kind'] + ':' + e['label'], e['kind'], None, e['label'])
            if e['label'] not in el['labels']:
                el['labels'].append(e['label'])
            if loc not in el['flutter']:
                el['flutter'].append(loc)
            el['ctor_locs'].append(loc)
            el['ctors'].add(e['ctor'])
    for a in facc:
        el = element('option:' + a.key, 'option', a.key, '')
        el['access'].append(a)
        if a.loc not in el['flutter']:
            el['flutter'].append(a.loc)

    rows = []
    for el in els.values():
        locs = el['flutter']
        # Android-only: every row/menu entry is on an Android page and every access is reached
        # only from Android pages
        mobile_only = all(l.startswith('lib/mobile/') for l in el['ctor_locs']) and \
            not any(a.shared for a in el['access'])
        stores = sorted({a.store for a in el['access'] if a.store})
        sciter, how, hint = '', '', ''
        k = el['key']
        if k is not None:
            if k in s_keys:
                sciter, how = '; '.join(sorted({a.loc for a in s_keys[k]})[:3]), 'auto'
            elif k in s_ids:
                sciter, how = '#id: ' + '; '.join(s_ids[k][:3]), 'auto'
            elif k in s_lits:   # a bare string ('theme' as a data-kind, a CM field ...): a hint only
                hint = 'string in Sciter, not used as an option: ' + '; '.join(s_lits[k][:2])
        for lab in el['labels']:
            if sciter or fold(lab) not in s_labels:
                continue
            if k is None:
                sciter, how = 'label: ' + '; '.join(s_labels[fold(lab)][:3]), 'auto-label'
            else:   # same wording, but Sciter never uses this key: a different setting
                hint = ((hint + '; ') if hint else '') + 'same label in Sciter (another key?): ' + \
                    '; '.join(s_labels[fold(lab)][:2])
            break
        if not sciter and k is not None and k in s_rust:
            hint = ('Rust only, no Sciter control: ' + '; '.join(s_rust[k][:2]) + ('; ' + hint if hint else ''))
        rows.append({
            'id': el['id'], 'kind': el['kind'], 'key': k or '', 'label': ' / '.join(el['labels'][:2]),
            'area': farea(locs[0]) if locs else '', 'platform': 'android-only' if mobile_only else (
                'desktop-only' if all(l.startswith('lib/desktop/') for l in locs) else 'shared'),
            'stores': ','.join(stores), 'flutter': '; '.join(locs[:3]), 'sciter': sciter, 'matched': how,
            'hint': hint,
            'hbb_common': (canon.get(k, '') + (' in ' + '/'.join(canon_lists.get(k, [])) if canon_lists.get(k) else '')) if k else '',
            '_access': el['access'],
        })
    return rows, facc, sacc, s_keys


def fold(s):
    s = norm(s).lower()
    s = re.sub(r"\s*\((beta|experimental)\)$", '', s)
    return s.rstrip(' .:…')


# ---- behaviour notes ---------------------------------------------------------------------------

STORES = ('main', 'local', 'user-default', 'peer', 'toggle')


def gated_stores(fixed, accs):
    """Stores a UI's is_option_fixed checks cover: those read or written in the function that
    holds the check (or by the same helper call). A check with no store access next to it
    covers every store (unknown -> no note)."""
    out = set()
    for f in fixed:
        near = {a.store for a in accs if a.src is f.src and a.op != 'fixed' and a.store in STORES and (
            a.off == f.off or (f.func and f.func[1] <= a.off <= f.func[2]))}
        out |= near or set(STORES)
    return out


def behaviour_notes(facc, sacc, canon_lists, stats=None):
    """Candidates only: keys both UIs use whose gating, store or default differs.
    stats (dict, optional) gets how many keys each check could compare."""
    notes = []
    stats = {} if stats is None else stats
    fby, sby = {}, {}
    for a in facc:
        if a.shared:          # Sciter is desktop: compare with what desktop Flutter reaches
            fby.setdefault(a.key, []).append(a)
    for a in sacc:
        sby.setdefault(a.key, []).append(a)
    stats['keys'] = len(set(fby) & set(sby))
    for key in sorted(set(fby) & set(sby)):
        fa, sa = fby[key], sby[key]
        if any(a.op == 'fixed' for a in fa + sa):
            stats['fixed'] = stats.get('fixed', 0) + 1
        f_gate = gated_stores([a for a in fa if a.op == 'fixed'], fa)
        s_gate = gated_stores([a for a in sa if a.op == 'fixed'], sa)
        f_set = [a for a in fa if a.op == 'set' and a.store in STORES]
        s_set = [a for a in sa if a.op == 'set' and a.store in STORES]
        miss_s = [a for a in s_set if a.store in f_gate and a.store not in s_gate]
        miss_f = [a for a in f_set if a.store in s_gate and a.store not in f_gate]
        if miss_s:
            notes.append({'id': f'behaviour:fixed:{key}', 'check': 'fixed', 'key': key,
                          'note': 'Flutter greys it when the administrator fixed the option; Sciter lets the '
                                  'user change it with no is_option_fixed check (the Rust setter drops the write '
                                  f"silently) -- store {'+'.join(sorted({a.store for a in miss_s}))}",
                          'flutter': '; '.join(sorted({a.loc for a in fa if a.op == 'fixed'})[:2]),
                          'sciter': '; '.join(sorted({a.loc for a in miss_s})[:2])})
        if miss_f:
            notes.append({'id': f'behaviour:fixed:{key}', 'check': 'fixed', 'key': key,
                          'note': 'Sciter greys it when the administrator fixed the option; Flutter lets the '
                                  'user change it with no isOptionFixed check (the Rust setter drops the write '
                                  f"silently) -- store {'+'.join(sorted({a.store for a in miss_f}))}",
                          'flutter': '; '.join(sorted({a.loc for a in miss_f})[:2]),
                          'sciter': '; '.join(sorted({a.loc for a in sa if a.op == 'fixed'})[:2])})
        fst = {a.store for a in fa if a.store in STORES}
        sst = {a.store for a in sa if a.store in STORES}
        if fst and sst:
            stats['store'] = stats.get('store', 0) + 1
        if fst and sst and not (fst & sst):
            lists = '/'.join(canon_lists.get(key, [])) or 'no hbb_common KEYS_* list'
            notes.append({'id': f'behaviour:store:{key}', 'check': 'store', 'key': key,
                          'note': f"Flutter keeps it in {'+'.join(sorted(fst))}, Sciter in {'+'.join(sorted(sst))}: "
                                  f"the two UIs do not see each other's value (hbb_common: {lists})",
                          'flutter': '; '.join(sorted({a.loc for a in fa if a.store in fst})[:2]),
                          'sciter': '; '.join(sorted({a.loc for a in sa if a.store in sst})[:2])})
        elif fst and sst:
            # same store in both, but one UI also WRITES the key to a store the other never
            # touches (e.g. a session toggle that Flutter can also set as a default for new
            # sessions): that setting exists in one UI only, though the key matched
            f_only = {a.store for a in f_set} - sst
            s_only = {a.store for a in s_set} - fst
            if f_only or s_only:
                both = '+'.join(sorted(fst & sst))
                parts = [f"{ui} also writes it to {'+'.join(sorted(extra))}, a store {other} never reads or writes"
                         for ui, extra, other in (('Flutter', f_only, 'Sciter'), ('Sciter', s_only, 'Flutter'))
                         if extra]
                notes.append({'id': f'behaviour:store:{key}', 'check': 'store', 'key': key,
                              'note': '; '.join(parts) + f" (both use {both})",
                              'flutter': '; '.join(sorted({a.loc for a in f_set if a.store in f_only} or
                                                          {a.loc for a in fa if a.store in fst})[:2]),
                              'sciter': '; '.join(sorted({a.loc for a in s_set if a.store in s_only} or
                                                         {a.loc for a in sa if a.store in sst})[:2])})
        fp = {a.polarity for a in fa if a.op == 'get' and a.polarity and a.store in STORES}
        sp = {a.polarity for a in sa if a.op == 'get' and a.polarity and a.store in STORES}
        if fp and sp:
            stats['default'] = stats.get('default', 0) + 1
        if len(fp) == 1 and len(sp) == 1 and fp != sp:
            notes.append({'id': f'behaviour:default:{key}', 'check': 'default', 'key': key,
                          'note': f"unset value reads as {'on' if fp == {'empty=on'} else 'off'} in Flutter, "
                                  f"{'on' if sp == {'empty=on'} else 'off'} in Sciter",
                          'flutter': '; '.join(sorted({a.loc for a in fa if a.polarity})[:2]),
                          'sciter': '; '.join(sorted({a.loc for a in sa if a.polarity})[:2])})
    return notes


def client_rev(client):
    try:
        rev = subprocess.run(['git', '-C', client, 'rev-parse', '--short=9', 'HEAD'], capture_output=True,
                             text=True, timeout=10).stdout.strip()
        dirty = subprocess.run(['git', '-C', client, 'status', '--porcelain', '--', 'src/ui', 'src/ui.rs',
                                'flutter/lib'], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return 'unknown'
    if not rev:
        return 'unknown (not a git checkout)'
    return rev + (' + uncommitted changes in src/ui or flutter/lib' if dirty else '')


def mdcell(s):
    return (s or '').replace('|', '\\|')


def main():
    ap = Parser()
    ap.add_argument('--client', default=os.path.join(SUPER, 'rustdesk-client-nemo'))
    ap.add_argument('--hbb-common', default=None,
                    help='hbb_common checkout (default: <client>/libs/hbb_common, else the superproject one)')
    ap.add_argument('--out', default=SUPER)
    ap.add_argument('--overrides', default=os.path.join(HERE, 'overrides.csv'))
    ap.add_argument('--overrides-f2s', default=os.path.join(HERE, 'overrides-f2s.csv'))
    ap.add_argument('--gaps', default=os.path.join(SUPER, 'PARITY-GAPS.md'))
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--strict', action='store_true', help='KNOWN gaps fail too (also TBF_STRICT=1)')
    a = ap.parse_args()
    strict = a.strict or os.environ.get('TBF_STRICT') == '1'

    if not (os.path.isdir(os.path.join(a.client, 'src', 'ui')) and os.path.isdir(os.path.join(a.client, 'flutter', 'lib'))):
        print(f"client source not found: {a.client} (needs src/ui and flutter/lib)", file=sys.stderr)
        sys.exit(2)
    hbb = a.hbb_common
    if not hbb:
        hbb = os.path.join(a.client, 'libs', 'hbb_common')
        if not os.path.exists(os.path.join(hbb, 'src', 'config.rs')):
            hbb = os.path.join(SUPER, 'rustdesk-client-nemo', 'libs', 'hbb_common')
    os.makedirs(a.out, exist_ok=True)
    rev = client_rev(a.client)
    opened, closed = gaps_table(a.gaps)

    # ---- Sciter -> Flutter ------------------------------------------------------------------
    els = sciter_elements(a.client)
    literals, uses, ffi = flutter_index(a.client)
    bmatch = binding_matches(a.client)
    ov = load_overrides(a.overrides)
    rows, missing, known = [], [], []
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
        # an override can also RECORD a gap ("MISSING: P<n> ..."): known if P<n> is open
        v, why = verdict(flutter, opened, closed) if (not flutter or flutter.strip().upper().startswith(
            ('MISSING', 'UNTRIAGED'))) else ('ok', '')
        if v == 'known':
            known.append(('S->F', row['id'], row['area'], row['sciter'], why))
        elif v == 'missing':
            row['_why'] = why
            missing.append(row)

    csv_path = os.path.join(a.out, 'flutter-parity-elements.csv')
    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=[k for k in rows[0].keys() if not k.startswith('_')],
                           extrasaction='ignore')
        w.writeheader()
        w.writerows(rows)

    def count(pred, rs=rows):
        return sum(1 for r in rs if pred(r))
    md = [
        '# Flutter parity: every Sciter element\n',
        'Generated by `tests/parity/inventory.py` from the client source -- do not edit by hand;',
        'put Flutter locations, lab verdicts and decisions in `tests/parity/overrides.csv`.',
        f"Client: `{rev}`. The reverse direction (Flutter -> Sciter) and the behaviour notes are in",
        '`FLUTTER-TO-SCITER-PARITY.md`.\n',
        f"Elements: **{len(rows)}** | Flutter counterpart found: **{len(rows) - len(missing) - sum(1 for k in known if k[0] == 'S->F')}** "
        f"(auto {count(lambda r: r['matched'] == 'auto')}, by hand {count(lambda r: r['matched'] == 'override')}) "
        f"| **missing: {len(missing)}** | known gaps: {sum(1 for k in known if k[0] == 'S->F')} | works verified desktop: "
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
    print(f"Sciter->Flutter: {len(rows)} elements, {len(missing)} without a Flutter counterpart -> {csv_path}")

    # ---- Flutter -> Sciter --------------------------------------------------------------------
    dconsts = {}
    for path in dart_files(a.client):
        for line in open(path, encoding='utf-8', errors='replace'):
            for m in re.finditer(r"""const\s+(?:String\s+)?([A-Za-z0-9_]+)\s*=\s*(['"])([^'"]+)\2""", line):
                dconsts.setdefault(m.group(1), m.group(3))
    frows, facc, sacc, s_keys = flutter_to_sciter(a.client, hbb, dconsts)
    _, canon_lists = canonical_keys(hbb)
    ovf = load_overrides(a.overrides_f2s)
    fmissing, freport = [], []
    for r in frows:
        o = ovf.get(r['id'], {})
        r['verified_by'], r['note'] = o.get('verified_by', ''), o.get('note', '')
        if o.get('sciter'):
            r['sciter'], r['matched'] = o['sciter'], 'override'
        stores = set(filter(None, r['stores'].split(',')))
        if not r['sciter'] and stores and stores <= {'flutter-ui'}:
            r['sciter'], r['matched'] = 'n/a: Flutter window/layout state (session/peer flutter option)', 'auto-n/a'
        elif not r['sciter'] and r['hbb_common'].startswith('OPTION_FLUTTER_'):
            r['sciter'], r['matched'] = 'n/a: Flutter UI state (hbb_common ' + r['hbb_common'] + ')', 'auto-n/a'
        v, why = verdict(r['sciter'], opened, closed) if (not r['sciter'] or r['sciter'].strip().upper().startswith(
            ('MISSING', 'UNTRIAGED'))) else ('ok', '')
        r['status'] = 'present' if v == 'ok' and r['matched'] in ('auto', 'auto-label', 'override') and not \
            r['sciter'].lower().startswith(('n/a', 'decision')) else ('n/a' if v == 'ok' else v)
        if v == 'missing':
            if r['platform'] == 'android-only':
                r['status'] = 'android-only'
                freport.append(r)
            elif r['kind'] == 'menu':
                r['status'] = 'label-only'
                freport.append(r)
            else:
                r['_why'] = why
                fmissing.append(r)
        elif v == 'known':
            known.append(('F->S', r['id'], r['area'], r['flutter'], why))
    fcsv = os.path.join(a.out, 'flutter-to-sciter-parity.csv')
    fields = ['id', 'area', 'kind', 'key', 'label', 'platform', 'stores', 'flutter', 'sciter', 'matched',
              'status', 'hint', 'hbb_common', 'verified_by', 'note']
    with open(fcsv, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
        w.writeheader()
        w.writerows(frows)

    nstats = {}
    notes = behaviour_notes(facc, sacc, canon_lists, nstats)
    open_notes = []
    for n in notes:
        o = ovf.get(n['id'], {})
        n['verdict'] = o.get('sciter', '')
        n['verified_by'], n['override_note'] = o.get('verified_by', ''), o.get('note', '')
        if n['verdict'].lower().startswith('ok'):
            continue
        v, why = verdict(n['verdict'], opened, closed) if n['verdict'] else ('missing', '')
        if v == 'known':
            n['status'] = 'known'
            known.append(('behaviour', n['id'], n['key'], '', why))
        elif v == 'ok':   # a verdict that is neither "ok: ..." nor "MISSING: P<n>"
            n['status'] = 'open'
            n['_why'] = f"verdict {n['verdict']!r} is neither 'ok: <reason>' nor 'MISSING: P<n>'"
            open_notes.append(n)
        else:
            n['status'] = 'open'
            n['_why'] = why
            open_notes.append(n)
    ncsv = os.path.join(a.out, 'parity-behaviour-notes.csv')
    with open(ncsv, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=['id', 'check', 'key', 'note', 'flutter', 'sciter', 'verdict',
                                          'verified_by', 'override_note', 'status'], extrasaction='ignore')
        w.writeheader()
        w.writerows(notes)

    fk = [k for k in known if k[0] == 'F->S']
    nk = [k for k in known if k[0] == 'behaviour']

    def fcount(st):
        return sum(1 for r in frows if r['status'] == st)
    md = [
        '# Flutter -> Sciter parity: every Flutter option key, settings row and menu entry\n',
        'Generated by `tests/parity/inventory.py` from the client source -- do not edit by hand;',
        'put Sciter locations, decisions and gap numbers in `tests/parity/overrides-f2s.csv`,',
        'open gaps in `PARITY-GAPS.md`. The other direction is `FLUTTER-PARITY-ELEMENTS.md`.',
        f"Client: `{rev}`.\n",
        f"Flutter elements: **{len(frows)}** | in Sciter: **{fcount('present')}** | n/a: {fcount('n/a')} "
        f"| **unaccounted: {len(fmissing)}** | known gaps: {len(fk)} | report-only: Android-only "
        f"{fcount('android-only')}, menu entries without option key {fcount('label-only')} "
        f"| behaviour notes: {len(notes)} ({len(nk)} known gaps, {len(open_notes)} not triaged)\n",
        '"In Sciter" is a presence candidate only: the key is read/written by the Sciter UI or is an',
        'element `#id` in `src/ui`; a settings row or menu entry without an option key matches on its',
        'translate() label. Hints next to a MISSING row: the same label on another key, a bare string',
        'that is not an option use, or *Rust only* (in `src/ui.rs` / `src/ui/remote.rs`, no Sciter page',
        'uses it). Stores: main = RustDesk2.toml options, local = RustDesk_local.toml, user-default =',
        'defaults for new sessions, peer = one peer\'s options, toggle = session toggle.\n',
        '## Behaviour notes (both UIs have the key)\n',
        'Candidates from the source, not lab results. `fixed` = one UI greys the row when the',
        'administrator fixed the option and the other does not; `store` = the two UIs keep the key in',
        'different places, or one UI also writes it to a store the other never touches (e.g. a session',
        'toggle that only Flutter can also set as a default for new sessions); `default` = an unset',
        'value reads as on in one UI and off in the other.',
        'Accept one with `ok: <reason>` or link it to a gap with `MISSING: P<n>` in overrides-f2s.csv.',
        f"Compared: {nstats.get('keys', 0)} keys both UIs use (desktop + shared Flutter code); fixed check "
        f"{nstats.get('fixed', 0)}, store {nstats.get('store', 0)}, default {nstats.get('default', 0)} of them "
        'had enough evidence on both sides.\n',
        '| Note | Key | What differs | Flutter | Sciter | Status |', '|---|---|---|---|---|---|',
    ]
    for n in notes:
        st = n.get('status') or ''
        shown = n['verdict'] if not st else (st + (': ' + n['verdict'] if n['verdict'] else ''))
        md.append(f"| `{n['id']}` | `{n['key']}` | {mdcell(n['note'])} | {n['flutter']} | {n['sciter']} "
                  f"| {mdcell(shown)} |")
    order = ['missing', 'known', 'label-only', 'android-only', 'n/a', 'present']
    titles = {'missing': 'Unaccounted (fails --check)', 'known': 'Known gaps (PARITY-GAPS.md)',
              'label-only': 'Menu entries without an option key, label not in Sciter (report-only)',
              'android-only': 'Android-only (report-only)', 'n/a': 'Not applicable to Sciter', 'present': 'Present in Sciter'}
    for st in order:
        sel = [r for r in frows if r['status'] == st]
        if not sel:
            continue
        md.append(f"\n## {titles[st]} ({len(sel)})\n")
        md.append('| Element | Label | Area | Stores | Flutter | Sciter | Note |')
        md.append('|---|---|---|---|---|---|---|')
        for r in sorted(sel, key=lambda r: (r['area'], r['id'])):
            sc = r['sciter'] or ('**MISSING**' + (f" ({r['hint']})" if r['hint'] else ''))
            note = '; '.join(x for x in (r['hbb_common'] and f"hbb_common {r['hbb_common']}", r['hint'] if r['sciter'] else '',
                                         r['verified_by'], r['note']) if x)
            md.append(f"| `{mdcell(r['id'])}` | {mdcell(r['label'])} | {r['area']} | {r['stores']} | {r['flutter']} "
                      f"| {mdcell(sc)} | {mdcell(note)} |")
    with open(os.path.join(a.out, 'FLUTTER-TO-SCITER-PARITY.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(md) + '\n')
    print(f"Flutter->Sciter: {len(frows)} elements, {len(fmissing)} unaccounted, {len(fk)} known, "
          f"{len(freport)} report-only, {len(notes)} behaviour notes ({len(open_notes)} not triaged) -> {fcsv}")

    if a.check:
        for r in missing[:60]:
            print(f"  MISSING S->F {r['id']} ({r['area']}, {r['sciter']}) {r['label']} {r.get('_why', '')}".rstrip())
        for r in fmissing[:60]:
            print(f"  MISSING F->S {r['id']} ({r['area']}, {r['flutter']}) {r['label']} {r.get('_why', '')}".rstrip())
        groups = OrderedDict()   # one line per PARITY-GAPS row
        for k in known:
            pn = re.search(r"\bP\d+\b", k[4])
            groups.setdefault((pn.group(0) if pn else '?', k[0]), []).append(k[1])
        for (pn, direction), ids in sorted(groups.items(), key=lambda g: (int(g[0][0][1:]) if g[0][0][1:].isdigit()
                                                                          else 1 << 30, g[0][1])):
            shown = ', '.join(ids[:6]) + (f", ... (+{len(ids) - 6})" if len(ids) > 6 else '')
            print(f"  KNOWN   {pn} {direction}: {len(ids)} -- {shown}")
        for n in open_notes[:40]:
            why = f" -- {n['_why']}" if n.get('_why') else ' -- no verdict in overrides-f2s.csv'
            print(f"  NOTE    {n['id']}: {n['note']} [F {n['flutter']} | S {n['sciter']}]{why}")
        # an untriaged behaviour note, or one whose MISSING: P<n> is not open, fails like an
        # unaccounted element: a new gating / store / default difference must not pass silently
        if missing or fmissing or open_notes or (strict and known):
            sys.exit(1)


if __name__ == '__main__':
    main()
