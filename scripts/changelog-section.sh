#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
file="${2:-CHANGELOG.md}"

if [[ -z "$version" ]]; then
  echo "Usage: changelog-section.sh <versi> [file]" >&2
  exit 1
fi

version="${version#v}"

section="$(awk -v ver="$version" '
  $0 ~ "^## \\[" ver "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' "$file")"

# Buang definisi link Markdown dan baris kosong di awal/akhir agar body rilis rapi.
section="$(printf '%s\n' "$section" | awk '
  /^\[[^]]*\]: / { next }
  { lines[++n] = $0 }
  END {
    start = 1
    while (start <= n && lines[start] ~ /^[[:space:]]*$/) start++
    end = n
    while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
    for (i = start; i <= end; i++) print lines[i]
  }
')"

if [[ -z "${section//[[:space:]]/}" ]]; then
  echo "Section ## [$version] tidak ditemukan di $file" >&2
  exit 1
fi

printf '%s\n' "$section"
