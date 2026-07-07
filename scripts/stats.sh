#!/usr/bin/env bash
# Install / usage proxies for Mojo Pulse — no telemetry required.
#
#   DMG downloads    ≈ installs (people who fetched the disk image)
#   appcast fetches  ≈ update checks — installed apps polling for updates,
#                      so growth here tracks the active fleet over time.
#
# Public data from the GitHub API; no auth needed.
set -euo pipefail
curl -sS --max-time 20 "https://api.github.com/repos/NativeMojo/mojo-pulse/releases?per_page=100" | python3 -c "
import json,sys
rels=json.load(sys.stdin)
tot_dmg=tot_cast=0
print(f'{\"release\":<12} {\"published\":<12} {\"DMG downloads\":>14} {\"appcast fetches\":>16}')
for r in rels:
    dmg=sum(a['download_count'] for a in r['assets'] if a['name'].endswith('.dmg'))
    cast=sum(a['download_count'] for a in r['assets'] if a['name']=='appcast.xml')
    tot_dmg+=dmg; tot_cast+=cast
    print(f\"{r['tag_name']:<12} {r['published_at'][:10]:<12} {dmg:>14} {cast:>16}\")
print(f'{\"TOTAL\":<12} {\"\":<12} {tot_dmg:>14} {tot_cast:>16}')
"
