#!/usr/bin/env bash
set -euo pipefail

tag="${1:-}"
if [[ -z "$tag" ]]; then
  echo "Usage: check-release.sh vX.Y.Z" >&2
  exit 1
fi

if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Tag harus memakai format vX.Y.Z (contoh: v1.0.0), bukan '$tag'." >&2
  exit 1
fi

version="${tag#v}"
fail() { echo "GAGAL: $*" >&2; exit 1; }

core_version="$(awk -F'"' '/^version = /{print $2; exit}' core/Cargo.toml | tr -d '\r')"
linux_version="$(awk -F'"' '/^version = /{print $2; exit}' apps/linux/Cargo.toml | tr -d '\r')"
mac_version="$(awk '/^[[:space:]]*MARKETING_VERSION:/{print $2; exit}' apps/macos/project.yml | tr -d '\r')"
win_version="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' apps/windows/Zterm/Zterm.csproj | head -1 | tr -d '\r')"
iss_version="$(sed -n 's/^[[:space:]]*#define AppVersion "\(.*\)"/\1/p' apps/windows/installer/Zterm.iss | head -1 | tr -d '\r')"
site_version="$(sed -n 's/.*"softwareVersion": "\(.*\)".*/\1/p' site/index.html | head -1 | tr -d '\r')"

[[ "$core_version" == "$version" ]] || fail "core/Cargo.toml = $core_version, tag = $version"
[[ "$linux_version" == "$version" ]] || fail "apps/linux/Cargo.toml = $linux_version, tag = $version"
[[ "$mac_version" == "$version" ]] || fail "apps/macos/project.yml = $mac_version, tag = $version"
[[ "$win_version" == "$version" ]] || fail "apps/windows/Zterm/Zterm.csproj = $win_version, tag = $version"
[[ "$iss_version" == "$version" ]] || fail "apps/windows/installer/Zterm.iss = $iss_version, tag = $version"
[[ "$site_version" == "$version" ]] || fail "site/index.html = $site_version, tag = $version"

bash scripts/changelog-section.sh "$version" > /dev/null \
  || fail "CHANGELOG.md tidak punya section ## [$version]"

echo "OK: versi $version konsisten dan changelog tersedia."
