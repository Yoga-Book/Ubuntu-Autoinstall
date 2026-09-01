#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
VERIFIER="$ROOT_DIR/scripts/verify-validated-stack.sh"
VALIDATED="$ROOT_DIR/manifests/yogabook-validated-packages.tsv"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

task --dir "$ROOT_DIR" --dry build > "$temporary_directory/build-dry-run.out" 2>&1
preflight_line="$(awk '/task: \[deb:preflight\]/ { print NR; exit }' \
  "$temporary_directory/build-dry-run.out")"
cleanup_line="$(awk '/task: \[iso:rm-extract\]/ { print NR; exit }' \
  "$temporary_directory/build-dry-run.out")"
if [[ -z "$preflight_line" || -z "$cleanup_line" || "$preflight_line" -ge "$cleanup_line" ]]; then
  printf 'FAIL: build does not run package preflight before cleanup\n' >&2
  exit 1
fi
if grep -Eq 'linux-(headers|image)-[0-9].*yogabook' "$ROOT_DIR/task/Deb.Taskfile.yaml"; then
  printf 'FAIL: offline installation hard-codes a stale Yoga Book kernel package\n' >&2
  exit 1
fi
if grep -Eq 'linux-(headers|image)-[0-9].*yogabook' "$ROOT_DIR/task/ISO.Taskfile.yaml"; then
  printf 'FAIL: ISO verification hard-codes a stale Yoga Book kernel package\n' >&2
  exit 1
fi
for template in nocloud/user-data nocloud/vm-verify.sh; do
  grep -Fq '@@YOGABOOK_PACKAGES@@' "$ROOT_DIR/$template"
  grep -Fq '@@YOGABOOK_KERNEL_RELEASE@@' "$ROOT_DIR/$template"
  if grep -Eq 'linux-(headers|image)-[0-9].*yogabook' "$ROOT_DIR/$template"; then
    printf 'FAIL: %s hard-codes a stale Yoga Book kernel package\n' "$template" >&2
    exit 1
  fi
done
grep -Fq 'SELECTED_MANIFEST="$REPO_ROOT/manifests/yogabook-selected-packages.tsv"' \
  "$ROOT_DIR/scripts/render-autoinstall.sh"
grep -Fq -- '-v "$SELECTED_MANIFEST:/opt/yoga-book-selected.tsv:ro"' \
  "$ROOT_DIR/task/Deb.Taskfile.yaml"
grep -Fq 'set -- $(cut -f1 /opt/yoga-book-selected.tsv)' \
  "$ROOT_DIR/task/Deb.Taskfile.yaml"

cp "$VALIDATED" "$temporary_directory/matching.tsv"
"$VERIFIER" "$temporary_directory/matching.tsv" "$VALIDATED" >/dev/null

awk -F '\t' 'BEGIN { OFS = "\t" } NR == 1 { $2 = $2 "-stale" } { print }' \
  "$VALIDATED" > "$temporary_directory/stale.tsv"
if "$VERIFIER" "$temporary_directory/stale.tsv" "$VALIDATED" \
  >"$temporary_directory/stale.out" 2>&1; then
  printf 'FAIL: mismatched package stack was accepted\n' >&2
  exit 1
fi
grep -Fq 'does not match the stack validated on the Yoga Book' "$temporary_directory/stale.out"
grep -Fq -- '-alsa-ucm-conf-yogabook' "$temporary_directory/stale.out"
grep -Fq -- '+alsa-ucm-conf-yogabook' "$temporary_directory/stale.out"

head -n 14 "$VALIDATED" > "$temporary_directory/incomplete.tsv"
if "$VERIFIER" "$temporary_directory/incomplete.tsv" "$VALIDATED" \
  >"$temporary_directory/incomplete.out" 2>&1; then
  printf 'FAIL: incomplete package stack was accepted\n' >&2
  exit 1
fi
grep -Fq 'must contain exactly 15 unique package identities; found 14' \
  "$temporary_directory/incomplete.out"

{
  head -n 14 "$VALIDATED"
  head -n 1 "$VALIDATED"
} > "$temporary_directory/duplicate.tsv"
if "$VERIFIER" "$temporary_directory/duplicate.tsv" "$VALIDATED" \
  >"$temporary_directory/duplicate.out" 2>&1; then
  printf 'FAIL: duplicate package identity was accepted\n' >&2
  exit 1
fi
grep -Fq 'duplicate package identity alsa-ucm-conf-yogabook' \
  "$temporary_directory/duplicate.out"

promotion_report="$temporary_directory/complete-report"
promotion_output="$temporary_directory/promoted.tsv"
selected_manifest="$ROOT_DIR/manifests/yogabook-selected-packages.tsv"
release_manifest="$ROOT_DIR/manifests/yogabook-release-debs.tsv"
validator_version=$(awk -F '\t' '$1 == "yogabook-validator" { print $2 }' "$selected_manifest")
[[ -n $validator_version ]]
trusted_deb="$ROOT_DIR/DATA/DEB/upstream/yogabook-validator_${validator_version}_all.deb"
mkdir -p "$promotion_report"
cp "$selected_manifest" "$promotion_report/validated-packages.tsv"
printf 'timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n' > "$promotion_report/results.tsv"
printf 'Yoga Book Validator %s\nCommand: dossier\n' "$validator_version" \
  > "$promotion_report/validator.log"
printf 'key\tvalue\ndevice\tLenovo YB1-X91L\n' > "$promotion_report/environment.tsv"
printf 'schema\torg.yogabook.validator.state/v1\n' > "$promotion_report/state-before.tsv"
printf 'schema\torg.yogabook.validator.state/v1\n' > "$promotion_report/state-after.tsv"

expected_sha=$(awk -F '\t' -v name="${trusted_deb##*/}" '$2 == name { print $1 }' "$release_manifest")
[[ -n $expected_sha ]]
printf '%s  %s\n' "$expected_sha" "$trusted_deb" | sha256sum --check --status
grep -Fq 'selected_manifest="$root_directory/manifests/yogabook-selected-packages.tsv"' \
  "$ROOT_DIR/scripts/promote-validated-stack.sh"
grep -Fq 'release_manifest="$root_directory/manifests/yogabook-release-debs.tsv"' \
  "$ROOT_DIR/scripts/promote-validated-stack.sh"
grep -Fq 'mv -fT -- "$temporary_manifest" "$output_manifest"' \
  "$ROOT_DIR/scripts/promote-validated-stack.sh"
if grep -Eq 'SELECTED_MANIFEST|RELEASE_MANIFEST' "$ROOT_DIR/Taskfile.yaml"; then
  printf 'FAIL: promotion trust anchors must not be caller-overridable\n' >&2
  exit 1
fi

promote() {
  "$ROOT_DIR/scripts/promote-validated-stack.sh" \
    "$promotion_report" "$promotion_output" "$trusted_deb"
}

expect_promotion_failure() {
  local label=$1
  local expected=$2
  printf 'preserve-on-failure\n' > "$promotion_output"
  if promote > "$temporary_directory/promotion-$label.out" 2>&1; then
    printf 'FAIL: unsafe promotion case was accepted: %s\n' "$label" >&2
    exit 1
  fi
  grep -Fxq 'preserve-on-failure' "$promotion_output"
  if ! grep -Fq "$expected" "$temporary_directory/promotion-$label.out"; then
    printf 'FAIL: %s did not emit expected diagnostic: %s\n' "$label" "$expected" >&2
    sed -n '1,80p' "$temporary_directory/promotion-$label.out" >&2
    exit 1
  fi
}

# A hand-authored supplied report with dummy components must never override the
# repository-bound Validator renderer's verdict from raw evidence.
jq -n '{schema:"org.yogabook.validator.report/v1", integrity:{status:"PASS"}, acceptance:{summary:{completion_ready:true}, components:[range(0;24)|{id:("dummy-"+tostring),status:"PASS"}]}}' \
  > "$promotion_report/report.json"
expect_promotion_failure self-asserted 'trusted regeneration does not prove'

tampered_deb="$temporary_directory/${trusted_deb##*/}"
cp "$trusted_deb" "$tampered_deb"
printf 'tampered\n' >> "$tampered_deb"
trusted_deb=$tampered_deb
expect_promotion_failure release-sha 'does not match its release-manifest SHA-256'
trusted_deb="$ROOT_DIR/DATA/DEB/upstream/yogabook-validator_${validator_version}_all.deb"

ln -s results.tsv "$promotion_report/unsafe-link"
expect_promotion_failure symlink 'symbolic link or unsafe file type'
rm "$promotion_report/unsafe-link"

mkdir "$temporary_directory/output-directory"
promotion_output="$temporary_directory/output-directory"
if promote > "$temporary_directory/promotion-output-directory.out" 2>&1; then
  printf 'FAIL: output directory was accepted as a manifest path\n' >&2
  exit 1
fi
grep -Fq 'output manifest exists and is not a regular file' \
  "$temporary_directory/promotion-output-directory.out"

printf 'Verified package preflight and repository-anchored fail-closed promotion behavior.\n'
"$ROOT_DIR/scripts/test-promote-validated-stack.sh"
