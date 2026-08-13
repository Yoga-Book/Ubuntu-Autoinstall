#!/bin/sh
set -eu

PACKAGE_DIR="${1:?Usage: package-manifest.sh PACKAGE_DIR}"

if ! find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print -quit | grep -q .; then
  echo "Error: no Debian packages found in $PACKAGE_DIR" >&2
  exit 1
fi

for package_file in "$PACKAGE_DIR"/*.deb; do
  package_name="$(dpkg-deb -f "$package_file" Package)"
  package_version="$(dpkg-deb -f "$package_file" Version)"
  package_architecture="$(dpkg-deb -f "$package_file" Architecture)"
  package_sha256="$(sha256sum "$package_file" | awk '{print $1}')"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$package_name" "$package_version" "$package_architecture" \
    "$(basename "$package_file")" "$package_sha256"
done | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2V
