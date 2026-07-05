#!/usr/bin/env bash
# Full release pipeline in one call: bump version -> commit/tag/push -> build,
# sign, notarize, staple, DMG -> sign appcast -> GitHub release -> Homebrew tap.
#
# Versioning policy: bump PATCH for fixes and small changes; only bump MINOR
# for a real user-facing feature; MAJOR is reserved for breaking changes.
# Don't default to minor out of habit — pick the flag that matches the size
# of the change.
#
# Usage:
#   scripts/release.sh --patch  --title "..." --notes-file notes.md
#   scripts/release.sh --minor  --title "..." --notes-file notes.md
#   scripts/release.sh --major  --title "..." --notes-file notes.md
#   scripts/release.sh --version 2.0.0 --title "..." --notes-file notes.md
#
# Add --dry-run to print every step (including the computed version and
# parsed DMG/sha256) without touching git, GitHub, or the Homebrew tap.
#
# Assumes: the change being released is already committed on a clean `main`;
# this script's first commit is the version bump itself. Requires the notary
# .p8 and Sparkle EdDSA key under ~/mojopulse-signing/, a homebrew-tap
# checkout as a sibling directory (override with TAP_DIR=/path env var), and
# a `gh` login isolated to GH_CONFIG_DIR below (see setup note there) — this
# script never depends on or touches your machine's default `gh` session, so
# switching accounts for other projects can't break (or be broken by) a
# mojo-pulse release.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TAP_DIR="${TAP_DIR:-$REPO_ROOT/../homebrew-tap}"
NOTARY_KEY_FILE="$HOME/mojopulse-signing/AuthKey_D56868A4PH.p8"
SPARKLE_KEY_FILE="$HOME/mojopulse-signing/sparkle_eddsa_private_key.txt"
GH_REPO="NativeMojo/mojo-pulse"

# Isolated gh CLI identity for this repo only — never the machine's shared
# default `gh` login/active-account (this repo's account is `iamojo`; other
# projects on this machine use their own accounts and must never see this one,
# or be seen by it). One-time setup, outside this script:
#   GH_CONFIG_DIR="$HOME/mojopulse-signing/gh-config" gh auth login -h github.com --web
export GH_CONFIG_DIR="$HOME/mojopulse-signing/gh-config"

BUMP=""
EXPLICIT_VERSION=""
TITLE=""
NOTES_FILE=""
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh (--patch|--minor|--major|--version X.Y.Z) --title "..." --notes-file <path> [--dry-run]

  --patch          Bump X.Y.Z -> X.Y.(Z+1). Default choice for fixes/small changes.
  --minor          Bump X.Y.Z -> X.(Y+1).0. Only for a real new user-facing feature.
  --major          Bump X.Y.Z -> (X+1).0.0. Breaking changes only.
  --version X.Y.Z  Use an explicit version instead of computing a bump.
  --title STR      GitHub release title.
  --notes-file P   Path to a file with the release notes body (Markdown).
  --dry-run        Print every step without touching git/GitHub/Homebrew.
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch) BUMP="patch"; shift ;;
    --minor) BUMP="minor"; shift ;;
    --major) BUMP="major"; shift ;;
    --version) EXPLICIT_VERSION="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -n "$BUMP" || -n "$EXPLICIT_VERSION" ]] || { echo "Must pass one of --patch/--minor/--major/--version"; usage; }
[[ -n "$TITLE" ]] || { echo "Must pass --title"; usage; }
[[ -n "$NOTES_FILE" && -f "$NOTES_FILE" ]] || { echo "Must pass --notes-file with an existing file"; usage; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

echo "==> Preflight checks"
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean — commit or stash first."; exit 1; }
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$CURRENT_BRANCH" == "main" ]] || { echo "Not on main (on $CURRENT_BRANCH) — aborting."; exit 1; }
command -v gh >/dev/null || { echo "gh CLI not found"; exit 1; }
# `gh auth status` exits 1 if ANY configured account has a stale token, even an
# inactive one — not what we want. Exercise the active credential directly.
# (GH_CONFIG_DIR above already scopes this to the isolated per-repo login.)
gh api user >/dev/null 2>&1 || { echo "gh not authenticated in \$GH_CONFIG_DIR ($GH_CONFIG_DIR) — see the setup note above"; exit 1; }
[[ -f "$NOTARY_KEY_FILE" ]] || { echo "Missing notary key: $NOTARY_KEY_FILE"; exit 1; }
[[ -f "$SPARKLE_KEY_FILE" ]] || { echo "Missing Sparkle EdDSA key: $SPARKLE_KEY_FILE"; exit 1; }
[[ -d "$TAP_DIR/.git" ]] || { echo "Homebrew tap not found at $TAP_DIR (override with TAP_DIR=)"; exit 1; }
[[ -z "$(cd "$TAP_DIR" && git status --porcelain)" ]] || { echo "$TAP_DIR working tree not clean — aborting."; exit 1; }

CURRENT_VERSION="$(grep -oE 'MARKETING_VERSION := [0-9]+\.[0-9]+\.[0-9]+' Makefile | awk '{print $3}')"
[[ -n "$CURRENT_VERSION" ]] || { echo "Could not read MARKETING_VERSION from Makefile"; exit 1; }
echo "Current version: $CURRENT_VERSION"

if [[ -n "$EXPLICIT_VERSION" ]]; then
  NEW_VERSION="$EXPLICIT_VERSION"
else
  IFS='.' read -r MAJ MIN PATCH <<< "$CURRENT_VERSION"
  case "$BUMP" in
    patch) NEW_VERSION="$MAJ.$MIN.$((PATCH + 1))" ;;
    minor) NEW_VERSION="$MAJ.$((MIN + 1)).0" ;;
    major) NEW_VERSION="$((MAJ + 1)).0.0" ;;
  esac
fi
echo "New version: $NEW_VERSION"
TAG="v$NEW_VERSION"

git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null && { echo "Tag $TAG already exists locally — aborting."; exit 1; }
if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists on origin — aborting."
  exit 1
fi

echo "==> Bumping Makefile version ($CURRENT_VERSION -> $NEW_VERSION)"
run sed -i '' "s/MARKETING_VERSION := $CURRENT_VERSION/MARKETING_VERSION := $NEW_VERSION/" Makefile
run git add Makefile
run git commit -m "Bump version to $NEW_VERSION

Co-Authored-By: Claude <noreply@anthropic.com>"

echo "==> Tagging $TAG"
run git tag "$TAG"

echo "==> Pushing tag (SSH, falling back to HTTPS if that fails)"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] git push origin $TAG"
else
  git push origin "$TAG" || git push "https://github.com/$GH_REPO.git" "$TAG"
fi

echo "==> make release (build, sign, notarize, staple, DMG) — can take several minutes"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] make release"
  DMG_PATH="dist/MojoPulse-$NEW_VERSION.dmg"
  SHA256="<dry-run-placeholder-sha256>"
else
  RELEASE_LOG="$(mktemp)"
  make release 2>&1 | tee "$RELEASE_LOG"
  DMG_PATH="$(grep '^DMG:' "$RELEASE_LOG" | awk '{print $2}')"
  SHA256="$(grep '^SHA256:' "$RELEASE_LOG" | awk '{print $2}')"
  rm -f "$RELEASE_LOG"
  [[ -n "$DMG_PATH" && -n "$SHA256" ]] || { echo "Could not parse DMG path/SHA256 from make release output"; exit 1; }
  ACTUAL_SHA256="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
  [[ "$ACTUAL_SHA256" == "$SHA256" ]] || { echo "SHA256 mismatch: make printed $SHA256, file hashes to $ACTUAL_SHA256"; exit 1; }
fi
echo "DMG:    $DMG_PATH"
echo "SHA256: $SHA256"

echo "==> Generating signed appcast"
APPCAST_DIR="dist/appcast-$NEW_VERSION"
run rm -rf "$APPCAST_DIR"
run mkdir -p "$APPCAST_DIR"
run cp "$DMG_PATH" "$APPCAST_DIR/"
run .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --ed-key-file "$SPARKLE_KEY_FILE" \
  --download-url-prefix "https://github.com/$GH_REPO/releases/download/$TAG/" \
  "$APPCAST_DIR"

echo "==> Creating GitHub release $TAG"
run gh release create "$TAG" \
  "$DMG_PATH" \
  "$APPCAST_DIR/appcast.xml" \
  --repo "$GH_REPO" \
  --title "$TITLE" \
  --notes-file "$NOTES_FILE" \
  --latest

if [[ $DRY_RUN -eq 0 ]]; then
  echo "==> Verifying /releases/latest serves the new appcast"
  sleep 3
  if curl -sL "https://github.com/$GH_REPO/releases/latest/download/appcast.xml" | grep -q "$NEW_VERSION"; then
    echo "OK: /releases/latest/download/appcast.xml mentions $NEW_VERSION"
  else
    echo "WARNING: /releases/latest/download/appcast.xml does not yet mention $NEW_VERSION — check manually."
  fi
fi

echo "==> Bumping Homebrew cask"
CASK_FILE="$TAP_DIR/Casks/mojo-pulse.rb"
[[ -f "$CASK_FILE" ]] || { echo "Cask not found: $CASK_FILE"; exit 1; }
run sed -i '' \
  -e "s/version \"$CURRENT_VERSION\"/version \"$NEW_VERSION\"/" \
  -e "s/sha256 \"[a-f0-9]*\"/sha256 \"$SHA256\"/" \
  "$CASK_FILE"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] commit + push $CASK_FILE in $TAP_DIR"
else
  (cd "$TAP_DIR" && git add Casks/mojo-pulse.rb && git commit -m "mojo-pulse $NEW_VERSION

Co-Authored-By: Claude <noreply@anthropic.com>" && git push origin main)
fi

echo ""
echo "=== Released $TAG ==="
echo "GitHub:  https://github.com/$GH_REPO/releases/tag/$TAG"
echo "DMG:     $DMG_PATH"
echo "SHA256:  $SHA256"
