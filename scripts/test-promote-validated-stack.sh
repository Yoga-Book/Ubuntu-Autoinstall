#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT

fixture_root="$temporary_directory/trusted-root"
fixture_package_root="$temporary_directory/package-root"
fixture_report="$temporary_directory/report"
fixture_output="$temporary_directory/promoted.tsv"
fixture_deb="$temporary_directory/yogabook-validator_9.9.0_all.deb"

mkdir -p \
  "$fixture_root/scripts" \
  "$fixture_root/manifests" \
  "$fixture_package_root/DEBIAN" \
  "$fixture_package_root/usr/libexec/yogabook-validator" \
  "$fixture_package_root/usr/share/yogabook-validator" \
  "$fixture_report"
install -m 0755 "$ROOT_DIR/scripts/promote-validated-stack.sh" \
  "$fixture_root/scripts/promote-validated-stack.sh"
install -m 0755 "$ROOT_DIR/scripts/verify-validated-stack.sh" \
  "$fixture_root/scripts/verify-validated-stack.sh"

awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "yogabook-validator" { $2 = "9.9.0"; $3 = "all" } { print }' \
  "$ROOT_DIR/manifests/yogabook-selected-packages.tsv" \
  > "$fixture_root/manifests/yogabook-selected-packages.tsv"
cp "$fixture_root/manifests/yogabook-selected-packages.tsv" \
  "$fixture_report/validated-packages.tsv"

printf '%s\n' \
  'Package: yogabook-validator' \
  'Version: 9.9.0' \
  'Architecture: all' \
  'Maintainer: Yoga Book test fixture <noreply@yogabook.local>' \
  'Description: trusted promotion integration fixture' \
  > "$fixture_package_root/DEBIAN/control"

jq -n '
  ["boot-kernel", "display-gpu", "micro-hdmi", "halo-input", "haptics", "pen",
   "touchscreen", "rotation-sensors", "audio", "headset", "cameras", "wifi",
   "bluetooth", "usb-otg", "internal-storage", "sd-card", "lte", "gnss",
   "battery-charging", "thermal-resources", "suspend-resume", "buttons-lid",
   "indicator-leds", "reboot-poweroff"] as $ids |
  {
    schema: "org.yogabook.validator.acceptance/v1",
    components: [$ids[] | {
      id: ., name: ., layers: {
        structural: ["fixture/structural"],
        functional: ["fixture/functional"],
        physical: ["physical/fixture"]
      }
    }]
  }
' > "$fixture_package_root/usr/share/yogabook-validator/acceptance.json"

cat > "$fixture_package_root/usr/libexec/yogabook-validator/yogabook-validator-report.py" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

report_dir = Path(sys.argv[1])
matrix_path = Path(os.environ["YBV_ACCEPTANCE_MATRIX"])
matrix = json.loads(matrix_path.read_text(encoding="utf-8"))
matrix_sha = hashlib.sha256(matrix_path.read_bytes()).hexdigest()
raw_results = (report_dir / "results.tsv").read_text(encoding="utf-8")
complete = "\tfixture\tpass\tPASS\t" in raw_results
evidence_names = [
    "results.tsv",
    "validator.log",
    "environment.tsv",
    "validated-packages.tsv",
    "state-before.tsv",
    "state-after.tsv",
]
evidence = []
for name in evidence_names:
    payload = (report_dir / name).read_bytes()
    evidence.append({
        "file": name,
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    })

components = []
for source in matrix["components"]:
    layer = {"status": "PASS"}
    components.append({
        "id": source["id"],
        "status": "PASS" if complete else "FAIL",
        "layers": {
            "structural": dict(layer),
            "functional": dict(layer),
            "physical": dict(layer),
        },
    })

model = {
    "schema": "org.yogabook.validator.report/v1",
    "validator": {"version": "9.9.0"},
    "run": {
        "command": "dossier",
        "finished": datetime.now(timezone.utc).isoformat(),
        "physical_acceptance_result": "PASS",
    },
    "environment": {"device": "Lenovo YB1-X91L"},
    "integrity": {"status": "PASS"},
    "package_inventory": {
        "complete": True,
        "validator_version_matches": True,
    },
    "acceptance": {
        "matrix": {"sha256": matrix_sha},
        "summary": {
            "completion_ready": complete,
            "components_total": len(components),
            "components_complete": len(components) if complete else 0,
        },
        "components": components,
        "execution_plan": {
            "integrity_blocking": False,
            "actions_total": 0 if complete else 1,
            "actions": [] if complete else [{"id": "fixture-failure"}],
        },
    },
    "evidence": evidence,
}
(report_dir / "report.json").write_text(
    json.dumps(model, indent=2) + "\n", encoding="utf-8"
)
PY
chmod 0755 "$fixture_package_root/usr/libexec/yogabook-validator/yogabook-validator-report.py"
dpkg-deb --build --root-owner-group "$fixture_package_root" "$fixture_deb" >/dev/null

fixture_sha=$(sha256sum "$fixture_deb" | awk '{print $1}')
printf '%s\t%s\n' "$fixture_sha" "${fixture_deb##*/}" \
  > "$fixture_root/manifests/yogabook-release-debs.tsv"

write_raw_result() {
  local status=$1
  printf 'timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n' \
    > "$fixture_report/results.tsv"
  printf '2026-08-31T00:00:00Z\tfixture\tpass\t%s\tfixture result\t\n' "$status" \
    >> "$fixture_report/results.tsv"
  printf 'Yoga Book Validator 9.9.0\nCommand: dossier\n' \
    > "$fixture_report/validator.log"
  printf 'key\tvalue\ndevice\tLenovo YB1-X91L\n' \
    > "$fixture_report/environment.tsv"
  printf 'schema\torg.yogabook.validator.state/v1\n' \
    > "$fixture_report/state-before.tsv"
  printf 'schema\torg.yogabook.validator.state/v1\n' \
    > "$fixture_report/state-after.tsv"
}

promote() {
  "$fixture_root/scripts/promote-validated-stack.sh" \
    "$fixture_report" "$fixture_output" "$fixture_deb"
}

write_raw_result PASS
printf '{"forged":true}\n' > "$fixture_report/report.json"
promote > "$temporary_directory/positive.out"
cmp -s "$fixture_report/validated-packages.tsv" "$fixture_output"
grep -Fq 'Promoted trusted complete physical-acceptance inventory' \
  "$temporary_directory/positive.out"

write_raw_result FAIL
printf '{"schema":"org.yogabook.validator.report/v1","forged_pass":true}\n' \
  > "$fixture_report/report.json"
printf 'preserve-on-failure\n' > "$fixture_output"
if promote > "$temporary_directory/raw-failure.out" 2>&1; then
  printf 'FAIL: negative raw evidence was accepted through a forged report\n' >&2
  exit 1
fi
grep -Fxq 'preserve-on-failure' "$fixture_output"
grep -Fq 'trusted regeneration does not prove' "$temporary_directory/raw-failure.out"

write_raw_result PASS
printf 'preserve-before-race\n' > "$fixture_output"
shim_directory="$temporary_directory/shims"
mkdir "$shim_directory"
cat > "$shim_directory/sync" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -f && ${2:-} == */.validated-packages.* && -n ${RACE_OUTPUT:-} ]]; then
  mv -T -- "$RACE_OUTPUT" "$RACE_OUTPUT.previous"
  mkdir -- "$RACE_OUTPUT"
fi
exec /usr/bin/sync "$@"
SH
chmod 0755 "$shim_directory/sync"
if PATH="$shim_directory:$PATH" RACE_OUTPUT="$fixture_output" promote \
  > "$temporary_directory/race.out" 2>&1; then
  printf 'FAIL: output type race produced a false promotion success\n' >&2
  exit 1
fi
[[ -d $fixture_output ]]
[[ -z $(find "$fixture_output" -mindepth 1 -print -quit) ]]
grep -Fxq 'preserve-before-race' "$fixture_output.previous"
if find "$temporary_directory" -name '.validated-packages.*' -print -quit | grep -q .; then
  printf 'FAIL: promotion race left a temporary manifest behind\n' >&2
  exit 1
fi
if grep -Fq 'Promoted trusted' "$temporary_directory/race.out"; then
  printf 'FAIL: promotion race printed a false success message\n' >&2
  exit 1
fi

printf 'Verified trusted positive promotion, raw-evidence regeneration, and atomic race failure.\n'
