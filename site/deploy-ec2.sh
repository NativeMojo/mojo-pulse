#!/usr/bin/env bash
# Deploy the Mojo Pulse marketing site to the EC2 box that serves mojopulse.io.
#
# The site lives at /opt/www/pulse (owned www:www); ec2-user reaches it via
# passwordless sudo. nginx + TLS are already configured on the box, so shipping
# a change is just this rsync. Run it from your Mac:  cd site && ./deploy-ec2.sh
set -euo pipefail

HOST="${PULSE_SITE_HOST:-mojopulse.io}"     # ssh alias / hostname
DEST="${PULSE_SITE_DEST:-/opt/www/pulse}"   # web root on the box
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "==> rsync $SRC/ → $HOST:$DEST/"
rsync -avz --delete \
  --exclude 'deploy.sh' --exclude 'deploy-ec2.sh' --exclude 'README.md' --exclude '.*' \
  --rsync-path="sudo rsync" \
  "$SRC/" "$HOST:$DEST/"

echo "==> fixing ownership + read perms"
ssh -o BatchMode=yes "$HOST" "sudo chown -R www:www '$DEST' && sudo chmod -R a+rX '$DEST'"

echo "==> verifying"
curl -sS -o /dev/null -w "https://$HOST/  →  %{http_code}\n" "https://$HOST/"
echo "Done. https://$HOST/"
