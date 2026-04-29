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

## Rebuilding and deploying the chat binary

The chat is a `chunks/lang/web/chat.blimp` script run by the Blimp
interpreter. Both live under `/srv/blimp-chat/` on the box. To
rebuild and ship a new interpreter:

```bash
# from chunks/lang/
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
scp zig-out/bin/blimp root@5.161.181.91:/srv/blimp-chat/blimp.new
ssh root@5.161.181.91 '
  chmod +x /srv/blimp-chat/blimp.new
  systemctl stop blimp-chat
  mv /srv/blimp-chat/blimp.new /srv/blimp-chat/blimp
  systemctl start blimp-chat'
```

To ship just an updated `chat.blimp` (no interpreter changes):

```bash
scp chunks/lang/web/chat.blimp root@5.161.181.91:/srv/blimp-chat/chat.blimp
ssh root@5.161.181.91 'systemctl restart blimp-chat'
```
