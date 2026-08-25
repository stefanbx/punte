#!/usr/bin/env python3
# End-to-end test for the personal content node, using a FAKE relay so it runs offline.
# Proves: host a blob -> it is fetchable by cid with a matching hash -> the node announced WHERE it is
# to the relay (the /provide heartbeat). Run: python3 node/test_xc_node.py
import base64, hashlib, json, os, socket, subprocess, sys, tempfile, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p


def get(url):
    return json.loads(urllib.request.urlopen(url, timeout=5).read())


def post(url, obj):
    req = urllib.request.Request(url, json.dumps(obj).encode(), {'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())


# --- a fake relay that just records the /provide announcements it receives ---
provides = []


class FakeRelay(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0) or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        if self.path.startswith('/provide'):
            provides.append(body)
        out = json.dumps({'ok': True}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(out))); self.end_headers()
        self.wfile.write(out)


def main():
    relay_port = free_port()
    node_port = free_port()
    relay = ThreadingHTTPServer(('127.0.0.1', relay_port), FakeRelay)
    threading.Thread(target=relay.serve_forever, daemon=True).start()

    store = tempfile.mkdtemp(prefix='xcnode-test-')
    public_port = free_port()
    admin_url = f'http://127.0.0.1:{node_port}'      # loopback admin: /host, /status
    public_url = f'http://127.0.0.1:{public_port}'   # public read-only: /blob (what others fetch)
    proc = subprocess.Popen(
        [sys.executable, os.path.join(HERE, 'xc_node.py'),
         '--port', str(node_port), '--public-port', str(public_port), '--bind', '127.0.0.1',
         '--public-url', public_url,
         '--relay', f'http://127.0.0.1:{relay_port}', '--store', store],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        # wait for the node to answer /status
        up = False
        for _ in range(50):
            try:
                st = get(admin_url + '/status'); up = True; break
            except Exception:
                time.sleep(0.1)
        assert up, 'node never came up'
        assert st['hosted'] == 0, f'fresh node should host nothing, got {st}'

        # 1. host content (via the loopback ADMIN server)
        payload = b'the bytes live on my machine, not the relay'
        want_cid = 'sha256-' + hashlib.sha256(payload).hexdigest()
        r = post(admin_url + '/host', {'b64': base64.b64encode(payload).decode()})
        assert r['cid'] == want_cid, f'cid mismatch: {r["cid"]} != {want_cid}'
        assert r['bytes'] == len(payload)
        assert r['announced_to'] == 1, f'should have announced to the 1 relay, got {r}'

        # 2. fetch it back by cid from the PUBLIC server and verify the hash (what any other browser does)
        b = get(public_url + '/blob?cid=' + want_cid)
        got = base64.b64decode(b['b64'])
        assert got == payload, 'bytes round-tripped wrong'
        assert 'sha256-' + hashlib.sha256(got).hexdigest() == want_cid, 'hash does not match cid'

        # 3. the node told the relay WHERE the bytes are, pointing at its PUBLIC /blob
        assert any(p.get('cid') == want_cid and p.get('url') == public_url + '/blob' for p in provides), \
            f'no matching /provide announcement seen: {provides}'

        # 4. status reflects the hosted blob
        st = get(admin_url + '/status')
        assert st['hosted'] == 1 and st['blob_url'] == public_url + '/blob', st

        # 5. SECURITY: the PUBLIC server must NOT expose admin routes (this is the tunnel-bypass fix —
        #    the tunnel forwards to the public server, so /host must be unreachable there).
        host_blocked = False
        try:
            post(public_url + '/host', {'b64': base64.b64encode(b'x').decode()})
        except urllib.error.HTTPError as e:
            host_blocked = (e.code == 404)
        assert host_blocked, 'PUBLIC server must reject /host (404) — else the tunnel bypass is open'
        hosted_blocked = False
        try:
            get(public_url + '/hosted')
        except urllib.error.HTTPError as e:
            hosted_blocked = (e.code == 404)
        assert hosted_blocked, 'PUBLIC server must not expose /hosted (catalogue enumeration)'

        # 6. an unknown cid 404s (not served, not forged)
        try:
            miss = get(public_url + '/blob?cid=sha256-' + '0' * 64)
            assert miss['b64'] is None, 'unknown cid should not return bytes'
        except urllib.error.HTTPError as e:
            assert e.code == 404

        print('NODE OK: hosted', want_cid[:20] + '...', '| public-served + hash-verified | admin /host blocked on public port | announced', public_url + '/blob')
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        relay.shutdown()


if __name__ == '__main__':
    main()
