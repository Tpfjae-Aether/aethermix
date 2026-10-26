# -*- coding: utf-8 -*-
"""Contract test: the Swift phone client against the live desktop bridge.

There is no iOS toolchain on this machine, so the client cannot be compiled
here. What *can* be proven is the half of the app that actually breaks in the
field: the wire. This script reads the Swift `Codable` structs out of
`AetherMix/Sources/Models.swift` and `Theme.swift`, then validates the real
bridge answers against them — a missing non-optional field is exactly the
silent "the room is empty" failure. It also opens a real byte-range stream and
proxies a real cover, which are the two paths the phone cannot fake.

Usage:  python ios/tools/contract_test.py [--host 127.0.0.1:3690]
Exit:   0 = every contract holds, 1 = at least one failure.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

# titles and room names are free text and reach this from a UTF-8 bridge on a
# cp1252 console; never let a print() fail the run
try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'ios', 'AetherMix', 'Sources')
FAIL = []
PASS = 0


def ok(name, detail=''):
    global PASS
    PASS += 1
    print('  ok   %s%s' % (name, (' - ' + detail) if detail else ''))


def bad(name, detail):
    FAIL.append((name, detail))
    print('  FAIL %s - %s' % (name, detail))


# ---------------------------------------------------------------------------
# Swift struct reader
# ---------------------------------------------------------------------------
class Struct:
    def __init__(self, name):
        self.name = name
        self.fields = []          # (jsonKey, type, optional)
        self.keys = {}            # var name -> CodingKey string


def read_structs():
    structs = {}
    for fn in sorted(os.listdir(SRC)):
        if not fn.endswith('.swift'):
            continue
        text = open(os.path.join(SRC, fn), encoding='utf-8').read()
        for m in re.finditer(r'^struct\s+(\w+)\s*:[^{]*\{', text, re.M):
            name = m.group(1)
            st = Struct(name)
            i = m.end() - 1
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
            body = text[i + 1:j]
            # CodingKeys map (var name -> wire key)
            ck = re.search(r'enum\s+CodingKeys[^{]*\{(.*?)\n\s*\}', body, re.S)
            if ck:
                for line in ck.group(1).splitlines():
                    line = line.strip().rstrip(',')
                    if not line.startswith('case '):
                        continue
                    for item in line[5:].split(','):
                        item = item.strip()
                        if not item:
                            continue
                        if '=' in item:
                            var, key = [x.strip() for x in item.split('=', 1)]
                            st.keys[var] = key.strip('"')
                        else:
                            st.keys[item] = item
            for line in body.splitlines():
                line = line.strip()
                mm = re.match(r'var\s+(\w+)\s*:\s*([\w\[\]:? ]+?)(\s*=\s*.*)?$', line)
                if not mm:
                    continue
                var, typ = mm.group(1), mm.group(2).strip()
                if typ.startswith('[') and typ.endswith(']'):
                    typ = typ.replace(' ', '')
                optional = typ.endswith('?')
                if optional:
                    typ = typ[:-1]
                # computed properties (`var id: String { ... }`) have no storage
                if 'CodingKeys' in body and var not in st.keys:
                    # a stored field without a CodingKey case is not decoded
                    if re.search(r'var\s+%s\s*:\s*[\w\[\]:? ]+\s*\{' % var, body):
                        continue
                    if var in ('id',):
                        continue
                st.fields.append((st.keys.get(var, var), typ, optional))
            structs[name] = st
    return structs


def type_ok(value, typ, structs, path):
    if typ == 'String':
        return isinstance(value, str)
    if typ == 'Int':
        return isinstance(value, int) and not isinstance(value, bool)
    if typ == 'Double':
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if typ == 'Bool':
        return isinstance(value, bool)
    if typ.startswith('[') and typ.endswith(']'):
        inner = typ[1:-1]
        return isinstance(value, list) and all(type_ok(v, inner, structs, path) for v in value)
    if typ in structs:
        return validate(value, structs[typ], structs, path) == []
    return True


def validate(value, st, structs, path='$'):
    errs = []
    if not isinstance(value, dict):
        return ['%s: expected an object for %s' % (path, st.name)]
    for key, typ, optional in st.fields:
        if key not in value:
            if optional:
                continue
            errs.append('%s.%s: missing (required %s on %s)' % (path, key, typ, st.name))
            continue
        if value[key] is None:
            if not optional:
                errs.append('%s.%s: null but not optional' % (path, key))
            continue
        if not type_ok(value[key], typ, structs, '%s.%s' % (path, key)):
            errs.append('%s.%s: %r is not %s' % (path, key, value[key] if not isinstance(value[key], (dict, list)) else type(value[key]).__name__, typ))
    return errs


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Client:
    def __init__(self, host):
        self.base = 'http://' + host if '://' not in host else host
        self.base = self.base.rstrip('/')

    def get(self, path, timeout=15, headers=None):
        req = urllib.request.Request(self.base + path, headers=headers or {})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()

    def json(self, path, timeout=20):
        status, _, body = self.get(path, timeout=timeout)
        if status != 200:
            raise RuntimeError('%s -> %s' % (path, status))
        return json.loads(body.decode('utf-8'))

    def cmd(self, path, timeout=20):
        status, _, body = self.get(path, timeout=timeout)
        if status != 200:
            raise RuntimeError('%s -> %s' % (path, status))
        try:
            return json.loads(body.decode('utf-8'))
        except Exception:
            return {'ok': True}


def q(**kw):
    return '?' + urllib.parse.urlencode(kw)


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
def check_payload(c, structs, label, path, struct_name):
    try:
        data = c.json(path)
    except Exception as e:
        bad(label, 'request failed: %s' % e)
        return None
    errs = validate(data, structs[struct_name], structs, path)
    if errs:
        bad(label, '%d field problem(s): %s' % (len(errs), ' | '.join(errs[:6])))
        return data
    ok(label, '%d bytes' % len(json.dumps(data)))
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='127.0.0.1:3690')
    ap.add_argument('--report', default=os.path.join(ROOT, 'ios', 'dist', 'contract-report.json'))
    args = ap.parse_args()

    structs = read_structs()
    need = ['PlayerState', 'LibraryResponse', 'PlaylistsResponse', 'Track',
            'PlaylistRow', 'LyricsResponse', 'Theme', 'ThemesResponse', 'OKResponse']
    missing = [n for n in need if n not in structs]
    if missing:
        print('could not read Swift structs: %s' % ', '.join(missing))
        return 1
    c = Client(args.host)

    print('\n== bridge reachable')
    try:
        state = c.json('/state')
        ok('GET /state')
    except Exception as e:
        print('  FAIL the bridge is not answering at %s (%s)' % (c.base, e))
        return 1

    print('\n== payload contracts (the Swift models decode these)')
    state = check_payload(c, structs, 'GET /state -> PlayerState', '/state', 'PlayerState')
    lib = check_payload(c, structs, 'GET /library -> LibraryResponse', '/library', 'LibraryResponse')
    rooms = check_payload(c, structs, 'GET /playlists -> PlaylistsResponse', '/playlists', 'PlaylistsResponse')
    scoped = check_payload(c, structs, 'GET /library?scope=playlist', '/library?scope=playlist', 'LibraryResponse')
    themes = check_payload(c, structs, 'GET /themes -> ThemesResponse', '/themes', 'ThemesResponse')
    cur = check_payload(c, structs, 'GET /theme/current -> Theme', '/theme/current', 'Theme')

    if lib and lib.get('tracks'):
        biggest = max(lib['tracks'], key=lambda t: t.get('duration_ms') or 0)
        tid = biggest['id']
        check_payload(c, structs, 'GET /lyrics?id=%d -> LyricsResponse' % tid,
                      '/lyrics?id=%d' % tid, 'LyricsResponse')

    if themes:
        for name in themes.get('themes', [])[:6]:
            check_payload(c, structs, 'GET /theme?name=%s -> Theme' % name,
                          '/theme' + q(name=name, preview=1), 'Theme')

    print('\n== artwork the phone proxies through /cover')
    covers = []
    for t in (lib or {}).get('tracks', []):
        cv = (t.get('cover') or '').strip()
        if cv and cv.lower().startswith('file:'):
            covers.append((t.get('title', '?'), cv))
        if len(covers) >= 6:
            break
    if not covers:
        bad('covers present', 'no track has a file cover')
    for title, cv in covers:
        path = urllib.parse.unquote(cv[5:])
        if path.startswith('///'):
            path = path[2:]
        path = path.replace('\\', '/')
        if path.startswith('/') and len(path) > 2 and path[2] == ':':
            path = path[1:]
        try:
            status, headers, body = c.get('/cover' + q(path=path))
            head = body[:12]
            image = head.startswith(b'\x89PNG') or head.startswith(b'\xff\xd8') or head.startswith(b'GIF8') or (head[:4] == b'RIFF' and body[8:12] == b'WEBP')
            if status == 200 and image:
                ok('cover %s' % title[:28], '%s %d bytes %s' % (path.rsplit('/', 1)[-1], len(body), headers.get('Content-Type', '?')))
            else:
                bad('cover %s' % title[:28], 'status %s, image=%s, first bytes=%r' % (status, image, head))
        except Exception as e:
            bad('cover %s' % title[:28], str(e))

    print('\n== audio the phone streams (byte ranges)')
    local = [t for t in (lib or {}).get('tracks', []) if (t.get('path') or '') and t.get('duration_ms')]
    if not local:
        bad('streamable rows', 'no row has a path + duration')
    for t in local[:3]:
        tid, title = t['id'], t.get('title', '?')[:28]
        try:
            status, headers, _ = c.get('/audio' + q(id=tid), headers={'Range': 'bytes=0-65535'})
            ctype = headers.get('Content-Type', '')
            crange = headers.get('Content-Range', '')
            if status == 206 and ctype.startswith('audio/') and crange:
                ok('range stream %s' % title, '206 %s %s' % (ctype, crange))
            else:
                bad('range stream %s' % title, 'status %s, type %r, range %r' % (status, ctype, crange))
        except Exception as e:
            bad('range stream %s' % title, str(e))
        try:
            status, headers, _ = c.get('/audio' + q(id=tid))
            if status == 200 and headers.get('Content-Type', '').startswith('audio/'):
                ok('full stream %s' % title, '200 %s %d bytes' % (headers.get('Content-Type'), int(headers.get('Content-Length', 0))))
            else:
                bad('full stream %s' % title, 'status %s type %r' % (status, headers.get('Content-Type')))
        except Exception as e:
            bad('full stream %s' % title, str(e))

    print('\n== transport commands (restored afterwards)')
    before = state or c.json('/state')
    pos, vol, playing = before.get('position_ms', 0), before.get('volume', 70), before.get('playing', False)
    for label, path in [
        ('/toggle', '/toggle'),
        ('/toggle (restore)', '/toggle'),
        ('/seek', '/seek' + q(ms=max(0, pos - 5000))),
        ('/volume', '/volume' + q(v=min(100, max(0, vol - 1)))),
        ('/volume (restore)', '/volume' + q(v=vol)),
    ]:
        try:
            r = c.cmd(path)
            if r.get('ok', True) is not False and not r.get('error'):
                ok(label)
            else:
                bad(label, json.dumps(r)[:160])
        except Exception as e:
            bad(label, str(e))
    try:
        c.cmd('/seek' + q(ms=pos))
        ok('/seek (restore)', '%d ms' % pos)
    except Exception as e:
        bad('/seek (restore)', str(e))

    print('\n== queue')
    cur_id = (c.json('/state') or {}).get('track_id')
    for label, path in [('/next', '/next'), ('/prev', '/prev')]:
        try:
            r = c.cmd(path)
            (ok if r.get('ok', True) is not False else bad)(label, json.dumps(r)[:90])
        except Exception as e:
            bad(label, str(e))
    if cur_id is not None:
        try:
            r = c.cmd('/play' + q(id=cur_id))
            (ok if not r.get('error') else bad)('/play current row', json.dumps(r)[:90])
        except Exception as e:
            bad('/play current row', str(e))
    if not playing:
        try:
            c.cmd('/pause')
            ok('left paused as found')
        except Exception:
            pass

    print('\n== a temporary room, end to end (removed afterwards)')
    active = before.get('playlist_file') or (scoped or {}).get('playlist_file')
    tmp_name = 'aether-contract-%d' % os.getpid()
    tmp_file = None
    try:
        r = c.cmd('/playlist/new' + q(name=tmp_name))
        tmp_file = r.get('file') or r.get('id')
        if tmp_file:
            ok('create room', str(tmp_file)[-40:])
        else:
            bad('create room', json.dumps(r)[:160])
        if tmp_file:
            r = c.cmd('/playlist/switch' + q(id=tmp_file))
            (ok if not r.get('error') else bad)('switch to it', json.dumps(r)[:80])
            empty = c.json('/library?scope=playlist')
            if empty.get('total') == 0:
                ok('a new room is empty', 'total=0')
            else:
                bad('a new room is empty', 'total=%s (scope leaks the vault)' % empty.get('total'))
            if local:
                tid = local[0]['id']
                r = c.cmd('/playlist/append' + q(pl=tmp_file, id=tid))
                (ok if not r.get('error') else bad)('append a row', json.dumps(r)[:80])
                after = c.json('/library?scope=playlist')
                if after.get('total') == 1:
                    ok('append lands in the room', 'total=1')
                else:
                    bad('append lands in the room', 'total=%s' % after.get('total'))
                r = c.cmd('/playlist/remove' + q(id=after['tracks'][0]['id']))
                (ok if not r.get('error') else bad)('remove a row', json.dumps(r)[:80])
                after = c.json('/library?scope=playlist')
                if after.get('total') == 0:
                    ok('remove empties the room', 'total=0')
                else:
                    bad('remove empties the room', 'total=%s' % after.get('total'))
    except Exception as e:
        bad('temporary room', str(e))
    finally:
        if active:
            try:
                c.cmd('/playlist/switch' + q(id=active))
                back = c.json('/library')
                if back.get('playlist_file') == active or back.get('total', 0) > 0:
                    ok('switched back to the real room', str(back.get('playlist_name')))
                else:
                    bad('switched back to the real room', json.dumps(back)[:120])
            except Exception as e:
                bad('switched back to the real room', str(e))
        if tmp_file:
            p = tmp_file if str(tmp_file).endswith('.json') else str(tmp_file) + '.json'
            p = p.replace('/', os.sep)
            try:
                if os.path.isfile(p):
                    os.remove(p)
                    ok('temp room file removed', p)
            except Exception as e:
                bad('temp room file removed', str(e))

    print('\n%d checks passed, %d failed' % (PASS, len(FAIL)))
    os.makedirs(os.path.dirname(args.report), exist_ok=True)
    with open(args.report, 'w', encoding='utf-8') as f:
        json.dump({'passed': PASS, 'failed': FAIL, 'host': c.base}, f, indent=2)
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
