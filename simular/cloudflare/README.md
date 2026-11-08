# Cloudflare side — what to create

One remotely-managed tunnel, one DNS record:

1. **Tunnel** — `POST /accounts/{account_id}/cfd_tunnel`
   `{"name": "<tunnel-name>", "config_src": "cloudflare"}`
   Save the returned tunnel id.
2. **Ingress config** — `PUT /accounts/{account_id}/cfd_tunnel/{id}/configurations`
   ```json
   {"config": {"ingress": [
     {"hostname": "<AGN>", "service": "http://localhost:8001"},
     {"service": "http_status:404"}
   ]}}
   ```
   The catch-all 404 matters: it is the liveness signature the
   external hooks probe for (see docs/04-operations.md).
3. **DNS** — in your zone, a proxied CNAME:
   `<AGN>` → `{tunnel_id}.cfargotunnel.com`
4. **Token** — `GET /accounts/{account_id}/cfd_tunnel/{id}/token`.
   Write the returned token byte-exact to a file (never retype it,
   never log it) and place that file in the box at
   `/workspace/agk-in.txt` — `supervise.sh` passes it to cloudflared
   with `--token-file`.
