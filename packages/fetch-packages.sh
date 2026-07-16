#!/usr/bin/env bash
# Download Prometheus-ecosystem packages for offline/air-gapped installs:
#
#   packages/tarball/  official upstream .tar.gz (linux-amd64) + checksums
#   packages/rpm/      EPEL RPMs (only some components are packaged there)
#   packages/windows/  windows_exporter .msi/.exe for Windows hosts
#
# Upstream Prometheus ships TARBALLS, not RPMs. EPEL packages a subset
# (prometheus, node-exporter, alertmanager); snmp_exporter and
# blackbox_exporter are tarball-only.
#
# Usage:  ./packages/fetch-packages.sh
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TB="$DIR/tarball"; RPM="$DIR/rpm"; WIN="$DIR/windows"
mkdir -p "$TB" "$RPM" "$WIN"
MAN="$DIR/manifest.txt"; : > "$MAN"

# repo -> asset filename pattern (linux amd64)
declare -A REPOS=(
  [prometheus/prometheus]='linux-amd64.tar.gz'
  [prometheus/node_exporter]='linux-amd64.tar.gz'
  [prometheus/snmp_exporter]='linux-amd64.tar.gz'
  [prometheus/blackbox_exporter]='linux-amd64.tar.gz'
  [prometheus/alertmanager]='linux-amd64.tar.gz'
  [prometheus/pushgateway]='linux-amd64.tar.gz'
)

echo "### 1. Upstream tarballs (github releases)"
for repo in "${!REPOS[@]}"; do
  pat="${REPOS[$repo]}"
  name="${repo#*/}"
  json=$(curl -sfL --max-time 60 "https://api.github.com/repos/$repo/releases/latest") || {
    echo "!!! API FAILED: $repo"; continue; }
  tag=$(jq -r .tag_name <<<"$json")
  url=$(jq -r --arg p "$pat" '.assets[] | select(.name|endswith($p)) | .browser_download_url' <<<"$json" | head -1)
  sums=$(jq -r '.assets[] | select(.name|test("sha256sums.txt$")) | .browser_download_url' <<<"$json" | head -1)
  [ -z "$url" ] && { echo "!!! no asset for $repo ($pat)"; continue; }

  f="$TB/$(basename "$url")"
  echo ">>> $name $tag"
  curl -sfL --max-time 300 -o "$f" "$url" || { echo "!!! DOWNLOAD FAILED: $url"; continue; }

  # verify against upstream sha256sums.txt when published
  ver="unverified"
  if [ -n "$sums" ] && curl -sfL --max-time 60 -o "$TB/$name-sha256sums.txt" "$sums"; then
    if (cd "$TB" && grep " $(basename "$f")\$" "$name-sha256sums.txt" | sha256sum -c --status -); then
      ver="sha256 OK"
    else
      ver="!!! CHECKSUM MISMATCH"; echo "    $ver"
    fi
    rm -f "$TB/$name-sha256sums.txt"
  fi
  printf '%-22s %-12s %-14s %s\n' "$name" "$tag" "$ver" "tarball/$(basename "$f")" >> "$MAN"
  echo "    $(basename "$f")  ($(du -h "$f"|cut -f1))  $ver"
done

echo
echo "### 2a. EPEL RPMs -- newest for prometheus/node-exporter/alertmanager"
for p in prometheus node-exporter alertmanager; do
  echo ">>> $p (epel)"
  # NOTE: --resolve is a boolean flag; `--resolve=false` is an argparse error.
  # Omit it to download just the named package without its dependencies.
  if dnf download --destdir "$RPM" "$p" >/dev/null 2>&1; then
    f=$(ls -t "$RPM"/${p}-*.rpm 2>/dev/null | head -1)
    [ -n "$f" ] && { printf '%-22s %-12s %-14s %s\n' "$p" "$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$f" 2>/dev/null)" "rpm(epel)" "rpm/$(basename "$f")" >> "$MAN"
                     echo "    $(basename "$f") ($(du -h "$f"|cut -f1))"; }
  else
    echo "!!! RPM DOWNLOAD FAILED: $p"
  fi
done

echo
echo "### 2b. prometheus-rpm (packagecloud) -- the ONLY RPM source for"
echo "###     snmp_exporter / blackbox_exporter / pushgateway on EL9"
PCREPO="https://packagecloud.io/prometheus-rpm/release/el/9/x86_64"
for p in snmp_exporter blackbox_exporter pushgateway node_exporter alertmanager; do
  echo ">>> $p (prometheus-rpm)"
  if dnf --repofrompath="promrpm,$PCREPO" --repo=promrpm --nogpgcheck --quiet \
        download --destdir "$RPM" "$p" >/dev/null 2>&1; then
    f=$(ls -t "$RPM"/${p}-*.rpm 2>/dev/null | head -1)
    [ -n "$f" ] && { printf '%-22s %-12s %-14s %s\n' "$p" "$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$f" 2>/dev/null)" "rpm(prom-rpm)" "rpm/$(basename "$f")" >> "$MAN"
                     echo "    $(basename "$f") ($(du -h "$f"|cut -f1))"; }
  else
    echo "!!! RPM DOWNLOAD FAILED: $p"
  fi
done
echo "    NOTE: --nogpgcheck is used to DOWNLOAD only. Import the repo GPG key"
echo "          before installing:  https://packagecloud.io/prometheus-rpm/release/gpgkey"

echo
echo "### 3. windows_exporter (for the Windows hosts)"
json=$(curl -sfL --max-time 60 "https://api.github.com/repos/prometheus-community/windows_exporter/releases/latest")
if [ -n "$json" ]; then
  tag=$(jq -r .tag_name <<<"$json")
  for pat in 'amd64.msi' 'amd64.exe'; do
    url=$(jq -r --arg p "$pat" '.assets[] | select(.name|endswith($p)) | .browser_download_url' <<<"$json" | head -1)
    [ -z "$url" ] && continue
    f="$WIN/$(basename "$url")"
    curl -sfL --max-time 300 -o "$f" "$url" \
      && { printf '%-22s %-12s %-14s %s\n' "windows_exporter" "$tag" "windows" "windows/$(basename "$f")" >> "$MAN"
           echo "    $(basename "$f") ($(du -h "$f"|cut -f1))"; }
  done
fi

echo
echo "=== manifest ==="; cat "$MAN"
echo "=== total: $(du -sh "$DIR" | cut -f1) ==="
