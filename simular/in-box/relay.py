#!/usr/bin/env python3
"""TCP relay: loopback:7844 -> HTTP CONNECT via box proxy -> Cloudflare edge.

Listens on 127.0.0.2:7844 (region1 pool) and 127.0.0.3:7844 (region2 pool).
For each accepted connection, picks the next real edge IP from the pool,
issues CONNECT ip:7844 to the proxy at 127.0.0.1:3128, then pipes bytes.
TLS stays end-to-end between cloudflared and the real edge.
"""
import socket
import sys
import threading

PROXY = ("127.0.0.1", 3128)
POOLS = {
    "127.0.0.2": ["198.41.192.67", "198.41.192.27", "198.41.192.57",
                  "198.41.192.77", "198.41.192.167", "198.41.192.227"],
    "127.0.0.3": ["198.41.200.73", "198.41.200.113", "198.41.200.63",
                  "198.41.200.33", "198.41.200.23", "198.41.200.13"],
}
counters = {k: 0 for k in POOLS}
lock = threading.Lock()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client, bind_ip):
    pool = POOLS[bind_ip]
    with lock:
        idx = counters[bind_ip]
        counters[bind_ip] += 1
    last_err = None
    for attempt in range(len(pool)):
        target = pool[(idx + attempt) % len(pool)]
        try:
            up = socket.create_connection(PROXY, timeout=10)
            up.settimeout(15)
            up.sendall(("CONNECT %s:7844 HTTP/1.1\r\nHost: %s:7844\r\n\r\n"
                        % (target, target)).encode())
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = up.recv(4096)
                if not chunk:
                    raise OSError("proxy closed during CONNECT")
                buf += chunk
            head, _, rest = buf.partition(b"\r\n\r\n")
            status = head.split(b"\r\n")[0].decode("ascii", "replace")
            if " 200 " not in status:
                raise OSError("CONNECT refused: " + status)
            up.settimeout(None)
            log("relay %s -> %s established (%s)" % (bind_ip, target, status))
            if rest:
                client.sendall(rest)
            t = threading.Thread(target=pipe, args=(up, client), daemon=True)
            t.start()
            pipe(client, up)
            t.join(timeout=5)
            try:
                up.close()
            except OSError:
                pass
            return
        except OSError as e:
            last_err = e
            log("relay %s -> %s failed: %s" % (bind_ip, target, e))
            try:
                up.close()
            except Exception:
                pass
    log("relay %s: all pool IPs failed, last: %s" % (bind_ip, last_err))
    client.close()


def serve(bind_ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((bind_ip, 7844))
    s.listen(50)
    log("relay listening on %s:7844" % bind_ip)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c, bind_ip), daemon=True).start()


for ip in POOLS:
    if ip != "127.0.0.2":
        threading.Thread(target=serve, args=(ip,), daemon=True).start()
serve("127.0.0.2")
