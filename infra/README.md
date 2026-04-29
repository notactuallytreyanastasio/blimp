# Infra

Configs that live on the Hetzner box (`5.161.181.91`).

## Caddyfile

Mounted into the `blog-caddy-1` container at `/etc/caddy/Caddyfile` from
the host path `/opt/blog/Caddyfile`. To update:

```bash
scp infra/Caddyfile root@5.161.181.91:/opt/blog/Caddyfile
ssh root@5.161.181.91 \
  "docker exec blog-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile"
```

The `blimp.bobbby.online/chat/*` block reverse-proxies to
`172.18.0.1:8080`, which is the docker-bridge gateway for the
`blog_default` network. The chat itself runs as the `blimp-chat`
systemd service on the host (binary + source under
`/srv/blimp-chat/`).
