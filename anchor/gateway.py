#!/usr/bin/env python3
# GATEWAY / RESOLVER for Path A — the one new component that makes anchored names work in ANY browser.
#
# It sits behind a wildcard  *.xno.name  (a domain you own) under a wildcard TLS cert, and for each
# request  https://<label>.xno.name/...  it:
#     1. pulls <label> from the Host header, validates it,
#     2. resolves <label> -> anchor via the registry (signed leases),
#     3. resolves anchor -> its current record set via the anchor chain (anchor.resolve),
#     4. answers in one of three modes: REDIRECT, CONTENT (hash-verified), or PROFILE,
#     5. exposes /.well-known/anchor.json so an anchor-aware client can verify the identity trustlessly.
#
# TLS, wildcard DNS and ACME are DEPLOYMENT, not code (see the spec / README) — they can't be exercised
# without a real domain. This file is the resolution+routing logic, which is the actually-new part.
#
# Isolated: imports anchor.py (which imports xchat's xc_common READ-ONLY). Edits no xchat file.

import re, json, hashlib
import anchor as A

BASE = 'xno.name'                                   # the domain you own (placeholder)
LABEL_RE = re.compile(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$')   # LDH, ≤63 — a legal DNS label
RESERVED = {'www', 'api', 'app', 'mail', 'ns1', 'ns2', 'admin', 'static', 'cdn', '_acme-challenge'}


# ───────────────────────── registry: signed label → anchor leases ─────────────────────────
# A lease binds a human label to an anchor and is authorised by the anchor's ROOT key (pub↔anchor), so
# it survives operational-key rotation — whoever controls the anchor controls the name. Uniqueness is
# the registry's job: FIRST valid claim per label wins (squatting/recycling is Harberger's job, later).
def _lease_canon(l):
    return A.xc.sig_canon('anchor-lease', l['label'], l['anchor'], l['ts'])

def make_lease(label, anchor, root_priv, ts):
    l = {'label': label, 'anchor': anchor, 'ts': ts}
    d = dict(s.split(' ', 1) for s in A.xc._sign_lines(root_priv, _lease_canon(l)))
    l['sig'] = d['sig']; l['pub'] = d['pub']
    return l

def registry_resolve(leases, label, anchor_logs):
    """(anchor_id, record_set) for the label, or (None, None). Verifies the lease is root-authorised and
    the anchor chain is valid."""
    for l in sorted((x for x in leases if x.get('label') == label), key=lambda x: x['ts']):
        if A.xc.pub_to_addr(l.get('pub', '')) != l['anchor']:      # lease must be signed by the anchor root
            continue
        if not A.xc.verify_msg(l['pub'], _lease_canon(l), l['sig']):
            continue
        log = anchor_logs.get(l['anchor'])
        if not log:
            continue
        try:
            return l['anchor'], A.resolve(log)                    # anchor chain must validate too
        except A.Invalid:
            continue
    return None, None


# ───────────────────────── the request handler (pure function) ─────────────────────────
def _resp(status, ctype, body, headers=None):
    if isinstance(body, str):
        body = body.encode()
    h = {'Content-Type': ctype, 'Cache-Control': 'public, max-age=30'}
    h.update(headers or {})
    return {'status': status, 'headers': h, 'body': body}

def _label_of(host):
    host = (host or '').split(':')[0].lower().rstrip('.')
    if host == BASE:
        return ''                                                 # apex → landing
    if not host.endswith('.' + BASE):
        return None                                               # not our zone → reject
    sub = host[:-(len(BASE) + 1)]
    return sub if '.' not in sub else None                        # one level only (wildcard cert covers one)

def resolve_request(host, path, state):
    """state = {'leases':[...], 'anchors':{anchor_id:[events]}, 'blobs':{cid:bytes}}"""
    label = _label_of(host)
    if label is None:
        return _resp(421, 'text/plain', 'Misdirected request: unknown host')   # 421 = wrong authority
    if label == '':
        return _resp(200, 'text/html', '<h1>xno.name</h1><p>Claim a name.</p>')
    if label in RESERVED or not LABEL_RE.match(label):
        return _resp(404, 'text/plain', 'No such name')

    anchor, rec = registry_resolve(state['leases'], label, state['anchors'])
    if anchor is None:
        return _resp(404, 'text/html', _claim_page(label))        # available → claim CTA

    if path.split('?')[0] == '/.well-known/anchor.json':
        # The full proof: an anchor-aware client re-runs anchor.resolve(log) itself and trusts nothing here.
        doc = {'label': label, 'anchor': anchor, 'current_key': rec['current_key'],
               'seq': rec['seq'], 'endpoints': rec['endpoints'], 'log': state['anchors'][anchor]}
        return _resp(200, 'application/json', json.dumps(doc),
                     {'Access-Control-Allow-Origin': '*', 'Cache-Control': 'public, max-age=15'})

    # Anchor discovery headers ride on EVERY response (cheap; lets clients/extensions find the proof).
    hdr = {'X-Anchor': anchor, 'Link': '</.well-known/anchor.json>; rel="anchor"'}
    web = (rec['endpoints'] or {}).get('web', '')

    if web.startswith('redirect:'):                               # holder runs their own server → get out of the path
        return _resp(307, 'text/plain', '', {**hdr, 'Location': web[len('redirect:'):]})

    if web.startswith('content:'):                                # holder published signed static content
        cid = web[len('content:'):]
        blob = state['blobs'].get(cid)                            # in prod: fetch from relays (like Api.media)
        if blob is None or ('sha256-' + hashlib.sha256(blob).hexdigest()) != cid:
            return _resp(502, 'text/plain', 'Content unavailable or hash mismatch')
        return _resp(200, 'text/html', blob, {**hdr, 'X-Anchor-Content-Cid': cid})

    return _resp(200, 'text/html', _profile_page(label, anchor, rec), hdr)   # default canonical profile


# ───────────────────────── tiny page renderers (placeholders) ─────────────────────────
def _claim_page(label):
    return f'<!doctype html><meta charset=utf-8><title>{label}.{BASE} is available</title>' \
           f'<h1>{label}.{BASE}</h1><p>This name is unclaimed. <a href="/claim?label={label}">Claim it</a>.</p>'

def _profile_page(label, anchor, rec):
    ep = rec['endpoints'] or {}
    disp = ep.get('display', label)
    return f'<!doctype html><meta charset=utf-8><title>{disp}</title>' \
           f'<h1>{disp}</h1><p class=handle>{label}.{BASE}</p>' \
           f'<p class=xno>Pay: <code>{anchor}</code></p>' \
           f'<p class=verify>Verify this identity in an anchor-aware client via ' \
           f'<a href="/.well-known/anchor.json">/.well-known/anchor.json</a>.</p>'
