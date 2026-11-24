#!/bin/sh
# Exercise the shell init's actual mount dispatch without mounting a filesystem.
set -eu
root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
dispatch="$(sed -n '/^case "${ROOT_IMAGE}" in$/,/^esac$/p' "${root}/system/backends/appliance/initramfs/init")"
[ -n "${dispatch}" ] || { echo 'root mount dispatch missing' >&2; exit 1; }
for format in erofs squashfs; do
  for result in 0 23; do
    status=0
    sh -eu -c '
      ROOT_IMAGE="/sysroot/root.$1"
      result="$2"
      rescue_or_halt() { echo "$1" >&2; exit 42; }
      # Validate mount arguments as well as failure propagation.
      mount() {
        [ "$1" = -t ] && [ "$2" = "$format" ] && [ "$3" = -o ] &&
          [ "$4" = ro,nodev ] && [ "$5" = "$ROOT_IMAGE" ] && [ "$6" = /mnt/root ] || exit 43
        return "$result"
      }
      format="$1"
      eval "$3"
    ' init-test "${format}" "${result}" "${dispatch}" || status=$?
    expected=0
    [ "${result}" -eq 0 ] || expected=42
    [ "${status}" -eq "${expected}" ] || {
      echo "${format}: mount status ${result} exited ${status}, expected ${expected}" >&2
      exit 1
    }
  done
done
assignment="$(sed -n '/^ROOT_DIR=/p' "${root}/scripts/build-initramfs.sh")"
actual="$(sh -eu -c "${assignment}; printf '%s' \"\${ROOT_DIR}\"" "${root}/scripts/build-initramfs.sh")"
[ "${actual}" = "${root}" ] || { echo "initramfs builder resolved wrong root: ${actual}" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/vda3" "$tmp/vda4"
printf 'DEVNAME=vda3\nPARTNAME=state.data\n' > "$tmp/vda3/uevent"
printf 'DEVNAME=vda4\nPARTNAME=stateXdata\n' > "$tmp/vda4/uevent"
for resolver in system/backends/appliance/initramfs/init system/backends/appliance/scripts/mount-state.sh; do
  functions=$(sed -n '/^partname_dev() {$/,/^state_is_luks() {$/p' "${root}/${resolver}" | sed '$d')
  SYSFS_BLOCK="$tmp" sh -eu -c '
    eval "$1"
    [ "$(state_block_dev PARTLABEL=state.data)" = /dev/vda3 ]
    [ -z "$(state_block_dev PARTLABEL=state.missing)" ]
    [ "$(state_block_dev /dev/mapper/state)" = /dev/mapper/state ]
  ' resolver-test "$functions"
done
echo 'shell init mount failures enter recovery; builder resolves repository root'
