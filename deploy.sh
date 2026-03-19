#!/bin/bash
# Deploy blimp docs to Hetzner box as static site
# Subdomain: blimp.bobbby.online

DEPLOY_HOST="root@5.161.181.91"
DEPLOY_DIR="/srv/blimp"

echo "Deploying blimp docs to $DEPLOY_HOST:$DEPLOY_DIR..."

# Sync docs/ to the server
rsync -avz --delete \
  --exclude='.DS_Store' \
  docs/ "$DEPLOY_HOST:$DEPLOY_DIR/"

echo "Done. Site should be live at https://blimp.bobbby.online"
