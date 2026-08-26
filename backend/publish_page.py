#!/usr/bin/env python3
# Publish an Octad CONTENT PAGE as a Punte kind:'page' event (Level A of docs/OCTAD-CONTENT-PAGES.md:
# content-address the rendered zero-JS HTML + a signed page event). The phone never runs keel — this
# tool does the publish, off-device.
#
# Pipeline: (author -> keel render_html -> zero-JS HTML)  ->  THIS TOOL:
#   1. hash the HTML  -> html_cid = "sha256-<hex>"  (content integrity, like games/photo blobs)
#   2. sign a page event over sig_canon('post', handle, 'page', preview, ts)  (the SAME preimage
#      the app + xc_post.py use; `media` carries html_cid and is unsigned — integrity is the cid)
#   3. DRY-RUN (default): verify the signature locally (exactly xc_post.py's ingest check) and emit
#      the artifacts. No network, no key of yours touched — a throwaway TEST key is used.
#      --publish: pin the HTML blob to the relays and (documented) post the event on a real account.
#
# Run under the mesh venv (nanopy):  ~/.xchat-mesh-node/venv/bin/python backend/publish_page.py --help
import argparse, json, os, base64, hashlib, time, sys, re, urllib.request, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("xc_common", os.path.join(HERE, "xc_common.py"))
xc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(xc)

# The zero-JS invariant, enforced at publish time too (the app re-checks on render): a "page" that
# carries a <script>, a javascript: URL, or an inline on*= handler is NOT an Octad content page.
# Inline event handlers appear as ` onclick=` etc. — the \b keeps this from false-matching an
# innocent attribute like `content=` (the "on" inside "c-ontent" is not at a word boundary).
DANGER = re.compile(r'<script|javascript:|\bon\w+\s*=', re.I)


def build_event(html_bytes, handle, title, preview, seedbyte):
    if DANGER.search(html_bytes.decode('utf-8', 'ignore')):
        raise SystemExit("REFUSED: HTML is not zero-JS (contains <script / javascript: / on*=). "
                         "render_html never emits these — did you point at a game or hand-written HTML?")
    cid = 'sha256-' + hashlib.sha256(html_bytes).hexdigest()
    key = xc.keyof(seedbyte)                 # deterministic dev/test key (a single byte -> a key)
    addr, pub = xc.derive(key)
    ts = int(time.time())
    canon = xc.sig_canon('post', handle, 'page', preview, ts)   # media (cid) is intentionally NOT signed
    sig = next(l.split(' ', 1)[1] for l in xc._sign_lines(key, canon) if l.startswith('sig '))
    # verify EXACTLY as the relay ingest does (xc_post.py: pub_to_addr(pub)==acc AND verify_msg)
    ok = (xc.pub_to_addr(pub) == addr) and xc.verify_msg(pub, canon, sig)
    rec = {'id': 'u' + str(ts), 'handle': handle, 'account': addr, 'kind': 'page',
           'text': preview, 'title': title, 'ts': ts, 'media': cid, 'sig': sig, 'pub': pub}
    return cid, rec, ok, canon


def pin_blob(cid, html_bytes):
    b64 = base64.b64encode(html_bytes).decode()
    pinned = 0
    for r in xc.discover_relays():
        try:
            urllib.request.urlopen(urllib.request.Request(
                r + '/blob', json.dumps({'cid': cid, 'b64': b64}).encode(),
                {'Content-Type': 'application/json'}), timeout=15).read()
            pinned += 1
        except Exception:
            pass
    return pinned


def main():
    ap = argparse.ArgumentParser(description="Publish an Octad page as a Punte kind:'page' event (Level A).")
    ap.add_argument('--html', required=True, help='the rendered zero-JS HTML (from keel render_html)')
    ap.add_argument('--title', default='Page', help='feed-card + screen title')
    ap.add_argument('--preview', default='An Octad content page.', help='plain-text preview (this is what is SIGNED)')
    ap.add_argument('--handle', default='you.xno')
    ap.add_argument('--seedbyte', type=int, default=7, help='deterministic TEST publisher key (dry-run). '
                    'A real publish uses YOUR account key, which YOU supply — never pass your seed here in dry-run.')
    ap.add_argument('--out', default='/tmp/xc_page_event.json')
    ap.add_argument('--publish', action='store_true', help='pin the blob to the relays (LIVE). Off by default.')
    a = ap.parse_args()

    html = open(a.html, 'rb').read()
    cid, rec, ok, canon = build_event(html, a.handle, a.title, a.preview, a.seedbyte)

    print(json.dumps({'html_cid': cid, 'bytes': len(html), 'account': rec['account'],
                      'kind': 'page', 'sig_verifies': ok, 'signed_preimage': canon,
                      'dry_run': not a.publish}, indent=2))
    json.dump(rec, open(a.out, 'w'), indent=2)
    print('\nwrote signed page event ->', a.out)

    if not ok:
        raise SystemExit('SIGNATURE DID NOT VERIFY — aborting (this would be rejected by the relay).')

    if not a.publish:
        print("\nDRY-RUN ok: the page event is valid and would be accepted by xc_post.py's ingest.")
        print("To go LIVE: run with --publish (pins the HTML blob), and post the event on YOUR account")
        print("through the normal post pipeline (prepare -> sign head -> push) — see docs/OCTAD-CONTENT-PAGES.md.")
        return

    n = pin_blob(cid, html)
    print('\npinned HTML blob to %d relay(s) as %s' % (n, cid))
    print("Now post the page event (rec above) on YOUR account via the app's post flow / xc_post.py")
    print("(prepare -> head). The blob is content-addressed; the event's `media` points at it.")


if __name__ == '__main__':
    main()
