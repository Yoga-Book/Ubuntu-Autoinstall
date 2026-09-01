#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $# -eq 3 ]] || {
  printf 'Usage: %s REPORT_DIRECTORY OUTPUT_MANIFEST TRUSTED_VALIDATOR_DEB\n' "${0##*/}" >&2
  exit 2
}

for input_path in "$1" "$2" "$3"; do
  [[ ! -L $input_path ]] || {
    printf 'Error: symbolic-link arguments are not accepted: %s\n' "$input_path" >&2
    exit 1
  }
done

report_directory=$(realpath -e -- "$1")
output_manifest=$(realpath -m -- "$2")
trusted_validator_deb=$(realpath -e -- "$3")
root_directory=$(cd -- "$(dirname -- "$0")/.." && pwd)
verifier="$root_directory/scripts/verify-validated-stack.sh"
selected_manifest="$root_directory/manifests/yogabook-selected-packages.tsv"
release_manifest="$root_directory/manifests/yogabook-release-debs.tsv"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

for command_name in jq sha256sum dpkg-deb python3 realpath find; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
done

[[ -d $report_directory && ! -L $report_directory ]] ||
  die "report directory is missing or is a symbolic link: $report_directory"
[[ -f $trusted_validator_deb && ! -L $trusted_validator_deb ]] ||
  die "trusted Validator package is missing or is a symbolic link: $trusted_validator_deb"
[[ -f $selected_manifest && ! -L $selected_manifest ]] ||
  die "selected package manifest is missing or is a symbolic link: $selected_manifest"
[[ -f $release_manifest && ! -L $release_manifest ]] ||
  die "release manifest is missing or is a symbolic link: $release_manifest"
[[ ! -e $output_manifest || -f $output_manifest ]] ||
  die "output manifest exists and is not a regular file: $output_manifest"

unsafe_entry=$(find "$report_directory" -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) -print -quit)
[[ -z $unsafe_entry ]] || die "report contains a symbolic link or unsafe file type: $unsafe_entry"
for evidence_name in results.tsv validator.log environment.tsv validated-packages.tsv \
  state-before.tsv state-after.tsv; do
  evidence_path="$report_directory/$evidence_name"
  [[ -f $evidence_path && ! -L $evidence_path ]] ||
    die "required regular evidence is missing: $evidence_name"
done

temporary_directory=$(mktemp -d)
temporary_manifest=
cleanup() {
  [[ -z $temporary_manifest ]] || rm -f -- "$temporary_manifest"
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT
trusted_validator_snapshot="$temporary_directory/trusted-validator.deb"
install -m 0400 -- "$trusted_validator_deb" "$trusted_validator_snapshot"

deb_name=${trusted_validator_deb##*/}
deb_sha=$(sha256sum -- "$trusted_validator_snapshot" | awk '{print $1}')
mapfile -t release_matches < <(
  awk -F '\t' -v name="$deb_name" '$2 == name { print $1 "\t" $2 }' "$release_manifest"
)
[[ ${#release_matches[@]} -eq 1 ]] ||
  die "release manifest must contain exactly one trusted Validator asset named $deb_name"
IFS=$'\t' read -r release_sha release_name <<< "${release_matches[0]}"
[[ $release_name == "$deb_name" && $release_sha =~ ^[0-9a-f]{64}$ && $release_sha == "$deb_sha" ]] ||
  die 'trusted Validator package does not match its release-manifest SHA-256'

deb_package=$(dpkg-deb -f "$trusted_validator_snapshot" Package)
deb_version=$(dpkg-deb -f "$trusted_validator_snapshot" Version)
deb_architecture=$(dpkg-deb -f "$trusted_validator_snapshot" Architecture)
[[ $deb_package == yogabook-validator && -n $deb_version && -n $deb_architecture ]] ||
  die 'trusted package metadata is not a Yoga Book Validator package'

inventory="$report_directory/validated-packages.tsv"
mapfile -t validator_rows < <(
  awk -F '\t' '$1 == "yogabook-validator" { print $1 "\t" $2 "\t" $3 }' "$inventory"
)
[[ ${#validator_rows[@]} -eq 1 ]] ||
  die 'validated inventory must contain exactly one yogabook-validator identity'
[[ ${validator_rows[0]} == $'yogabook-validator\t'"$deb_version"$'\t'"$deb_architecture" ]] ||
  die 'validated inventory does not match the trusted Validator package metadata'

"$verifier" "$selected_manifest" "$inventory" >/dev/null

trusted_root="$temporary_directory/validator-root"
trusted_report="$temporary_directory/report"
mkdir -p -- "$trusted_root" "$trusted_report"
dpkg-deb -x "$trusted_validator_snapshot" "$trusted_root"
renderer="$trusted_root/usr/libexec/yogabook-validator/yogabook-validator-report.py"
matrix="$trusted_root/usr/share/yogabook-validator/acceptance.json"
[[ -f $renderer && ! -L $renderer && -f $matrix && ! -L $matrix ]] ||
  die 'trusted Validator package does not contain its report renderer and acceptance matrix'

cp -a -- "$report_directory/." "$trusted_report/"
unsafe_copy=$(find "$trusted_report" -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) -print -quit)
[[ -z $unsafe_copy ]] || die "copied report contains a symbolic link or unsafe file type: $unsafe_copy"
trusted_inventory="$trusted_report/validated-packages.tsv"
mapfile -t trusted_validator_rows < <(
  awk -F '\t' '$1 == "yogabook-validator" { print $1 "\t" $2 "\t" $3 }' "$trusted_inventory"
)
[[ ${#trusted_validator_rows[@]} -eq 1 && \
  ${trusted_validator_rows[0]} == $'yogabook-validator\t'"$deb_version"$'\t'"$deb_architecture" ]] ||
  die 'copied inventory does not match the trusted Validator package metadata'
"$verifier" "$selected_manifest" "$trusted_inventory" >/dev/null
rm -f -- "$trusted_report/report.json" "$trusted_report/report.md" "$trusted_report/report.html"
if ! YBV_ACCEPTANCE_MATRIX="$matrix" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$renderer" "$trusted_report" >/dev/null; then
  die 'trusted Validator could not regenerate the dossier report from raw evidence'
fi
report_model="$trusted_report/report.json"
[[ -f $report_model && ! -L $report_model ]] || die 'trusted report regeneration produced no report.json'

matrix_sha=$(sha256sum -- "$matrix" | awk '{print $1}')
matrix_schema=$(jq -er '.schema' "$matrix") || die 'trusted acceptance matrix has no schema'
matrix_component_count=$(jq -er '.components | length' "$matrix") ||
  die 'trusted acceptance matrix has no component catalog'
[[ $matrix_schema == org.yogabook.validator.acceptance/v1 && $matrix_component_count -eq 24 ]] ||
  die 'trusted acceptance matrix is not the required 24-component schema'
expected_component_ids=$(jq -c '[.components[].id] | sort' "$matrix")
jq -e \
  --arg version "$deb_version" \
  --arg matrix_sha "$matrix_sha" \
  --argjson expected_ids "$expected_component_ids" '
  .schema == "org.yogabook.validator.report/v1" and
  .validator.version == $version and
  .run.command == "dossier" and
  (.run.finished | type == "string" and length > 0) and
  .run.physical_acceptance_result == "PASS" and
  .environment.device == "Lenovo YB1-X91L" and
  .integrity.status == "PASS" and
  .package_inventory.complete == true and
  .package_inventory.validator_version_matches == true and
  .acceptance.matrix.sha256 == $matrix_sha and
  .acceptance.summary.completion_ready == true and
  .acceptance.summary.components_total == ($expected_ids | length) and
  .acceptance.summary.components_complete == ($expected_ids | length) and
  ([.acceptance.components[].id] | length) == ($expected_ids | length) and
  ([.acceptance.components[].id] | unique | length) == ($expected_ids | length) and
  ([.acceptance.components[].id] | sort) == $expected_ids and
  ([.acceptance.components[] | select(
    .status != "PASS" or
    .layers.structural.status != "PASS" or
    .layers.functional.status != "PASS" or
    .layers.physical.status != "PASS"
  )] | length) == 0 and
  .acceptance.execution_plan.integrity_blocking == false and
  .acceptance.execution_plan.actions_total == 0 and
  (.acceptance.execution_plan.actions | length) == 0
' "$report_model" >/dev/null ||
  die 'trusted regeneration does not prove the expected device, release, matrix, and complete physical acceptance'

jq -e '
  [.evidence[].file] as $files |
  ($files | length) == ($files | unique | length) and
  (["results.tsv", "validator.log", "environment.tsv", "validated-packages.tsv",
    "state-before.tsv", "state-after.tsv"] - $files | length) == 0
' "$report_model" >/dev/null || die 'trusted report evidence set is missing required files or contains duplicates'

evidence_count=0
evidence_tsv="$temporary_directory/evidence.tsv"
jq -er '.evidence[] | [.file, .bytes, .sha256] | @tsv' "$report_model" > "$evidence_tsv" ||
  die 'trusted report evidence metadata is missing or malformed'
while IFS=$'\t' read -r evidence_name evidence_bytes evidence_sha; do
  [[ -n $evidence_name ]] || continue
  [[ $evidence_name == "${evidence_name##*/}" && $evidence_name != . && $evidence_name != .. ]] ||
    die "trusted report contains an unsafe evidence path: $evidence_name"
  [[ $evidence_bytes =~ ^[0-9]+$ && $evidence_sha =~ ^[0-9a-f]{64}$ ]] ||
    die "trusted report contains a malformed evidence identity for $evidence_name"
  evidence_path="$trusted_report/$evidence_name"
  [[ -f $evidence_path && ! -L $evidence_path ]] || die "trusted evidence is missing: $evidence_name"
  [[ $(stat -c %s -- "$evidence_path") == "$evidence_bytes" ]] ||
    die "trusted evidence size does not match: $evidence_name"
  [[ $(sha256sum -- "$evidence_path" | awk '{print $1}') == "$evidence_sha" ]] ||
    die "trusted evidence SHA-256 does not match: $evidence_name"
  evidence_count=$((evidence_count + 1))
done < "$evidence_tsv"
((evidence_count >= 6)) || die "trusted report declares too few evidence files: $evidence_count"

output_parent=${output_manifest%/*}
[[ -n $output_parent ]] || output_parent=.
mkdir -p -- "$output_parent"
temporary_manifest=$(mktemp "$output_parent/.validated-packages.XXXXXX")
install -m 0644 -- "$trusted_report/validated-packages.tsv" "$temporary_manifest"
sync -f "$temporary_manifest"
mv -fT -- "$temporary_manifest" "$output_manifest"
temporary_manifest=
if ! sync -f "$output_parent"; then
  printf 'Warning: output was atomically replaced but directory sync was unavailable: %s\n' "$output_parent" >&2
fi

printf 'Promoted trusted complete physical-acceptance inventory to %s\n' "$output_manifest"
