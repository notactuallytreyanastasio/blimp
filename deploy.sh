#!/bin/bash
# Deploy blimp docs to Hetzner box as static site
# Subdomain: blimp.bobbby.online
set -e

DEPLOY_HOST="root@5.161.181.91"
# Note: the Caddy container mounts /opt/blimp (read-only) and serves it at
# blimp.bobbby.online. The separate /srv/blimp path on the host is NOT what
# Caddy reads, so we rsync to /opt/blimp.
DEPLOY_DIR="/opt/blimp"

echo "Deploying blimp docs to $DEPLOY_HOST:$DEPLOY_DIR..."

# -L follows the docs/tutorial/exercises -> ../../exercises symlink so the
# tutorial's fetches for stub and solution .blimp files resolve on the server.
rsync -aLvz --delete \
  --exclude='.DS_Store' \
  docs/ "$DEPLOY_HOST:$DEPLOY_DIR/"

echo "Done. Site should be live at https://blimp.bobbby.online"
echo "Tutorial: https://blimp.bobbby.online/tutorial/"
