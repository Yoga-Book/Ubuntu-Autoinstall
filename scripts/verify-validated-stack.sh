#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SELECTED_MANIFEST="${1:-$ROOT_DIR/manifests/yogabook-selected-packages.tsv}"
VALIDATED_MANIFEST="${2:-$ROOT_DIR/manifests/yogabook-validated-packages.tsv}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

normalize_manifest() {
  local manifest=$1
  [[ -f "$manifest" ]] || die "package manifest is missing: $manifest"
  awk -F '\t' '
    NF != 3 || $1 == "" || $2 == "" || $3 == "" {
      printf "Error: malformed package identity at %s:%d\n", FILENAME, FNR > "/dev/stderr"
      invalid = 1
      next
    }
    seen[$1]++ {
      printf "Error: duplicate package identity %s in %s\n", $1, FILENAME > "/dev/stderr"
      invalid = 1
      next
    }
    { print $1 "\t" $2 "\t" $3; count++ }
    END {
      if (count != 15) {
        printf "Error: %s must contain exactly 15 unique package identities; found %d\n", FILENAME, count > "/dev/stderr"
        invalid = 1
      }
      exit invalid ? 1 : 0
    }
  ' "$manifest" | LC_ALL=C sort -t "$(printf '\t')" -k1,1
}

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
selected_normalized="$temporary_directory/selected.tsv"
validated_normalized="$temporary_directory/validated.tsv"
normalize_manifest "$SELECTED_MANIFEST" > "$selected_normalized" \
  || die "selected package manifest is invalid: $SELECTED_MANIFEST"
normalize_manifest "$VALIDATED_MANIFEST" > "$validated_normalized" \
  || die "validated package manifest is invalid: $VALIDATED_MANIFEST"

if ! cmp -s "$selected_normalized" "$validated_normalized"; then
  printf '%s\n' \
    'Error: the ISO-selected package set does not match the stack validated on the Yoga Book.' \
    'Publish and pin the missing release assets, then update yogabook-selected-packages.tsv.' >&2
  diff -u \
    --label manifests/yogabook-selected-packages.tsv \
    --label manifests/yogabook-validated-packages.tsv \
    "$selected_normalized" "$validated_normalized" >&2 || true
  exit 1
fi

printf 'Verified that all 15 ISO-selected package identities match the validated Yoga Book stack.\n'
