#!/usr/bin/env python3
"""
lspeer — a minimal LocalSend v2 peer for testing LanShare from a PC.

Stdlib only. Speaks plain HTTP (like LanShare M1). Subcommands:

  discover               announce over multicast and list peers that answer
  serve                  act as a receiver (multicast + REST), save files to --out
  send IP FILE...        send files to a peer (register -> prepare-upload -> upload)
  scenarios IP           scripted M1 checks against a LanShare receiver

Examples:
  python3 tools/lspeer.py discover
  python3 tools/lspeer.py serve --out /tmp/inbox --pin 1234
  python3 tools/lspeer.py send 192.168.0.23 photo.jpg notes.txt
  python3 tools/lspeer.py scenarios 192.168.0.23
"""
import argparse
import hashlib
import http.client
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GROUP = '224.0.0.167'
PORT = 53317
API = '/api/localsend/v2'
FINGERPRINT = uuid.uuid4().hex.upper()
CLIENT_CERT = None  # (cert.pem, key.pem): official clients >= 2.2 demand a client cert over HTTPS


def log(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


def lan_ip():
    """Best-effort LAN IPv4, skipping docker bridges and proxy TUN devices."""
    try:
        out = subprocess.run(['ip', '-4', '-o', 'addr'], capture_output=True, text=True).stdout
        for line in out.splitlines():
            parts = line.split()
            ifname, addr = parts[1], parts[3].split('/')[0]
            if ifname == 'lo' or ifname.startswith(('docker', 'br-', 'veth', 'tun', 'Mihomo', 'utun')):
                continue
            if addr.startswith(('127.', '172.17.', '198.18.')):
                continue
            return addr
    except (OSError, IndexError):
        pass
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('192.168.0.1', 9))
        return s.getsockname()[0]
    finally:
        s.close()


def identity(alias, port, announce=None):
    info = {
        'alias': alias,
        'version': '2.1',
        'deviceModel': 'lspeer',
        'deviceType': 'headless',
        'fingerprint': FINGERPRINT,
        'port': port,
        'protocol': 'http',
        'download': False,
    }
    if announce is not None:
        info['announce'] = announce
    return info


# ---------------------------------------------------------------- multicast

def multicast_socket(bind_ip):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, 'SO_REUSEPORT'):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(('', PORT))
    mreq = struct.pack('4s4s', socket.inet_aton(GROUP), socket.inet_aton(bind_ip))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(bind_ip))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    return sock


def announce(sock, alias, port, flag=True):
    data = json.dumps(identity(alias, port, announce=flag)).encode()
    sock.sendto(data, (GROUP, PORT))


def listen_multicast(sock, alias, port, on_peer, reply):
    while True:
        data, (ip, _) = sock.recvfrom(65535)
        try:
            msg = json.loads(data)
        except ValueError:
            continue
        if msg.get('fingerprint') == FINGERPRINT:
            continue
        on_peer(ip, msg)
        if reply and (msg.get('announce') or msg.get('announcement')):
            # Spec: answer via POST /register, fall back to a multicast reply.
            peer_port = msg.get('port', PORT)
            scheme = msg.get('protocol', 'http')
            try:
                request(ip, peer_port, 'POST', f'{API}/register', identity(alias, port), scheme=scheme, timeout=2)
            except OSError:
                announce(sock, alias, port, flag=False)


# ---------------------------------------------------------------- http client

def request(ip, port, method, path, body=None, scheme='http', timeout=10, raw=None):
    """Returns (status, parsed-json-or-text)."""
    if scheme == 'https':
        import ssl
        ctx = ssl._create_unverified_context()
        if CLIENT_CERT:
            ctx.load_cert_chain(*CLIENT_CERT)
        conn = http.client.HTTPSConnection(ip, port, timeout=timeout, context=ctx)
    else:
        conn = http.client.HTTPConnection(ip, port, timeout=timeout)
    try:
        headers = {}
        payload = None
        if raw is not None:
            payload = raw
            headers['Content-Type'] = 'application/octet-stream'
        elif body is not None:
            payload = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        text = resp.read().decode(errors='replace')
        try:
            return resp.status, json.loads(text) if text else None
        except ValueError:
            return resp.status, text
    finally:
        conn.close()


def file_entry(path):
    with open(path, 'rb') as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    return {
        'id': uuid.uuid4().hex,
        'fileName': os.path.basename(path),
        'size': os.path.getsize(path),
        'fileType': 'application/octet-stream',
        'sha256': digest,
    }


def prepare(ip, port, alias, files, pin=None, timeout=120, scheme='http'):
    path = f'{API}/prepare-upload'
    if pin:
        path += '?pin=' + urllib.parse.quote(pin)
    body = {'info': identity(alias, PORT), 'files': {f['id']: f for f in files}}
    return request(ip, port, 'POST', path, body, timeout=timeout, scheme=scheme)


def upload(ip, port, session_id, file_id, token, data, scheme='http'):
    q = urllib.parse.urlencode({'sessionId': session_id, 'fileId': file_id, 'token': token})
    return request(ip, port, 'POST', f'{API}/upload?{q}', raw=data, timeout=300, scheme=scheme)


# ---------------------------------------------------------------- receiver

class Receiver:
    def __init__(self, out_dir, pin, mode):
        self.out_dir = out_dir
        self.pin = pin
        self.mode = mode  # accept | decline | busy
        self.lock = threading.Lock()
        self.session = None  # {'id', 'ip', 'files': {id: (meta, token)}}
        self.pin_failures = {}


def make_handler(rx, alias, port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            log(f'{self.client_address[0]} {fmt % args}')

        def reply(self, status, payload=None):
            body = b'' if payload is None else json.dumps(payload).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def body(self):
            # The official clients stream uploads with chunked transfer encoding
            # (no Content-Length), so both framings must be handled.
            if 'chunked' in (self.headers.get('Transfer-Encoding') or '').lower():
                parts = []
                while True:
                    size_line = self.rfile.readline()
                    if not size_line:
                        break
                    size = int(size_line.split(b';', 1)[0].strip() or b'0', 16)
                    if size == 0:
                        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                            pass  # discard trailers
                        break
                    parts.append(self.rfile.read(size))
                    self.rfile.readline()  # CRLF after each chunk
                return b''.join(parts)
            length = int(self.headers.get('Content-Length') or 0)
            return self.rfile.read(length) if length else b''

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            if url.path in (f'{API}/info', '/api/localsend/v1/info'):
                return self.reply(200, identity(alias, port))
            self.reply(404)

        def do_POST(self):
            url = urllib.parse.urlparse(self.path)
            q = dict(urllib.parse.parse_qsl(url.query))
            ip = self.client_address[0]
            raw = self.body()
            if url.path == f'{API}/register':
                peer = json.loads(raw or b'{}')
                log(f'register from {peer.get("alias")} ({ip}) protocol={peer.get("protocol")}')
                return self.reply(200, {k: v for k, v in identity(alias, port).items()
                                        if k not in ('port', 'protocol')})
            if url.path == f'{API}/prepare-upload':
                return self.prepare(ip, q, raw)
            if url.path == f'{API}/upload':
                return self.upload(ip, q, raw)
            if url.path == f'{API}/cancel':
                with rx.lock:
                    if rx.session and rx.session['id'] == q.get('sessionId'):
                        log(f'session {rx.session["id"]} cancelled by sender')
                        rx.session = None
                return self.reply(200)
            self.reply(404)

        def prepare(self, ip, q, raw):
            if rx.pin and q.get('pin') != rx.pin:
                n = rx.pin_failures.get(ip, 0) + 1
                rx.pin_failures[ip] = n
                log(f'bad PIN #{n} from {ip}')
                return self.reply(429 if n >= 3 else 401)
            rx.pin_failures.pop(ip, None)
            req = json.loads(raw)
            files = req['files']
            log(f'prepare-upload from {req["info"].get("alias")}: '
                + ', '.join(f'{f["fileName"]} ({f["size"]} B)' for f in files.values()))
            with rx.lock:
                if rx.mode == 'busy' or rx.session is not None:
                    return self.reply(409)
                if rx.mode == 'decline':
                    return self.reply(403)
                sid = uuid.uuid4().hex
                rx.session = {'id': sid, 'ip': ip,
                              'files': {fid: (f, uuid.uuid4().hex) for fid, f in files.items()},
                              'done': set()}
                tokens = {fid: tok for fid, (_, tok) in rx.session['files'].items()}
            return self.reply(200, {'sessionId': sid, 'files': tokens})

        def upload(self, ip, q, raw):
            with rx.lock:
                s = rx.session
                if s is None:
                    return self.reply(409)
                if s['ip'] != ip or s['id'] != q.get('sessionId'):
                    return self.reply(403)
                entry = s['files'].get(q.get('fileId'))
                if entry is None or entry[1] != q.get('token'):
                    return self.reply(403)
                meta = entry[0]
            target = os.path.join(rx.out_dir, os.path.basename(meta['fileName']))
            with open(target, 'wb') as f:
                f.write(raw)
            ok = len(raw) == meta['size']
            want = meta.get('sha256') or meta.get('hash')
            if want:
                ok = ok and hashlib.sha256(raw).hexdigest().lower() == want.lower()
            log(f'received {meta["fileName"]} -> {target} ({len(raw)} B) {"OK" if ok else "MISMATCH"}')
            if not ok:
                log(f'  expected {meta["size"]} B; Content-Length={self.headers.get("Content-Length")} '
                    f'Transfer-Encoding={self.headers.get("Transfer-Encoding")}')
            with rx.lock:
                if rx.session is s:
                    s['done'].add(q.get('fileId'))
                    if len(s['done']) == len(s['files']):
                        log(f'session {s["id"]} complete')
                        rx.session = None
            # Don't let the sender believe a truncated file arrived intact.
            self.reply(200 if ok else 500)

    return Handler


# ---------------------------------------------------------------- commands

def cmd_discover(args):
    bind_ip = args.bind or lan_ip()
    sock = multicast_socket(bind_ip)
    seen = {}

    def on_peer(ip, msg):
        key = msg.get('fingerprint', '').upper()
        if key not in seen:
            seen[key] = msg
            log(f'found {msg.get("alias")!r} {ip}:{msg.get("port", PORT)} '
                f'protocol={msg.get("protocol", "?")} model={msg.get("deviceModel")} type={msg.get("deviceType")}')

    threading.Thread(target=listen_multicast, args=(sock, args.alias, PORT, on_peer, False),
                     daemon=True).start()
    log(f'announcing from {bind_ip} as {args.alias!r} (fingerprint {FINGERPRINT[:8]}…)')
    for delay in (0.1, 0.5, 2.0):
        time.sleep(delay)
        announce(sock, args.alias, PORT)
    time.sleep(args.wait)
    if not seen:
        log('no peers answered over multicast (try `serve` and refresh on the phone, '
            'or check that the Wi-Fi does not isolate clients)')


def cmd_serve(args):
    os.makedirs(args.out, exist_ok=True)
    bind_ip = args.bind or lan_ip()
    rx = Receiver(args.out, args.pin, args.mode)
    server = ThreadingHTTPServer(('0.0.0.0', args.port), make_handler(rx, args.alias, args.port))
    sock = multicast_socket(bind_ip)

    def on_peer(ip, msg):
        log(f'announcement from {msg.get("alias")!r} {ip} protocol={msg.get("protocol")}')

    threading.Thread(target=listen_multicast, args=(sock, args.alias, args.port, on_peer, True),
                     daemon=True).start()
    for delay in (0.1, 0.5, 2.0):
        time.sleep(delay)
        announce(sock, args.alias, args.port)
    log(f'serving {args.alias!r} on http://{bind_ip}:{args.port} mode={args.mode} '
        f'pin={"on" if args.pin else "off"} -> {args.out}')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


def cmd_send(args):
    # Official clients default to HTTPS (self-signed); 'auto' tries it first, then HTTP.
    schemes = ['https', 'http'] if args.scheme == 'auto' else [args.scheme]
    for scheme in schemes:
        try:
            status, info = request(args.ip, args.port, 'POST', f'{API}/register',
                                   identity(args.alias, PORT), scheme=scheme, timeout=5)
            break
        except (OSError, http.client.HTTPException) as e:
            log(f'register over {scheme} failed: {e}')
    else:
        return 1
    log(f'register ({scheme}) -> {status} {info}')
    files = [file_entry(p) for p in args.files]
    by_id = {f['id']: p for f, p in zip(files, args.files)}
    log('prepare-upload (accept on the phone)…')
    status, resp = prepare(args.ip, args.port, args.alias, files, args.pin, scheme=scheme)
    log(f'prepare-upload -> {status} {resp}')
    if status != 200:
        return 1
    sid = resp['sessionId']
    for fid, token in resp['files'].items():
        if args.cancel_after is not None and args.cancel_after == 0:
            log(f'cancel -> {request(args.ip, args.port, "POST", f"{API}/cancel?sessionId={sid}", scheme=scheme)[0]}')
            return 0
        with open(by_id[fid], 'rb') as f:
            data = f.read()
        status, _ = upload(args.ip, args.port, sid, fid, token, data, scheme=scheme)
        log(f'upload {os.path.basename(by_id[fid])} ({len(data)} B) -> {status}')
        if args.cancel_after is not None:
            args.cancel_after -= 1
    return 0


def cmd_scenarios(args):
    """Scripted checks. Some steps need a tap on the phone; prompts say which."""
    ip, port, alias = args.ip, args.port, args.alias
    results = []

    def check(name, cond, detail=''):
        results.append((name, cond))
        log(f'{"PASS" if cond else "FAIL"}  {name} {detail}')

    def small(name='hello.txt', size=None):
        data = os.urandom(size) if size else f'LanShare test {time.time()}\n'.encode()
        f = {'id': uuid.uuid4().hex, 'fileName': name, 'size': len(data),
             'fileType': 'text/plain', 'sha256': hashlib.sha256(data).hexdigest()}
        return f, data

    status, info = request(ip, port, 'GET', f'{API}/info', timeout=5)
    check('info reachable', status == 200 and isinstance(info, dict), f'{status} {info}')
    status, _ = request(ip, port, 'POST', f'{API}/register', identity(alias, PORT), timeout=5)
    check('register', status == 200)
    me = dict(identity(alias, PORT))
    me['fingerprint'] = info.get('fingerprint', '') if isinstance(info, dict) else ''
    status, _ = request(ip, port, 'POST', f'{API}/register', me, timeout=5)
    check('register with own fingerprint -> 412', status == 412, str(status))
    status, _ = request(ip, port, 'GET', '/nope', timeout=5)
    check('unknown route -> 404', status == 404, str(status))
    status, _ = request(ip, port, 'POST', f'{API}/upload?sessionId=x&fileId=y&token=z', raw=b'x', timeout=5)
    check('upload without session -> 409', status == 409, str(status))

    if args.pin:
        log(f'--- PIN: the phone must have PIN {args.pin!r} set')
        f, _ = small()
        codes = [prepare(ip, port, alias, [f], pin='0000' if args.pin != '0000' else '1111', timeout=10)[0]
                 for _ in range(3)]
        check('wrong PIN -> 401, 401, 429', codes == [401, 401, 429], str(codes))
        log('note: this IP is now rate-limited until it sends the right PIN')

    input('>>> Next: DECLINE the request on the phone. Press Enter to send it… ')
    f, _ = small()
    status, _ = prepare(ip, port, alias, [f], pin=args.pin)
    check('declined -> 403', status == 403, str(status))

    input('>>> Next: ACCEPT the request on the phone (save dialog may follow). Press Enter… ')
    f1, d1 = small('a.txt')
    f2, d2 = small('b.bin', 256 * 1024)
    result = {}
    t = threading.Thread(target=lambda: result.update(r=prepare(ip, port, alias, [f1, f2], pin=args.pin)))
    t.start()
    time.sleep(1.5)
    status, _ = prepare(ip, port, alias, [small()[0]], pin=args.pin, timeout=10)
    check('second request while prompting -> 409', status == 409, str(status))
    t.join()
    status, resp = result['r']
    check('accepted -> 200 with tokens', status == 200 and len(resp.get('files', {})) == 2, str(status))
    if status == 200:
        sid, tokens = resp['sessionId'], resp['files']
        status, _ = upload(ip, port, sid, f1['id'], 'bad-token', d1)
        check('bad token -> 403', status == 403, str(status))
        status, _ = upload(ip, port, sid, f1['id'], tokens[f1['id']], d1)
        check('upload a.txt -> 200', status == 200, str(status))
        status, _ = upload(ip, port, sid, f2['id'], tokens[f2['id']], d2)
        check('upload b.bin -> 200', status == 200, str(status))
        input('>>> Save the files on the phone, then press Enter… ')

    input('>>> Next: ACCEPT once more; the script will cancel mid-session. Press Enter… ')
    f1, d1 = small('c.txt')
    f2, _ = small('d.txt')
    status, resp = prepare(ip, port, alias, [f1, f2], pin=args.pin)
    if status == 200:
        sid = resp['sessionId']
        upload(ip, port, sid, f1['id'], resp['files'][f1['id']], d1)
        status, _ = request(ip, port, 'POST', f'{API}/cancel?sessionId={sid}')
        check('cancel -> 200', status == 200, str(status))
        status, _ = upload(ip, port, sid, f2['id'], resp['files'][f2['id']], b'late')
        check('upload after cancel -> 409', status == 409, str(status))
    else:
        check('accepted for cancel test', False, str(status))

    log('--- oversized: a 65 MB file must not be offered a token (no tap needed if only file)')
    big = {'id': uuid.uuid4().hex, 'fileName': 'big.bin', 'size': 65 * 1024 * 1024,
           'fileType': 'application/octet-stream'}
    status, _ = prepare(ip, port, alias, [big], pin=args.pin, timeout=10)
    check('only-oversized request -> 403', status == 403, str(status))

    passed = sum(1 for _, ok in results if ok)
    log(f'{passed}/{len(results)} checks passed')
    return 0 if passed == len(results) else 1


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--alias', default=f'lspeer-{socket.gethostname()}')
    p.add_argument('--bind', help='LAN IPv4 used for multicast (default: auto)')
    p.add_argument('--cert', help='client certificate PEM for HTTPS peers (fingerprint = its SHA-256)')
    p.add_argument('--key', help='private key PEM matching --cert')
    sub = p.add_subparsers(dest='cmd', required=True)

    d = sub.add_parser('discover')
    d.add_argument('--wait', type=float, default=5)

    s = sub.add_parser('serve')
    s.add_argument('--out', default='./lspeer-inbox')
    s.add_argument('--port', type=int, default=PORT)
    s.add_argument('--pin')
    s.add_argument('--mode', choices=['accept', 'decline', 'busy'], default='accept')

    t = sub.add_parser('send')
    t.add_argument('ip')
    t.add_argument('files', nargs='+')
    t.add_argument('--port', type=int, default=PORT)
    t.add_argument('--pin')
    t.add_argument('--cancel-after', type=int, help='cancel after uploading N files')
    t.add_argument('--scheme', choices=['auto', 'http', 'https'], default='auto',
                   help='auto: try https (official default, cert not verified) then http')

    c = sub.add_parser('scenarios')
    c.add_argument('ip')
    c.add_argument('--port', type=int, default=PORT)
    c.add_argument('--pin', help='PIN configured on the phone (enables the PIN checks)')

    args = p.parse_args()
    if args.cert:
        import ssl
        global CLIENT_CERT, FINGERPRINT
        CLIENT_CERT = (args.cert, args.key or args.cert)
        with open(args.cert) as f:
            FINGERPRINT = hashlib.sha256(ssl.PEM_cert_to_DER_cert(f.read())).hexdigest().upper()
    handler = {'discover': cmd_discover, 'serve': cmd_serve, 'send': cmd_send, 'scenarios': cmd_scenarios}
    sys.exit(handler[args.cmd](args) or 0)


if __name__ == '__main__':
    main()
