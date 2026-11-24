#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/alpenglow-release-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/scripts/lib" "${tmp}/build/native" "${tmp}/bin"
cp "${root}/scripts/build-release.sh" "${tmp}/scripts/"
cp "${root}/scripts/lib/initramfs-codec-identity.sh" "${tmp}/scripts/lib/"
printf 'old kernel\n' > "${tmp}/build/native/vmlinuz"
printf '\037\213old archive' > "${tmp}/build/native/initramfs.cpio.gz"
printf '\050\265\057\375old' > "${tmp}/build/native/initramfs.cpio.zst"
cat > "${tmp}/scripts/boot-native.sh" <<'EOF'
#!/bin/sh
echo called >> "${PROBE_LOG}"
if [ "${PROBE_SUCCESS:-0}" = 1 ]; then
  kernel="$(dirname "$0")/../build/native/vmlinuz"
  dd if=/dev/zero of="$kernel" bs=1 count=564 2>/dev/null
  printf '\001' >> "$kernel"
  printf '\002\041\114\030new' > "$(dirname "$0")/../build/native/initramfs.cpio.lz4"
  exit 0
fi
exit 71
EOF
cat > "${tmp}/bin/curl" <<'EOF'
#!/bin/sh
echo fetched >> "${PROBE_LOG}"
exit 1
EOF
chmod +x "${tmp}/scripts/boot-native.sh" "${tmp}/bin/curl"
cp "${tmp}/bin/curl" "${tmp}/bin/lz4"
# This fixture tests build failure handling, not the separate kernel architecture gate.
printf '#!/bin/sh\nexit 0\n' > "${tmp}/bin/python3"
chmod +x "${tmp}/bin/python3"
if PATH="${tmp}/bin:${PATH}" PROBE_LOG="${tmp}/calls" sh "${tmp}/scripts/build-release.sh" > "${tmp}/output" 2>&1; then
  echo 'release succeeded after boot build failed' >&2
  exit 1
fi
[ "$(cat "${tmp}/calls")" = called ] || {
  echo 'release proceeded past the failed boot build' >&2
  cat "${tmp}/output" >&2
  exit 1
}
: > "${tmp}/calls"
PATH="${tmp}/bin:${PATH}" PROBE_LOG="${tmp}/calls" PROBE_SUCCESS=1 sh "${tmp}/scripts/build-release.sh" > "${tmp}/output" 2>&1 || true
[ "$(cat "${tmp}/calls")" = "$(printf 'called\nfetched')" ] || {
  echo 'release did not reach the fetch after a successful boot build' >&2
  cat "${tmp}/output" >&2
  exit 1
}
cmp "${tmp}/build/native/initramfs.cpio.lz4" "${tmp}/build/release/initramfs.cpio.lz4" || {
  echo 'release did not select the freshly built initramfs' >&2
  exit 1
}
cmp "${tmp}/build/native/vmlinuz" "${tmp}/build/release/vmlinuz" || {
  echo 'release did not select the freshly built kernel' >&2
  exit 1
}
cat > "${tmp}/bin/docker" <<'EOF'
#!/bin/sh
echo docker >> "${PROBE_LOG}"
exit 71
EOF
chmod +x "${tmp}/bin/docker"
touch -t 200001010000 "${tmp}/build/native/initramfs.cpio.lz4"
touch "${tmp}/build/native/vmlinuz" "${tmp}/build/native/.kernel-fast.ok"
: > "${tmp}/calls"
if PATH="${tmp}/bin:${PATH}" PROBE_LOG="${tmp}/calls" KERNEL_BUILD=1 KERNEL_VERSION=7.1.3 sh "${root}/system/backends/appliance/scripts/build-kernel-fast.sh" "${tmp}/build/native" "${root}" > "${tmp}/output" 2>&1; then
  echo 'fast kernel build accepted the cached kernel' >&2
  exit 1
fi
[ "$(cat "${tmp}/calls")" = docker ] || {
  echo 'fast kernel build did not invoke Docker' >&2
  cat "${tmp}/output" >&2
  exit 1
}
# A failed requested service build must stop even when old binaries exist.
sed -n '/^# Build userspace services$/,/^if \[ "${GRAPHICAL}" = "1" \]; then$/p' "${root}/scripts/boot-native.sh" |
  sed '$d' > "${tmp}/services.sh"
cat > "${tmp}/bin/docker" <<'EOF'
#!/bin/sh
count=$(cat "${PROBE_LOG}" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s' "$count" > "${PROBE_LOG}"
[ "$count" -ne "$PROBE_FAIL_AT" ] || exit 71
EOF
chmod +x "${tmp}/bin/docker"
for binary in iwd/usr/libexec/iwd greetd/usr/bin/greetd dropbear/usr/bin/dropbear chrony/usr/sbin/chronyd dnsmasq/usr/sbin/dnsmasq; do
  mkdir -p "${tmp}/build/native/$(dirname "$binary")"
  printf 'stale binary\n' > "${tmp}/build/native/${binary}"
done
for fail_at in 1 2 3 4 5; do
  printf 0 > "${tmp}/calls"
  status=0
  PATH="${tmp}/bin:${PATH}" PROBE_LOG="${tmp}/calls" PROBE_FAIL_AT="$fail_at" \
    BUILD_SERVICES=1 OUT_DIR="${tmp}/build/native" ROOT_DIR="${root}" \
    sh -eu "${tmp}/services.sh" > "${tmp}/output" 2>&1 || status=$?
  [ "$status" -eq 71 ] && [ "$(cat "${tmp}/calls")" -eq "$fail_at" ] || {
    echo "service build $fail_at failure was masked (status $status)" >&2
    cat "${tmp}/output" >&2
    exit 1
  }
done
echo 'release stops on failure and selects the freshly built initramfs'
