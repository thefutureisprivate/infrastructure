#!/usr/bin/bash
set -euo pipefail

readonly version="20260817.0"
readonly archive="gvisor.tar.bz2"
readonly archive_url="https://storage.googleapis.com/gvisor/releases/release/${version}/x86_64/${archive}"
readonly archive_sha512="bd8271a7742f90e53373b2a8613f37f3ae2c765ff5e2e611a75a47167a323cab7519b149c50273307743491713525a14ad1b3e398651c93b16f3e248dfeff3dd"
readonly marker="/usr/local/share/gvisor/${version}.sha512"
readonly -a sidecars=(
  checkpointgofer
  gvisor-sentry-prewarmer
  gvisor_sentry
  runsc-metric-server
)

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

rm -rf -- staging
install -d -m 0700 staging staging/sidecars
tar --extract --bzip2 --file "${archive}" --directory staging --no-same-owner \
  runsc containerd-shim-runsc-v1
sidecar_members=()
for sidecar in "${sidecars[@]}"; do
  sidecar_members+=("gvisor-bin/${sidecar}")
done
tar --extract --bzip2 --file "${archive}" --directory staging/sidecars \
  --no-same-owner --strip-components=1 "${sidecar_members[@]}"
test -x staging/runsc
test -x staging/containerd-shim-runsc-v1
for sidecar in "${sidecars[@]}"; do
  test -x "staging/sidecars/${sidecar}"
done

install -d -m 0755 /usr/local/bin/gvisor-bin
install -m 0755 staging/runsc /usr/local/bin/runsc.new
install -m 0755 \
  staging/containerd-shim-runsc-v1 \
  /usr/local/bin/containerd-shim-runsc-v1.new
mv --force /usr/local/bin/runsc.new /usr/local/bin/runsc
mv --force \
  /usr/local/bin/containerd-shim-runsc-v1.new \
  /usr/local/bin/containerd-shim-runsc-v1
for sidecar in "${sidecars[@]}"; do
  install -m 0755 \
    "staging/sidecars/${sidecar}" \
    "/usr/local/bin/gvisor-bin/${sidecar}.new"
  mv --force \
    "/usr/local/bin/gvisor-bin/${sidecar}.new" \
    "/usr/local/bin/gvisor-bin/${sidecar}"
done
restorecon -RF \
  /usr/local/bin/runsc \
  /usr/local/bin/containerd-shim-runsc-v1 \
  /usr/local/bin/gvisor-bin

printf '%s\n' "${archive_sha512}" > "${marker}.new"
chmod 0644 "${marker}.new"
mv --force "${marker}.new" "${marker}"
restorecon -F "${marker}"
