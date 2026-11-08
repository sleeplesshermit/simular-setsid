# 05 — Known limitations and open questions

1. **Data-plane egress is only partly characterised.** The tunnel
   control plane is verified end-to-end (handshake 101, tunnel
   healthy, server log shows accepted inbound connections). But
   the box has no direct egress — its traffic must traverse the
   platform HTTP proxy — and per-destination reachability *from
   xray's direct (`freedom`) outbound* has not been fully mapped:
   in the original deployment, some destinations accepted at the
   inbound never completed, and a client delay test against a
   major search domain returned -1 while other nodes on the same
   client worked. Treat "tunnel up" and "proxy usable for
   destination X" as separate claims, and test the destinations
   you care about. (Fixing the outbound path is future work and
   would be its own change; it is deliberately not part of the
   setsid result.)
2. **No in-box root watchdog (by design).** A watchdog prototype
   (test E) was built during the experiments but excluded from
   this project by the owner's decision. If the platform ever
   starts reaping detached sessions, recovery falls back to the
   external supervisor's ~14 min cycle.
3. **Save/restore behaviour is partly understood.** During test
   C the box's saved-at timestamp advanced once; whether the
   setsid session survives image saves verbatim, or supervise.sh
   reassembled the stack, is unresolved. Hibernation *does* kill
   user processes (root dns53 excepted, inconsistently) — the
   external supervisor's relaunch check exists for this.
4. **The platform's rules are unpublished.** No documented idle
   threshold, teardown rule, or computer-time metering. The usage
   tool read all-zero after a day of scripted activity; what
   actually consumes the daily credit is unconfirmed.
5. **Single sample.** One box, one account, one day of
   experiments (2026-11-08), plus a one-week downtime report
   pending in the original deployment. The setsid result is
   strong within that sample (10–12 min baseline vs 2 h 48 min+),
   but it is still n=1.
6. **VMess/WS is deprecated upstream.** Current xray cores warn
   that VMess and WebSocket transport are deprecated and may be
   removed; the stack pins xray v26.10.31. A future migration
   (VLESS / XHTTP) is out of scope here.
7. **The resolv.conf guard is a loop, not a lock.** A rewrite
   between guard iterations can still flap cloudflared for a few
   seconds; measured self-heal is <8 s.
