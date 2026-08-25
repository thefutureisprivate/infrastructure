#!/usr/bin/bash
set -euo pipefail

readonly version="20260817.0"
readonly archive="gvisor.tar.bz2"
readonly archive_url="https://storage.googleapis.com/gvisor/releases/release/${version}/x86_64/${archive}"
readonly archive_sha512="bd8271a7742f90e53373b2a8613f37f3ae2c765ff5e2e611a75a47167a323cab7519b149c50273307743491713525a14ad1b3e398651c93b16f3e248dfeff3dd"
readonly marker="/usr/local/share/gvisor/${version}.sha512"

if [[ -x /usr/local/bin/runsc ]] && grep --fixed-strings --line-regexp --quiet "${archive_sha512}" "${marker}" 2>/dev/null; then
  exit 0
fi

install -d -m 0755 /usr/local/bin /usr/local/share/gvisor
curl \
  --fail \
  --location \
  --proto '=https' \
  --retry 5 \
  --retry-all-errors \
  --show-error \
  --silent \
  --tlsv1.2 \
  --output "${archive}" \
  "${archive_url}"
printf '%s  %s\n' "${archive_sha512}" "${archive}" | sha512sum --check --strict -

install -d -m 0700 staging
tar --extract --bzip2 --file "${archive}" --directory staging --no-same-owner
test -x staging/runsc
test -x staging/containerd-shim-runsc-v1
test -d staging/gvisor-bin
cp --archive staging/. /usr/local/bin/
restorecon -RF \
  /usr/local/bin/runsc \
  /usr/local/bin/containerd-shim-runsc-v1 \
  /usr/local/bin/gvisor-bin
/usr/local/bin/runsc --version

printf '%s\n' "${archive_sha512}" > "${marker}.new"
chmod 0644 "${marker}.new"
mv --force "${marker}.new" "${marker}"
restorecon -F "${marker}"
