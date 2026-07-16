#!/usr/bin/env bash
# Pull every image referenced by the manifests and save each as a gzipped
# docker-archive in images/, plus manifest.txt recording resolved digests.
#
# Usage:
#   ./images/save-images.sh
#
# The archives are git-ignored (~1.1GB); regenerate them whenever the stack's
# images change. See images/README.md for how to load them on a node/registry.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/images"
MAN="$OUT/manifest.txt"
mkdir -p "$OUT"
: > "$MAN"

# Every distinct `image:` value in the manifests.
IMAGES=$(grep -rhoE 'image:[[:space:]]*[^ ]+' --include=*.yaml "$REPO" \
  | sed 's/image:[[:space:]]*//' | grep -v '^#' | sort -u)

fail=0
for img in $IMAGES; do
  # podman's short-name resolution needs a TTY; qualify bare docker.io names.
  case "$img" in
    *.*/*|localhost/*) fq="$img" ;;   # already has a registry host
    *)                 fq="docker.io/$img" ;;
  esac

  file="$(echo "$img" | sed 's#[/:]#_#g').tar.gz"
  echo ">>> $fq"

  if ! podman pull --quiet "$fq" >/dev/null 2>&1; then
    echo "!!! PULL FAILED: $img"; fail=$((fail+1)); continue
  fi
  if ! podman save --format docker-archive "$fq" 2>/dev/null | gzip -1 > "$OUT/$file"; then
    echo "!!! SAVE FAILED: $img"; rm -f "$OUT/$file"; fail=$((fail+1)); continue
  fi

  digest=$(podman inspect --format '{{index .RepoDigests 0}}' "$fq" 2>/dev/null)
  printf '%s\n  digest: %s\n  file:   %s (%s)\n\n' \
    "$img" "${digest:-unknown}" "$file" "$(du -h "$OUT/$file" | cut -f1)" >> "$MAN"
  echo "    saved images/$file ($(du -h "$OUT/$file" | cut -f1))"
done

echo
echo "=== saved to $OUT ($(du -sh "$OUT" | cut -f1)), failures: $fail ==="
exit $((fail > 0))
