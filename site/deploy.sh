#!/usr/bin/env bash
# Deploy the Mojo Pulse marketing site (this directory) to S3 + CloudFront.
#
# One-time setup (bucket, CloudFront, ACM cert, DNS) is documented in README.md.
# After that, shipping a change is just:  ./deploy.sh
#
# Config via env (or edit the defaults):
#   PULSE_SITE_BUCKET   S3 bucket name            (default: mojopulse.io)
#   PULSE_SITE_CF_DIST  CloudFront distribution id (optional; enables cache invalidation)
#   AWS_PROFILE         which aws credentials to use (optional)
set -euo pipefail

BUCKET="${PULSE_SITE_BUCKET:-mojopulse.io}"
DIST_ID="${PULSE_SITE_CF_DIST:-}"
SRC="$(cd "$(dirname "$0")" && pwd)"

command -v aws >/dev/null || { echo "aws CLI not found — install it and 'aws configure' first."; exit 1; }

echo "==> Syncing $SRC → s3://$BUCKET"

# Long-lived, rarely-changing assets first (icons, favicon).
aws s3 sync "$SRC/assets" "s3://$BUCKET/assets" \
  --cache-control "public, max-age=86400" \
  --delete

# Everything else (HTML, favicon.svg) — short cache so releases show up fast.
aws s3 sync "$SRC" "s3://$BUCKET" \
  --exclude ".*" \
  --exclude "deploy.sh" \
  --exclude "README.md" \
  --exclude "assets/*" \
  --cache-control "public, max-age=300" \
  --delete

if [[ -n "$DIST_ID" ]]; then
  echo "==> Invalidating CloudFront $DIST_ID"
  aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" >/dev/null
  echo "    done (propagation ~30–60s)"
else
  echo "!! PULSE_SITE_CF_DIST not set — skipped CloudFront invalidation."
  echo "   Viewers may see the old page until the CDN cache expires."
fi

echo "==> Deployed. https://mojopulse.io/"
