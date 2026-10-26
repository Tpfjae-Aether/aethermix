# -*- coding: utf-8 -*-
"""Static check for the phone client on a machine without Xcode.

Parses every file in ios/AetherMix/Sources with the tree-sitter Swift grammar
and cross-checks member references against declarations in the same sources:
`Bridge.shared.x`, `theme.x`, `engine.x`, `store.x`, `shelf.x`. That catches
the two failures that compile nowhere and only show up at runtime as a blank
screen: a syntax error and a renamed property.

    pip install tree-sitter tree-sitter-swift
    python ios/tools/swift_check.py

Exit 0 means every file parses and every member resolves.
"""
import io, os, re, sys, glob

from tree_sitter import Language, Parser
import tree_sitter_swift

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'AetherMix', 'Sources')
LANG = Language(tree_sitter_swift.language())
parser = Parser(LANG)

files = sorted(glob.glob(os.path.join(ROOT, '*.swift')))
src = {}
bad = 0
for f in files:
    data = io.open(f, 'rb').read()
    tree = parser.parse(data)
    src[f] = data.decode('utf-8')
    if tree.root_node.has_error:
        # locate the first error node for a useful message
        stack = [tree.root_node]
        err = None
        while stack:
            n = stack.pop()
            if n.type == 'ERROR' or n.is_missing:
                err = n
                break
            stack.extend(n.children)
        if err is not None:
            ln = err.start_point[0] + 1
            col = err.start_point[1] + 1
            line = src[f].splitlines()[ln - 1] if ln <= len(src[f].splitlines()) else ''
            print('SYNTAX %s:%d:%d  %s' % (f, ln, col, line.strip()[:120]))
        else:
            print('SYNTAX %s (error node not located)' % f)
        bad += 1

print('parsed %d files, %d with syntax errors' % (len(files), bad))

# ---------------------------------------------------------------- members
MEM = re.compile(r'^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:public |private |fileprivate |internal |static |final |override |lazy |weak |nonisolated )*'
                 r'(?:var|let|func|case)\s+([A-Za-z_]\w*)', re.M)
TYP = re.compile(r'^(?:final )?(?:public |private |fileprivate )?(struct|class|enum|extension)\s+([A-Za-z_]\w*)', re.M)

types = {}       # type -> set(members)
declared_types = set()
for f, text in src.items():
    # split into type blocks by brace depth tracking from each type header
    for m in TYP.finditer(text):
        kind, name = m.group(1), m.group(2)
        if kind == 'extension':
            continue
        # walk braces from the header to its end
        i = text.find('{', m.end())
        if i < 0:
            continue
        depth = 0
        j = i
        while j < len(text):
            if text[j] == '{':
                depth += 1
            elif text[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = text[i:j]
        mem = types.setdefault(name, set())
        for mm in MEM.finditer(body):
            mem.add(mm.group(1))
        declared_types.add(name)
        # SwiftUI synthesised / protocol members that are not written down
        mem.update({'body', 'init', 'self', 'hash', 'id', 'decode', 'encode', 'description'})

# implicit members every ObservableObject / View has, plus enum cases of lookalikes
EXTRA = {
    'store': {'objectWillChange'},
    'engine': {'objectWillChange'},
    'shelf': {'objectWillChange'},
    'app': {'objectWillChange'},
}

STR = re.compile(r'"(?:\\.|[^"\\])*"')


def check_receiver(f, text, recv, typ):
    """flag `<recv>.<member>` where member is not declared on <typ>`"""
    # a path like "shelf.json" must not look like a property access
    text = STR.sub('""', text)
    known = types.get(typ)
    if not known:
        print('NO TYPE %s for %s' % (typ, recv))
        return 0
    known = known | EXTRA.get(recv, set())
    issues = 0
    for m in re.finditer(r'(?<![\w.])' + recv + r'\.([A-Za-z_]\w*)', text):
        name = m.group(1)
        # skip chained calls whose member is a standard Swift/Foundation member
        if name in ('self', 'map', 'flatMap', 'filter', 'count', 'isEmpty', 'first', 'last',
                    'append', 'removeAll', 'sorted', 'contains', 'forEach', 'prefix', 'dropFirst',
                    'indices', 'enumerated', 'joined', 'split', 'reversed', 'randomElement',
                    'description', 'type', 'init'):
            continue
        if name.startswith('$') or name[0].isupper():
            continue
        if name not in known:
            ln = text[:m.start()].count('\n') + 1
            print('MEMBER %s:%d  %s.%s' % (f, ln, recv, name))
            issues += 1
    return issues

total = 0
for f, text in src.items():
    total += check_receiver(f, text, 'engine', 'PlayerEngine')
    total += check_receiver(f, text, 'store', 'LibraryStore')
    total += check_receiver(f, text, 'shelf', 'LocalShelf')
print('%d unresolved member references' % total)

# Bridge methods must exist for every Bridge.shared.<name>
bridge = types.get('Bridge', set())
miss = 0
for f, text in src.items():
    for m in re.finditer(r'Bridge\.shared\.([A-Za-z_]\w*)', text):
        if m.group(1) not in bridge:
            ln = text[:m.start()].count('\n') + 1
            print('BRIDGE %s:%d %s' % (f, ln, m.group(1)))
            miss += 1
print('%d unknown Bridge members' % miss)

# Theme keys used as theme.<x> must exist in Theme
theme = types.get('Theme', set())
tmiss = 0
for f, text in src.items():
    for m in re.finditer(r'theme\.([A-Za-z_]\w*)', text):
        if m.group(1) not in theme:
            ln = text[:m.start()].count('\n') + 1
            print('THEME %s:%d %s' % (f, ln, m.group(1)))
            tmiss += 1
print('%d unknown Theme members' % tmiss)

# ------------------------------------------------- reserved words and awaiting
# Tree-sitter happily parses `var repeat: Int?` and an async call with no await,
# but the Swift compiler rejects both, and those were exactly what failed the
# first CI build. A miss here costs a second; a miss in CI costs three minutes.
KEYWORDS = {
    'repeat', 'for', 'while', 'if', 'else', 'switch', 'case', 'default', 'break',
    'continue', 'return', 'func', 'var', 'let', 'class', 'struct', 'enum',
    'protocol', 'extension', 'import', 'in', 'is', 'as', 'do', 'catch', 'throw',
    'throws', 'rethrows', 'try', 'await', 'async', 'guard', 'defer', 'init',
    'self', 'super', 'true', 'false', 'nil', 'where', 'inout', 'operator',
    'static', 'public', 'private', 'fileprivate', 'internal', 'open', 'final',
    'lazy', 'weak', 'unowned', 'mutating', 'nonmutating', 'convenience',
    'required', 'override', 'subscript', 'typealias', 'associatedtype',
    'deinit', 'some', 'any', 'each', 'borrowing', 'consuming', 'package',
    'actor', 'nonisolated', 'distributed', 'macro', 'yield',
}

KW_DECL = re.compile(
    r'^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:public |private |fileprivate |internal '
    r'|static |final |override |lazy |weak |nonisolated |mutating |convenience '
    r'|required )*(var|let|func|case)\s+([A-Za-z_]\w*)', re.M)

kwbad = 0
for f, text in src.items():
    for m in KW_DECL.finditer(text):
        if m.group(2) in KEYWORDS:
            ln = text[:m.start()].count('\n') + 1
            print('KEYWORD %s:%d  %s %s' % (f, ln, m.group(1), m.group(2)))
            kwbad += 1
print('%d reserved words used as identifiers' % kwbad)

# an async Bridge method called without await does not compile
ASYNC_FN = re.compile(r'func\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\([^)]*\)\s*(?:async|rethrows)')
async_names = set()
for f, text in src.items():
    if f.replace('\\', '/').endswith('Bridge.swift'):
        async_names |= set(ASYNC_FN.findall(text))

awbad = 0
for f, text in src.items():
    for m in re.finditer(r'(?<![\w.])Bridge\.shared\.([A-Za-z_]\w*)\s*\(', text):
        nm = m.group(1)
        if nm not in async_names:
            continue
        line_start = text.rfind('\n', 0, m.start()) + 1
        if 'await' not in text[line_start:m.start()]:
            ln = text[:m.start()].count('\n') + 1
            print('AWAIT %s:%d  Bridge.shared.%s is async and needs await' % (f, ln, nm))
            awbad += 1
print('%d async Bridge calls without await' % awbad)

sys.exit(1 if bad or total or miss or tmiss or kwbad or awbad else 0)
