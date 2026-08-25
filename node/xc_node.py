#!/usr/bin/env python3
# xc_node.py — a PERSONAL CONTENT NODE for the sovereign web.
#
# The point of this program: your web pages, files and apps live on YOUR machine, not on a relay.
# A relay is demoted from HOST to NAMESERVER — it keeps the signed name->key->cid pointer and a hint
# of WHERE the bytes are, but the bytes themselves are served from here. That is what makes the stack
# a web you own rather than a service you rent: turn this off and only YOUR content goes dark.
#
# It works because content is address-by-hash. Every blob is named `sha256-<hex>` of its own bytes, so
# whoever fetches it re-computes that hash and refuses a mismatch. The fetcher therefore does not have
# to trust this node, the relay, or the network path — only the math. A relay (or an attacker) can hide
# bytes or serve garbage, but can never forge a page that verifies.
#
# What this node does:
#   * stores content blobs on local disk, addressed by cid           (~/.xchat-node/blobs/<cid>)
#   * serves  GET /blob?cid=<cid>   -> {"cid","b64"}   (SAME wire shape a relay serves, so a browser
#                                                        fetches from a node and a relay identically)
#   * heartbeats  POST /provide {cid,url}  to the relays every ~1 min, so the relay directory always
#                                          points at a node that is actually up (stale ones age out)
#   * admin API on loopback only:  POST /host  (add content),  GET /hosted,  GET /status
#
# It deliberately holds NO keys and signs NOTHING. Naming (the signed lease + anchor) is done by the
# signer that owns the seed — today the browser's publish flow, tomorrow an optional `--sign` mode here.
# Keeping bytes and keys in separate programs is the whole security story: a byte server that is broken
# into cannot forge your identity, and a lost node loses availability, never ownership.
#
# Run:
#   python3 node/xc_node.py --public-url https://my.example.com          # a reachable home server
#   python3 node/xc_node.py --serve-dir ~/site                           # host a folder, print its cids
#   python3 node/xc_node.py                                              # localhost only (same-machine)
#
# Stdlib only — no venv, no crypto deps. It can run on the smallest box you have.

import argparse, base64, hashlib, json, os, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DEFAULT_RELAYS = ['https://xchat-relay-1.fly.dev', 'https://xchat-alpha-node.fly.dev']
HEARTBEAT_S = 60                       # re-announce every minute; the relay's freshness window is 15 min
CID_PREFIX = 'sha256-'


def cid_of(data: bytes) -> str:
    # The exact content id the browser (cidOf) and publish_page.py compute, so a blob hosted here is
    # byte-for-byte the one a name's pointer names.
    return CID_PREFIX + hashlib.sha256(data).hexdigest()


class Store:
    # Content-addressed blob store on local disk. The filename IS the cid, so the store is self-verifying
    # and trivially inspectable — `ls ~/.xchat-node/blobs` is the list of everything you host.
    def __init__(self, root):
        self.root = os.path.expanduser(root)
        self.blobs = os.path.join(self.root, 'blobs')
        os.makedirs(self.blobs, exist_ok=True)
        self._lock = threading.Lock()

    def _path(self, cid):
        # cids are `sha256-<64 hex>` — no path separators possible, but pin it to the blobs dir anyway.
        if not cid.startswith(CID_PREFIX) or not cid[len(CID_PREFIX):].isalnum():
            return None
        return os.path.join(self.blobs, cid)

    def put(self, data: bytes) -> str:
        cid = cid_of(data)
        p = self._path(cid)
        with self._lock:
            if not os.path.exists(p):
                tmp = p + '.tmp'
                with open(tmp, 'wb') as f:
                    f.write(data)
                os.replace(tmp, p)          # atomic: a reader never sees a half-written blob
        return cid

    def get(self, cid) -> bytes | None:
        p = self._path(cid)
        if not p or not os.path.exists(p):
            return None
        with open(p, 'rb') as f:
            return f.read()

    def has(self, cid) -> bool:
        p = self._path(cid)
        return bool(p) and os.path.exists(p)

    def cids(self):
        with self._lock:
            return sorted(n for n in os.listdir(self.blobs) if n.startswith(CID_PREFIX) and not n.endswith('.tmp'))

    def size(self, cid):
        p = self._path(cid)
        return os.path.getsize(p) if p and os.path.exists(p) else 0


class Node:
    def __init__(self, store, public_url, relays):
        self.store = store
        self.public_url = public_url.rstrip('/')
        self.relays = relays
        self.mesh = None                 # set in --tunnel mode (an xc_tunnel.MeshClient)
        self._stop = threading.Event()

    def blob_url(self):
        return self.public_url + '/blob'

    def provider_blob_urls(self):
        # WHERE other people can fetch our /blob. In TUNNEL mode this is our current reach URLs through
        # the public entry relays — they rotate each epoch, so we recompute them every heartbeat, and we
        # deliberately do NOT advertise our loopback URL (a remote browser would resolve 127.0.0.1 to ITS
        # OWN machine). Without a tunnel it is just our own public URL.
        if self.mesh is not None:
            return [u + '/blob' for u in self.mesh.current_reach_urls()]
        return [self.blob_url()]

    # --- provider heartbeat: tell the relays WHERE these bytes are, repeatedly, so the directory only
    #     ever points at a node that is currently up (and, in tunnel mode, at a token that is still live)
    def _provide(self, cid, url):
        body = json.dumps({'cid': cid, 'url': url}).encode()
        ok = 0
        for r in self.relays:
            try:
                req = urllib.request.Request(r + '/provide', body, {'Content-Type': 'application/json'})
                urllib.request.urlopen(req, timeout=10).read()
                ok += 1
            except Exception:
                pass
        return ok

    def announce(self, cid):
        # register this one cid at every current provider URL (used right after /host)
        urls = self.provider_blob_urls()
        for u in urls:
            self._provide(cid, u)
        return len(urls)

    def heartbeat_loop(self):
        while not self._stop.is_set():
            urls = self.provider_blob_urls()
            if urls:
                cids = self.store.cids()
                for c in cids:
                    for u in urls:
                        self._provide(c, u)
                print(f'[heartbeat] announced {len(cids)} blob(s) at {len(urls)} url(s): '
                      f'{", ".join(urls)}', flush=True)
                self._stop.wait(HEARTBEAT_S)
            else:
                # tunnel mode, not yet connected to an entry — retry soon so we advertise as fast as we can
                print('[heartbeat] waiting for a tunnel entry…', flush=True)
                self._stop.wait(5)

    def stop(self):
        self._stop.set()
        if self.mesh is not None:
            try:
                self.mesh.stop()
            except Exception:
                pass


def make_handler(node: Node, admin=False):
    # admin=True: the loopback-only server the OWNER's browser uses (has /host, /hosted). admin=False: the
    # PUBLIC/tunnel-facing server — /blob + /status ONLY. Splitting them is what closes the tunnel bypass:
    # the mesh tunnel forwards to the PUBLIC server (no /host), so a remote caller can never reach an admin
    # route even though the tunnel dispatches over a loopback socket. is_loopback stays as defence in depth.
    def is_loopback(addr):
        return addr[0] in ('127.0.0.1', '::1', '::ffff:127.0.0.1')

    class H(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *a):        # quiet; heartbeat prints what matters
            pass

        def _send(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            # a browser on any origin fetches bytes here and verifies the hash itself — CORS-open is safe
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlparse(self.path).path
            q = parse_qs(urlparse(self.path).query)
            if path == '/blob':
                # PUBLIC: serve content bytes by cid, base64 in JSON — the exact shape a relay's /blob
                # returns, so a fetcher treats a node and a relay as interchangeable sources.
                cid = (q.get('cid') or [''])[0]
                data = node.store.get(cid)
                if data is None:
                    self._send(404, {'cid': cid, 'b64': None, 'error': 'not hosted here'})
                else:
                    self._send(200, {'cid': cid, 'b64': base64.b64encode(data).decode()})
            elif path == '/status':
                cids = node.store.cids()
                self._send(200, {'node': 'xc_node', 'public_url': node.public_url,
                                 'blob_url': node.blob_url(), 'relays': node.relays,
                                 'hosted': len(cids), 'heartbeat_s': HEARTBEAT_S,
                                 'tunnel': node.mesh is not None,
                                 'reach': node.provider_blob_urls()})
            elif path == '/hosted' and admin:
                # ADMIN-ONLY: the full catalogue. Public callers must not enumerate everything one node
                # hosts (that correlates an owner's whole catalogue under one identity).
                cids = node.store.cids()
                self._send(200, {'hosted': [{'cid': c, 'size': node.store.size(c)} for c in cids]})
            else:
                self._send(404, {'error': 'unknown route'})

        def do_POST(self):
            path = urlparse(self.path).path
            if not admin:
                # the public/tunnel server exposes NO mutating routes at all
                self._send(404, {'error': 'unknown route'})
                return
            if not is_loopback(self.client_address):
                # /host mutates what this machine serves — only the machine's owner (loopback) may call it.
                self._send(403, {'error': 'admin routes are loopback-only'})
                return
            n = int(self.headers.get('Content-Length', 0) or 0)
            raw = self.rfile.read(n) if n else b''
            if path == '/host':
                # ADMIN: add content to host. Body is either {"b64": "..."} (raw bytes) or {"path": "..."}
                # (read a local file). Returns the cid + the announce result. This is what the browser's
                # "keep on my machine" publish calls before it signs the pointer.
                try:
                    m = json.loads(raw or '{}')
                except Exception as e:
                    self._send(400, {'error': f'bad json: {e}'})
                    return
                if 'b64' in m:
                    try:
                        data = base64.b64decode(m['b64'])
                    except Exception as e:
                        self._send(400, {'error': f'bad b64: {e}'})
                        return
                elif 'path' in m:
                    p = os.path.expanduser(m['path'])
                    if not os.path.isfile(p):
                        self._send(400, {'error': f'no such file: {p}'})
                        return
                    with open(p, 'rb') as f:
                        data = f.read()
                else:
                    self._send(400, {'error': 'need "b64" or "path"'})
                    return
                cid = node.store.put(data)
                announced = node.announce(cid)     # register WHERE immediately, don't wait for the beat
                self._send(200, {'cid': cid, 'bytes': len(data), 'blob_url': node.blob_url(),
                                 'announced_to': announced})
            else:
                self._send(404, {'error': 'unknown route'})

    return H


# --- tunnel mode: make a NAT'd home node reachable through public entry relays, no static IP / no CA.
# This is the ONLY part that needs the crypto module (xc_common) + xc_tunnel from the repo, so it is
# loaded lazily and only when --tunnel is given. Run it under a venv that has nanopy + pynacl
# (e.g. ~/.xchat-mesh-node/venv/bin/python).
def _load_crypto_and_tunnel():
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    def _load(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m

    xc = _load('xc_common', os.path.join(root, 'backend', 'xc_common.py'))
    tun = _load('xc_tunnel', os.path.join(root, 'relay', 'xc_tunnel.py'))
    return xc, tun


def _rendezvous_secret(store):
    # A stable per-node secret that seeds our routing tokens. In PUBLIC mode the node trades anonymity for
    # zero-config reachability anyway, so this need only be stable, not shared — kept on disk beside blobs.
    p = os.path.join(store.root, 'tunnel_secret')
    if os.path.exists(p):
        with open(p) as f:
            return f.read().strip()
    import binascii
    s = binascii.hexlify(os.urandom(32)).decode()
    with open(p, 'w') as f:
        f.write(s)
    return s


def main():
    ap = argparse.ArgumentParser(description='Personal content node for the sovereign web.')
    ap.add_argument('--port', type=int, default=8791)
    ap.add_argument('--bind', default='0.0.0.0', help='0.0.0.0 to be reachable on the LAN; 127.0.0.1 for local-only')
    ap.add_argument('--store', default='~/.xchat-node', help='where blobs live on disk')
    ap.add_argument('--public-url', default=None,
                    help='the URL other people reach this node at (e.g. https://me.example.com). '
                         'Defaults to http://127.0.0.1:<port> — fine for same-machine, not reachable by others.')
    ap.add_argument('--relay', action='append', default=None,
                    help='relay to announce to (repeatable). Defaults to the two live relays.')
    ap.add_argument('--serve-dir', default=None,
                    help='host every file in this directory on startup and print each cid')
    ap.add_argument('--public-port', type=int, default=None,
                    help='port for the PUBLIC read-only server (/blob, /status) that the tunnel and remote/LAN '
                         'users reach. Defaults to <port>+1. The admin API (/host) is NEVER served here.')
    ap.add_argument('--tunnel', action='store_true',
                    help='become reachable from anywhere through the public entry relays (no static IP, '
                         'no CA). Requires nanopy + pynacl — run under the mesh venv. Announces the current '
                         'reach URLs as providers, so a remote browser fetches through an entry.')
    a = ap.parse_args()

    store = Store(a.store)
    public_port = a.public_port or (a.port + 1)
    # The provider URL other people fetch from is the PUBLIC server. Default it to loopback:public_port
    # (fine same-machine; set --public-url to a reachable address for LAN, or use --tunnel for anywhere).
    public_url = a.public_url or f'http://127.0.0.1:{public_port}'
    relays = a.relay or DEFAULT_RELAYS
    node = Node(store, public_url, relays)

    if a.tunnel:
        try:
            xc, tun = _load_crypto_and_tunnel()
        except Exception as e:
            raise SystemExit(f'--tunnel needs the crypto module (nanopy + pynacl). Run under the mesh venv, '
                             f'e.g. ~/.xchat-mesh-node/venv/bin/python node/xc_node.py --tunnel …\n  ({e})')
        secret = _rendezvous_secret(store)
        # The tunnel forwards to the PUBLIC server (no admin routes), so a request arriving over the tunnel
        # can never reach /host even though it is dispatched over a loopback socket. public=True lists this
        # node so any browser reaches it with no shared secret (trades node anonymity for reach).
        node.mesh = tun.MeshClient(xc, secret, f'http://127.0.0.1:{public_port}', entries=list(relays),
                                   self_url='', public=True,
                                   log=lambda m: print(f'[tunnel] {m}', flush=True))
        node.mesh.start()

    if a.serve_dir:
        d = os.path.expanduser(a.serve_dir)
        for name in sorted(os.listdir(d)):
            p = os.path.join(d, name)
            if os.path.isfile(p):
                with open(p, 'rb') as f:
                    cid = store.put(f.read())
                print(f'  hosting {name}  ->  {cid}')

    threading.Thread(target=node.heartbeat_loop, daemon=True).start()

    # PUBLIC server (read-only: /blob, /status) — bound to --bind so remote/LAN + the tunnel can reach it.
    public_srv = ThreadingHTTPServer((a.bind, public_port), make_handler(node, admin=False))
    threading.Thread(target=public_srv.serve_forever, daemon=True).start()
    # ADMIN server (/host, /hosted) — bound to LOOPBACK ONLY, for this machine's own browser. Never remote.
    admin_srv = ThreadingHTTPServer(('127.0.0.1', a.port), make_handler(node, admin=True))
    print(f'xc_node up — admin(loopback) 127.0.0.1:{a.port} · public {a.bind}:{public_port}  (provider: {public_url})', flush=True)
    print(f'  store:  {store.blobs}', flush=True)
    print(f'  relays: {", ".join(relays)}', flush=True)
    print(f'  tunnel: {"on (reachable from anywhere via entry relays)" if a.tunnel else "off (local/LAN only)"}', flush=True)
    print(f'  hosting {len(store.cids())} blob(s)', flush=True)
    try:
        admin_srv.serve_forever()
    except KeyboardInterrupt:
        node.stop()
        print('\nbye', flush=True)


if __name__ == '__main__':
    main()
