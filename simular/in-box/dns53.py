#!/usr/bin/env python3
"""Minimal DNS server on 127.0.0.1:53 (UDP+TCP) for the Simular Box pilot.

Upstream = DNS-over-HTTPS (cloudflare-dns.com JSON API) reached through the
box HTTP proxy at 127.0.0.1:3128 (hardcoded: the process runs under sudo and
must not depend on inherited env).

Special handling:
- A queries for region1/region2.v2.argotunnel.com: if /tmp/dns53-mode reads
  "relay", answer with loopback 127.0.0.2 / 127.0.0.3 (the CONNECT relay);
  otherwise fall through to DoH for real edge IPs.
- AAAA queries for the region names: NODATA (avoid IPv6 dial attempts).
Everything else is answered from DoH JSON, encoded as wire format.
"""
import json
import socket
import struct
import sys
import threading
import urllib.request

PROXY = "http://127.0.0.1:3128"
MODE_FILE = "/tmp/dns53-mode"
REGION_LOOPBACK = {
    "region1.v2.argotunnel.com": "127.0.0.2",
    "region2.v2.argotunnel.com": "127.0.0.3",
}
TMAP = {1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX",
        16: "TXT", 28: "AAAA", 33: "SRV", 65: "HTTPS", 64: "SVCB"}

opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))


def mode():
    try:
        with open(MODE_FILE) as f:
            return f.read().strip()
    except OSError:
        return "real"


def enc_name(name):
    out = b""
    for lab in name.rstrip(".").split("."):
        out += bytes([len(lab)]) + lab.encode()
    return out + b"\x00"


def parse_question(data):
    p = 12
    labels = []
    while True:
        ln = data[p]
        if ln == 0:
            p += 1
            break
        labels.append(data[p + 1:p + 1 + ln].decode("ascii", "replace"))
        p += 1 + ln
    qtype, qclass = struct.unpack(">HH", data[p:p + 4])
    return ".".join(labels), qtype, p + 4


def doh(name, qtype):
    t = TMAP.get(qtype)
    if not t:
        return None
    url = ("https://cloudflare-dns.com/dns-query?name="
           + urllib.request.quote(name) + "&type=" + t)
    req = urllib.request.Request(url, headers={"accept": "application/dns-json"})
    with opener.open(req, timeout=10) as r:
        return json.load(r)


def encode_rdata(ty, d):
    if ty == 1:
        return socket.inet_aton(d)
    if ty == 28:
        return socket.inet_pton(socket.AF_INET6, d)
    if ty in (2, 5, 12):
        return enc_name(d)
    if ty == 33:
        parts = d.rstrip(".").split()
        return (int(parts[0]).to_bytes(2, "big") + int(parts[1]).to_bytes(2, "big")
                + int(parts[2]).to_bytes(2, "big") + enc_name(parts[3]))
    if ty == 15:
        parts = d.split(None, 1)
        return int(parts[0]).to_bytes(2, "big") + enc_name(parts[1])
    # TXT and anything else: single character-string / raw text
    b = d.encode()
    if ty == 16:
        return bytes([min(len(b), 255)]) + b[:255]
    return b


def build_response(data):
    tid = data[:2]
    name, qtype, qend = parse_question(data)
    question = data[12:qend]
    answers = []
    authority = []
    status = 0
    lname = name.lower()
    if lname == "localhost":
        # cloudflared resolves its origin (http://localhost:8001) through this
        # server; public DNS rightly NXDOMAINs "localhost", so answer locally.
        if qtype == 1:
            answers = [{"name": name, "type": 1, "TTL": 60, "data": "127.0.0.1"}]
        elif qtype == 28:
            answers = [{"name": name, "type": 28, "TTL": 60, "data": "::1"}]
    elif qtype == 1 and lname in REGION_LOOPBACK and mode() == "relay":
        answers = [{"name": name, "type": 1, "TTL": 60,
                    "data": REGION_LOOPBACK[lname]}]
    elif qtype == 28 and lname in REGION_LOOPBACK:
        pass  # NODATA
    else:
        j = doh(name, qtype)
        if j is None:
            status = 4  # NOTIMP for unmapped qtypes
        else:
            status = int(j.get("Status", 0))
            answers = j.get("Answer") or []
            if not answers:
                authority = j.get("Authority") or []
    flags = 0x8180 | (status & 0xF)
    hdr = (tid + flags.to_bytes(2, "big") + (1).to_bytes(2, "big")
           + len(answers).to_bytes(2, "big") + len(authority).to_bytes(2, "big")
           + (0).to_bytes(2, "big"))
    body = question
    for rrset in (answers, authority):
        for a in rrset:
            ty = int(a.get("type", qtype))
            try:
                rd = encode_rdata(ty, str(a.get("data", "")))
            except Exception:
                continue
            body += (enc_name(a.get("name", name)) + ty.to_bytes(2, "big")
                     + (1).to_bytes(2, "big")
                     + int(a.get("TTL", 60)).to_bytes(4, "big")
                     + len(rd).to_bytes(2, "big") + rd)
    return hdr + body


def handle(data):
    try:
        return build_response(data)
    except Exception as e:
        print("dns53 err:", e, file=sys.stderr, flush=True)
        return data[:2] + b"\x81\x82" + data[4:6] + b"\x00\x00\x00\x00\x00\x00" + data[12:]


def udp_server():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 53))
    print("dns53 udp on 127.0.0.1:53", flush=True)
    while True:
        data, addr = s.recvfrom(4096)
        threading.Thread(target=lambda: s.sendto(handle(data), addr),
                         daemon=True).start()


def tcp_server():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 53))
    s.listen(50)
    print("dns53 tcp on 127.0.0.1:53", flush=True)
    while True:
        c, _ = s.accept()
        def job(c=c):
            try:
                hdr = c.recv(2)
                if len(hdr) < 2:
                    c.close(); return
                n = int.from_bytes(hdr, "big")
                data = b""
                while len(data) < n:
                    chunk = c.recv(n - len(data))
                    if not chunk:
                        break
                    data += chunk
                resp = handle(data)
                c.sendall(len(resp).to_bytes(2, "big") + resp)
            except Exception:
                pass
            finally:
                c.close()
        threading.Thread(target=job, daemon=True).start()


threading.Thread(target=udp_server, daemon=True).start()
tcp_server()
