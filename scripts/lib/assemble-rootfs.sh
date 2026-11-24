#!/bin/sh
# Shared rootfs assembly for boot-native.sh.
# FAST/minimal: lean toybox dinit units. standard/desktop: configure-rootfs.sh + QEMU serial.
# Expects ROOTFS_DIR, OUT_DIR, ROOT_DIR, BACKEND_DIR, BUILD_PROFILE, FAST, and toybox_has.
set -eu

_assemble_qemu_mount_units() {
  mkdir -p "${ROOTFS_DIR}/etc/dinit.d"
  cat > "${ROOTFS_DIR}/etc/dinit.d/shell-ttyS0" << 'SHELL'
type = process
command = /bin/toybox getty -L -l /usr/local/bin/alpenglow-login 115200 ttyS0 vt100
restart = yes
depends-on = mount-filesystems
SHELL

  cat > "${ROOTFS_DIR}/etc/dinit.d/mount-filesystems" << 'MOUNT'
type = scripted
command = /bin/toybox sh -c "/bin/toybox mount -t proc proc /proc; /bin/toybox mount -t sysfs sysfs /sys; /bin/toybox mount -t devtmpfs devtmpfs /dev; /bin/toybox mount -t tmpfs -o nosuid,nodev,mode=0755 tmpfs /run"
restart = no
MOUNT
}

_assemble_minimal_toybox_networking() {
  cat > "${ROOTFS_DIR}/etc/dinit.d/networking" << 'NET'
type = scripted
command = /bin/toybox udhcpc -i eth0 -s /usr/share/udhcpc/default.script -q
restart = yes
depends-on = mount-filesystems
NET
}

_assemble_minimal_toybox_syslogd() {
  cat > "${ROOTFS_DIR}/etc/dinit.d/syslogd" << 'SYSLOG'
type = process
command = /bin/toybox syslogd -n
restart = yes
depends-on = mount-filesystems
SYSLOG
}

_assemble_minimal_toybox_crond() {
  cat > "${ROOTFS_DIR}/etc/dinit.d/crond" << 'CROND'
type = process
command = /bin/toybox crond -n
restart = yes
depends-on = syslogd
CROND
}

# Write base entries to an /etc database, keeping entries already there
# (configure-rootfs.sh adds service users before this runs).
_merge_etc_db() {
  db="${ROOTFS_DIR}/etc/$1"
  base="$(cat)"
  old=""
  [ -f "${db}" ] && old="$(cat "${db}")"
  {
    printf '%s\n' "${base}"
    printf '%s\n' "${old}" | while IFS= read -r line; do
      [ -n "${line}" ] || continue
      printf '%s\n' "${base}" | grep -q "^${line%%:*}:" || printf '%s\n' "${line}"
    done
  } > "${db}.new"
  mv "${db}.new" "${db}"
}

_assemble_boot_native_passwd() {
  mkdir -p "${ROOTFS_DIR}/etc"
  _merge_etc_db passwd << 'PASSWD'
root:x:0:0:root:/root:/bin/sh
seatd:x:772:772:seatd:/var/empty:/sbin/nologin
PASSWD
  # Root ships locked ('!'): the first console login sets a password
  # (alpenglow-login). An empty field would let anyone in without one.
  _merge_etc_db shadow << 'SHADOW'
root:!:19999:0:99999:7:::
SHADOW
  chmod 600 "${ROOTFS_DIR}/etc/shadow"
  _merge_etc_db group << 'GROUP'
root:x:0:
wheel:x:10:
daemon:x:1:
bin:x:2:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
lp:x:7:
mail:x:8:
news:x:9:
uucp:x:10:
man:x:12:
proxy:x:13:
kmem:x:15:
dialout:x:20:
fax:x:21:
voice:x:22:
cdrom:x:24:
floppy:x:25:
tape:x:26:
sudo:x:27:
audio:x:29:pipewire
video:x:44:seatd
input:x:777:
seatd:x:772:
iwd:x:773:
pipewire:x:774:
GROUP
}

_assemble_common_rootfs_tail() {
  mkdir -p "${ROOTFS_DIR}/usr/share/udhcpc"
  cat > "${ROOTFS_DIR}/usr/share/udhcpc/default.script" << 'SCRIPT'
#!/bin/toybox sh
case "$1" in
  bound|renew) /bin/toybox ifconfig $interface $ip netmask $subnet; /bin/toybox route add default gw $router 2>/dev/null;;
  deconfig) /bin/toybox ifconfig $interface 0.0.0.0;;
esac
SCRIPT
  chmod 755 "${ROOTFS_DIR}/usr/share/udhcpc/default.script"

  mkdir -p "${ROOTFS_DIR}/root"
  mkdir -p "${ROOTFS_DIR}/lib/modules"
  if [ -f "${ALPENGLOW_MODULE}" ]; then
    cp "${ALPENGLOW_MODULE}" "${ROOTFS_DIR}/lib/modules/"
  fi

  if [ "${ZIG_INIT:-0}" = "1" ]; then
    [ -f "${OUT_DIR}/alpenglow-init" ] || { echo "ERROR: requested Zig init is missing" >&2; return 1; }
    cp "${OUT_DIR}/alpenglow-init" "${ROOTFS_DIR}/init"
    chmod 755 "${ROOTFS_DIR}/init"
  else
    cat > "${ROOTFS_DIR}/init" << 'INIT'
#!/bin/toybox sh
/bin/toybox mount -t proc proc /proc
/bin/toybox mount -t sysfs sysfs /sys
/bin/toybox mount -t devtmpfs devtmpfs /dev
exec </dev/ttyS0 >/dev/ttyS0 2>&1
/bin/toybox mount -t tmpfs -o nosuid,nodev,mode=0755 tmpfs /run
/bin/toybox mkdir -p /dev/shm /tmp 2>/dev/null
/bin/toybox chmod 01777 /dev/shm /tmp
SHM_SIZE="mode=1777,size=256m"
if [ -r /proc/meminfo ]; then
  mem_total_kb=""
  while read -r key value _; do
    [ "$key" = "MemTotal:" ] && { mem_total_kb="$value"; break; }
  done < /proc/meminfo
  if [ -n "$mem_total_kb" ]; then
    SHM_SIZE="mode=1777,size=$((mem_total_kb / 2))k"
  fi
fi
/bin/toybox mount -t tmpfs -o nosuid,nodev,"$SHM_SIZE" tmpfs /dev/shm
/bin/toybox mount -t tmpfs -o nosuid,nodev,mode=1777 tmpfs /tmp
/bin/toybox mkdir -p /run/user/0
/bin/toybox chown 0:0 /run/user/0
/bin/toybox chmod 700 /run/user/0
/bin/toybox mkdir -p /state
# Try to mount state partition (if available)
state_dev=""
for arg in $(cat /proc/cmdline); do
  case "$arg" in
    alpenglow.state=LABEL=*) state_dev="/dev/disk/by-label/${arg#alpenglow.state=LABEL=}" ;;
    alpenglow.state=*) state_dev="${arg#alpenglow.state=}" ;;
  esac
done
if [ -z "$state_dev" ]; then
  state_dev="/dev/disk/by-label/alpenglow-state"
fi
if [ -b "$state_dev" ]; then
  /bin/toybox mount -t bcachefs -o rw,nosuid,nodev "$state_dev" /state 2>/dev/null && echo "Mounted state: $state_dev"
fi
echo ""
echo "Alpenglow boot"
echo ""
# Log memory at boot for benchmark
if [ -f /proc/meminfo ]; then
  /bin/toybox grep -E 'MemTotal|MemFree' /proc/meminfo 2>/dev/null
fi
exec /sbin/dinit -d /etc/dinit.d -s -t boot
INIT
    chmod 755 "${ROOTFS_DIR}/init"
  fi

  mknod -m 622 "${ROOTFS_DIR}/dev/console" c 5 1 2>/dev/null || true
  mknod -m 666 "${ROOTFS_DIR}/dev/null" c 1 3 2>/dev/null || true
  mknod -m 666 "${ROOTFS_DIR}/dev/zero" c 1 5 2>/dev/null || true
  mknod -m 444 "${ROOTFS_DIR}/dev/random" c 1 8 2>/dev/null || true
  mknod -m 444 "${ROOTFS_DIR}/dev/urandom" c 1 9 2>/dev/null || true

  echo "alpenglow" > "${ROOTFS_DIR}/etc/hostname"
  _assemble_login

  mkdir -p "${ROOTFS_DIR}/root/.ssh"
  chmod 700 "${ROOTFS_DIR}/root/.ssh"
}

_assemble_minimal_configs() {
  _assemble_boot_native_passwd

  cat > "${ROOTFS_DIR}/etc/hosts" << 'HOSTS'
127.0.0.1 localhost
127.0.1.1 alpenglow
::1       localhost ip6-localhost ip6-loopback
ff02::1   ip6-allnodes
ff02::2   ip6-allrouters
HOSTS

  mkdir -p "${ROOTFS_DIR}/etc/chrony"
  cat > "${ROOTFS_DIR}/etc/chrony/chrony.conf" << 'CHRONY'
pool pool.ntp.org iburst
makestep 1.0 3
rtcsync
cmdport 0
bindcmdaddress 127.0.0.1
bindcmdaddress ::1
CHRONY

  cat > "${ROOTFS_DIR}/etc/dnsmasq.conf" << 'DNSMASQ'
listen-address=127.0.0.1
bind-interfaces
port=53
domain-needed
bogus-priv
no-resolv
server=1.1.1.1
server=8.8.8.8
cache-size=1000
DNSMASQ

  mkdir -p "${ROOTFS_DIR}/etc/crontabs"
  cat > "${ROOTFS_DIR}/etc/crontabs/root" << 'CRONT'
0 0 * * * /usr/local/bin/logrotate.sh >/dev/null 2>&1
CRONT
  chmod 600 "${ROOTFS_DIR}/etc/crontabs/root"

  cat > "${ROOTFS_DIR}/usr/local/bin/logrotate.sh" << 'LOGX'
#!/bin/toybox sh
for log in /var/log/alpenglow/*.log; do
  [ -f "${log}" ] || continue
  mv "${log}" "${log}.old" 2>/dev/null || true
done
LOGX
  chmod 755 "${ROOTFS_DIR}/usr/local/bin/logrotate.sh"
}

# Console login wrapper used by every edition's getty.
_assemble_login() {
  mkdir -p "${ROOTFS_DIR}/usr/local/bin"
  cat > "${ROOTFS_DIR}/usr/local/bin/alpenglow-login" << 'LOGIN'
#!/bin/toybox sh
# Root ships locked. The first console login sets its password; with /state
# mounted, shadow points at persistent storage for subsequent password changes.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
saved=/state/etc/root-shadow
state_mounted() { grep -q ' /state ' /proc/mounts; }
# A fresh boot has the image's locked root: keep the saved root entry while
# retaining the current image's other accounts. BusyBox follows this symlink
# when atomically replacing shadow, including passwd and chpasswd updates.
if state_mounted && [ "$(/bin/busybox readlink /etc/shadow 2>/dev/null)" != "${saved}" ]; then
  mkdir -p /state/etc && chmod 700 /state/etc || exit 1
  old_umask=$(umask)
  umask 077
  if [ -s "${saved}" ]; then
    { grep '^root:' "${saved}"; grep -v '^root:' /etc/shadow || true; } > "${saved}.new" || exit 1
  else
    cat /etc/shadow > "${saved}.new" || exit 1
  fi
  chmod 600 "${saved}.new" && mv "${saved}.new" "${saved}" &&
    ln -sf "${saved}" /etc/shadow || exit 1
  umask "${old_umask}"
fi
if grep -q '^root:!:' /etc/shadow; then
  echo "First login on this machine: choose a root password."
  tries=0
  # Toybox account applets can truncate the database; use the checked BusyBox applet.
  until /bin/busybox passwd -a sha512 root; do
    tries=$((tries + 1))
    [ "${tries}" -lt 5 ] || { echo "Could not set a password; root stays locked."; break; }
    sleep 1
  done
  state_mounted || echo "No /state mounted: this password lasts until reboot."
fi
exec /bin/toybox login "$@"
LOGIN
  chmod 755 "${ROOTFS_DIR}/usr/local/bin/alpenglow-login"
}

# Network services and Oil built by boot-native.sh (world file / BUILD_SERVICES).
_assemble_network_payloads() {
  for svc in dropbear chrony dnsmasq sdhcp; do
    [ -d "${OUT_DIR}/${svc}" ] && cp -R "${OUT_DIR}/${svc}/." "${ROOTFS_DIR}/"
  done
  [ -d "${OUT_DIR}/dropbear" ] && mkdir -p "${ROOTFS_DIR}/etc/dropbear"
  [ -d "${OUT_DIR}/chrony" ] && mkdir -p "${ROOTFS_DIR}/etc/chrony"
  if [ "${FAST:-0}" != "1" ] && [ -f "${OUT_DIR}/oil" ]; then
    mkdir -p "${ROOTFS_DIR}/usr/local/bin"
    cp "${OUT_DIR}/oil" "${ROOTFS_DIR}/usr/local/bin/oil"
    chmod 755 "${ROOTFS_DIR}/usr/local/bin/oil"
  fi
  return 0
}

# Where `oil install` puts packages (/opt/oil, bound from /state/oil): make
# them runnable from the RAM root without touching it at runtime.
_assemble_oil_runtime() {
  [ -f "${ROOTFS_DIR}/usr/local/bin/oil" ] || return 0
  mkdir -p "${ROOTFS_DIR}/opt/oil" "${ROOTFS_DIR}/lib" "${ROOTFS_DIR}/etc/profile.d"
  # Alpine binaries load /lib/ld-musl-x86_64.so.1; the musl package puts it
  # under /opt/oil/lib. Static images have no loader of their own.
  if [ ! -e "${ROOTFS_DIR}/lib/ld-musl-x86_64.so.1" ] && [ ! -L "${ROOTFS_DIR}/lib/ld-musl-x86_64.so.1" ]; then
    ln -s /opt/oil/lib/ld-musl-x86_64.so.1 "${ROOTFS_DIR}/lib/ld-musl-x86_64.so.1"
  fi
  printf '%s\n' /opt/oil/lib /opt/oil/usr/lib /lib /usr/lib /usr/local/lib \
    > "${ROOTFS_DIR}/etc/ld-musl-x86_64.path"
  cat > "${ROOTFS_DIR}/etc/profile.d/oil.sh" << 'OILPATH'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/oil/usr/sbin:/opt/oil/usr/bin:/opt/oil/sbin:/opt/oil/bin"
export PATH
OILPATH
  if [ ! -f "${ROOTFS_DIR}/etc/profile" ]; then
    cat > "${ROOTFS_DIR}/etc/profile" << 'PROFILE'
for f in /etc/profile.d/*.sh; do [ -r "$f" ] && . "$f"; done
PROFILE
  fi
}

# Units for potato/internet (minimal profile, not fast): /state, DHCP and
# the network services their world asks for. Services start without an
# address and pick it up once DHCP binds, so nothing blocks boot offline.
_assemble_lean_service_units() {
  d="${ROOTFS_DIR}/etc/dinit.d"
  mkdir -p "${d}" "${ROOTFS_DIR}/usr/local/bin" "${ROOTFS_DIR}/etc/dropbear"
  cp "${BACKEND_DIR}/scripts/mount-state.sh" "${BACKEND_DIR}/scripts/mount-state-paths.sh" \
    "${ROOTFS_DIR}/usr/local/bin/"
  chmod 755 "${ROOTFS_DIR}/usr/local/bin/mount-state.sh"
  for dir in home var/lib/alpenglow var/cache/alpenglow var/log/alpenglow; do
    mkdir -p "${ROOTFS_DIR}/${dir}"
  done
  # Edition kernel policy (editions.toml kernel_policy) and zram swap.
  [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-kernelctl" ] && cp "${BACKEND_DIR}/dinit/alpenglow-kernel-policy" "${d}/"
  [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-zramctl-zig" ] && cp "${BACKEND_DIR}/dinit/alpenglow-zram" "${d}/"
  # The console waits for the /state attempt so the first-login password can
  # be kept there. Release images require state; dev boots may stay RAM-only.
  if [ "${ALPENGLOW_REQUIRE_STATE:-0}" != "1" ]; then
    printf 'waits-for = state-mount\n' >> "${d}/shell-ttyS0"
    # Diskless boots are valid: no state partition means RAM-only, said aloud.
    cat > "${d}/state-mount" << 'UNIT'
type = scripted
command = /bin/toybox sh -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; /usr/local/bin/mount-state.sh || echo 'alpenglow: /state not mounted; changes last until reboot'"
restart = no
depends-on = mount-filesystems
UNIT
  fi
  resolv_flag=""
  if [ -x "${ROOTFS_DIR}/usr/sbin/dnsmasq" ]; then
    resolv_flag="-d"
    echo "nameserver 127.0.0.1" > "${ROOTFS_DIR}/etc/resolv.conf"
  fi
  if [ -x "${ROOTFS_DIR}/usr/sbin/sdhcp" ]; then
    cat > "${d}/networking" << UNIT
type = scripted
command = /bin/toybox sh -c "/bin/toybox ifconfig lo 127.0.0.1 up; /bin/toybox ifconfig eth0 up; /usr/sbin/sdhcp ${resolv_flag} eth0 &"
restart = no
depends-on = mount-filesystems
UNIT
  fi
  if [ -x "${ROOTFS_DIR}/usr/sbin/dropbear" ]; then
    # Host keys and root's authorized_keys live on /state when it is mounted.
    cat > "${d}/dropbear" << 'UNIT'
type = process
command = /bin/toybox sh -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; if grep -q ' /state ' /proc/mounts && ! grep -q ' /etc/dropbear ' /proc/mounts; then mkdir -p /state/etc/dropbear && mkdir -p -m 700 /state/root-ssh && mount --bind /state/etc/dropbear /etc/dropbear && mount --bind /state/root-ssh /root/.ssh; fi; exec /usr/sbin/dropbear -F -R -s"
restart = yes
depends-on = state-mount
UNIT
    [ ! -f "${d}/networking" ] || echo 'waits-for = networking' >> "${d}/dropbear"
  fi
  if [ -x "${ROOTFS_DIR}/usr/sbin/chronyd" ]; then
    cat > "${d}/chronyd" << 'UNIT'
type = process
command = /usr/sbin/chronyd -d -s -u chrony -f /etc/chrony/chrony.conf
restart = yes
UNIT
    [ ! -f "${d}/networking" ] || echo 'waits-for = networking' >> "${d}/chronyd"
  fi
  if [ -x "${ROOTFS_DIR}/usr/sbin/dnsmasq" ]; then
    cat > "${d}/dnsmasq" << 'UNIT'
type = process
command = /usr/sbin/dnsmasq -k -u dnsmasq -C /etc/dnsmasq.conf
restart = yes
UNIT
    [ ! -f "${d}/networking" ] || echo 'waits-for = networking' >> "${d}/dnsmasq"
  fi
  _merge_etc_db passwd << 'PASSWD'
chrony:x:776:776:chrony:/var/empty:/sbin/nologin
dnsmasq:x:781:781:dnsmasq:/var/empty:/sbin/nologin
PASSWD
  _merge_etc_db group << 'GROUP'
chrony:x:776:
dnsmasq:x:781:
GROUP
}

_wire_boot_services() {
  mkdir -p "${ROOTFS_DIR}/etc/dinit.d/boot.d"
  for svc in ${BOOT_SERVICES}; do
    ln -sf "/etc/dinit.d/${svc}" "${ROOTFS_DIR}/etc/dinit.d/boot.d/${svc}" 2>/dev/null || true
  done
  # waits-for: one failing service must not stop the console with it.
  # Release images explicitly require their persistent state mount.
  {
    echo "type = scripted"
    echo "command = /bin/true"
    echo "restart = no"
    for svc in ${BOOT_SERVICES}; do
      if [ "${svc}" = state-mount ] && [ "${ALPENGLOW_REQUIRE_STATE:-0}" = "1" ]; then
        echo "depends-on = ${svc}"
      else
        echo "waits-for = ${svc}"
      fi
    done
  } > "${ROOTFS_DIR}/etc/dinit.d/boot"
}

_assemble_native_boot_services() {
  case "${BUILD_PROFILE}" in
    minimal)
      # boot + SSH + time + logs; each only if its binary was built.
      BOOT_SERVICES="shell-ttyS0 mount-filesystems state-mount"
      [ -f "${ROOTFS_DIR}/etc/dinit.d/networking" ] && [ -x "${ROOTFS_DIR}/usr/sbin/sdhcp" ] && BOOT_SERVICES="${BOOT_SERVICES} networking"
      toybox_has syslogd && BOOT_SERVICES="${BOOT_SERVICES} syslogd"
      toybox_has crond && BOOT_SERVICES="${BOOT_SERVICES} crond"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-kernelctl" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-kernel-policy"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-zramctl-zig" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-zram"
      [ -x "${ROOTFS_DIR}/usr/sbin/dropbear" ] && BOOT_SERVICES="${BOOT_SERVICES} dropbear"
      [ -x "${ROOTFS_DIR}/usr/sbin/chronyd" ] && BOOT_SERVICES="${BOOT_SERVICES} chronyd"
      [ -x "${ROOTFS_DIR}/usr/sbin/dnsmasq" ] && BOOT_SERVICES="${BOOT_SERVICES} dnsmasq"
      ;;
    standard)
      BOOT_SERVICES="shell-ttyS0 mount-filesystems networking syslogd crond"
      toybox_has udhcpc || BOOT_SERVICES="$(printf '%s\n' "${BOOT_SERVICES}" | sed 's/ networking//')"
      toybox_has syslogd || BOOT_SERVICES="$(printf '%s\n' "${BOOT_SERVICES}" | sed 's/ syslogd//')"
      toybox_has crond || BOOT_SERVICES="$(printf '%s\n' "${BOOT_SERVICES}" | sed 's/ crond//')"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-kernelctl" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-kernel-policy"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-netd" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-netd"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-zramctl-zig" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-zram"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-pressurectl-zig" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-pressure"
      [ -f "${ROOTFS_DIR}/usr/sbin/dropbear" ] && BOOT_SERVICES="${BOOT_SERVICES} dropbear"
      [ -f "${ROOTFS_DIR}/usr/sbin/chronyd" ] && BOOT_SERVICES="${BOOT_SERVICES} chronyd"
      [ -f "${ROOTFS_DIR}/usr/sbin/dnsmasq" ] && BOOT_SERVICES="${BOOT_SERVICES} dnsmasq"
      ;;
    desktop)
      BOOT_SERVICES="shell-ttyS0 mount-filesystems"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-kernelctl" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-kernel-policy"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-netd" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-netd"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-zramctl-zig" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-zram"
      [ -f "${ROOTFS_DIR}/usr/local/bin/alpenglow-pressurectl-zig" ] && BOOT_SERVICES="${BOOT_SERVICES} alpenglow-pressure"
      if [ "${ALPENGLOW_DESKTOP_FULL}" = "1" ] && [ -f "${ROOTFS_DIR}/usr/bin/greetd" ]; then
        BOOT_SERVICES="${BOOT_SERVICES} greetd"
      elif [ -f "${ROOTFS_DIR}/usr/bin/alpenglowed-bin" ]; then
        BOOT_SERVICES="${BOOT_SERVICES} alpenglowed"
      fi
      ;;
  esac
  # A missing optional binary is expected, not a failure under set -e.
  return 0
}

_assemble_qemu_serial_login() {
  _assemble_qemu_mount_units
  ln -sf "/etc/dinit.d/shell-ttyS0" "${ROOTFS_DIR}/etc/dinit.d/boot.d/shell-ttyS0" 2>/dev/null || true
  if ! grep -q 'depends-on = shell-ttyS0' "${ROOTFS_DIR}/etc/dinit.d/boot" 2>/dev/null; then
    printf 'depends-on = shell-ttyS0\n' >> "${ROOTFS_DIR}/etc/dinit.d/boot"
  fi
  if ! grep -q '^root:' "${ROOTFS_DIR}/etc/passwd" 2>/dev/null; then
    _assemble_boot_native_passwd
  elif ! grep -q '^root:.*:/bin/sh$' "${ROOTFS_DIR}/etc/passwd" 2>/dev/null; then
    sed -i 's|^\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\).*|\1/bin/sh|' "${ROOTFS_DIR}/etc/passwd"
  fi
}

_native_executable() (
  path="$1"
  count=0
  while [ -L "${ROOTFS_DIR}${path}" ]; do
    count=$((count + 1))
    [ "${count}" -le 40 ] || return 1
    target="$(readlink "${ROOTFS_DIR}${path}")"
    case "${target}" in
      /*) path="${target}" ;;
      *) path="${path%/*}/${target}" ;;
    esac
  done
  [ -f "${ROOTFS_DIR}${path}" ] && [ -x "${ROOTFS_DIR}${path}" ]
)

_native_service_runnable() (
  service="$1"
  unit="${ROOTFS_DIR}/etc/dinit.d/${service}"
  [ -f "${unit}" ] || return 1
  command="$(sed -n 's/^[[:space:]]*command[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "${unit}" | head -n 1)"
  [ -n "${command}" ] && _native_executable "${command}" || return 1
  if [ "${command}" = /bin/toybox ]; then
    applet="$(sed -n 's/^[[:space:]]*command[[:space:]]*=[[:space:]]*\/bin\/toybox[[:space:]]\+\([^[:space:]]*\).*/\1/p' "${unit}" | head -n 1)"
    [ -n "${applet}" ] && toybox_has "${applet}" || return 1
  fi
  if [ "$(head -c 2 "${ROOTFS_DIR}${command}" 2>/dev/null || true)" = '#!' ]; then
    interpreter="$(sed -n '1s/^#![[:space:]]*\([^[:space:]]*\).*/\1/p' "${ROOTFS_DIR}${command}")"
    _native_executable "${interpreter}" || return 1
  fi
  case "${service}" in
    mount-filesystems) toybox_has mount || return 1 ;;
    alpenglow-zram) _native_executable /usr/local/bin/alpenglow-zramctl-zig || return 1 ;;
    alpenglowed) _native_executable /usr/bin/alpenglowed-bin || _native_executable /usr/bin/alpenglowed || return 1 ;;
    alpenglowed-lite) _native_executable /usr/bin/alpenglowed-lite || return 1 ;;
    networking)
      if [ "${command}" = /bin/toybox ]; then
        toybox_has ifconfig || return 1
        if [ "${applet}" = udhcpc ]; then
          toybox_has route && _native_executable /usr/share/udhcpc/default.script || return 1
        else
          _native_executable /usr/sbin/sdhcp || return 1
        fi
      fi
      ;;
  esac
  for dependency in $(sed -n 's/^[[:space:]]*waits-for[[:space:]]*=[[:space:]]*//p' "${unit}"); do
    [ -f "${ROOTFS_DIR}/etc/dinit.d/${dependency}" ] || return 1
  done
  for dependency in $(sed -n 's/^[[:space:]]*depends-on[[:space:]]*=[[:space:]]*//p' "${unit}"); do
    case " ${2:-} " in *" ${dependency} "*) return 1 ;; esac
    _native_service_runnable "${dependency}" "${2:-} ${service}" || return 1
  done
)

_assemble_native_filter_services() {
  services="$(sed -n 's/^\(depends-on\|waits-for\) = //p' "${ROOTFS_DIR}/etc/dinit.d/boot")"
  BOOT_SERVICES=""
  for service in ${services}; do
    if [ "${service}" = state-mount ] || _native_service_runnable "${service}"; then
      BOOT_SERVICES="${BOOT_SERVICES} ${service}"
    else
      echo "  skipping unavailable native service: ${service}" >&2
      rm -f "${ROOTFS_DIR}/etc/dinit.d/boot.d/${service}"
    fi
  done
  _wire_boot_services
}

_assemble_native_validate_services() {
  _native_executable /bin/true || { echo 'native boot command is not runnable: /bin/true' >&2; return 1; }
  for service in $(sed -n 's/^\(depends-on\|waits-for\) = //p' "${ROOTFS_DIR}/etc/dinit.d/boot"); do
    if ! _native_service_runnable "${service}"; then
      echo "native boot service is not runnable: ${service}" >&2
      return 1
    fi
  done
}

_assemble_minimal_rootfs() {
  _assemble_qemu_mount_units
  if [ "${ALPENGLOW_REQUIRE_STATE:-0}" = "1" ]; then
    cp "${BACKEND_DIR}/dinit/state-mount" "${ROOTFS_DIR}/etc/dinit.d/state-mount"
    printf '%s\n' 'depends-on = mount-filesystems' >> "${ROOTFS_DIR}/etc/dinit.d/state-mount"
    printf '%s\n' 'depends-on = state-mount' >> "${ROOTFS_DIR}/etc/dinit.d/shell-ttyS0"
    cp "${BACKEND_DIR}/scripts/mount-state.sh" "${BACKEND_DIR}/scripts/mount-state-paths.sh" "${ROOTFS_DIR}/usr/local/bin/"
    mkdir -p "${ROOTFS_DIR}/home" "${ROOTFS_DIR}/var/lib/alpenglow" "${ROOTFS_DIR}/var/cache/alpenglow" "${ROOTFS_DIR}/var/log/alpenglow"
  fi
  if [ "${FAST:-0}" = "1" ]; then
    BOOT_SERVICES="shell-ttyS0 mount-filesystems"
    [ "${ALPENGLOW_REQUIRE_STATE:-0}" != "1" ] || BOOT_SERVICES="state-mount ${BOOT_SERVICES}"
    _wire_boot_services
    _assemble_boot_native_passwd
    _assemble_common_rootfs_tail
    _assemble_native_validate_services
    return
  fi
  _assemble_minimal_toybox_syslogd
  _assemble_minimal_toybox_crond
  _assemble_minimal_configs
  _assemble_network_payloads
  _assemble_lean_service_units
  _assemble_oil_runtime
  _assemble_native_boot_services
  _wire_boot_services
  _assemble_common_rootfs_tail
  _assemble_native_validate_services
}

_assemble_production_rootfs() {
  _assemble_network_payloads
  BUILD_PROFILE="${BUILD_PROFILE}" \
    ALPENGLOW_DESKTOP_FULL="${ALPENGLOW_DESKTOP_FULL:-1}" \
    sh "${BACKEND_DIR}/scripts/configure-rootfs.sh" "${ROOTFS_DIR}"

  _assemble_qemu_serial_login

  if [ ! -f "${ROOTFS_DIR}/etc/dinit.d/mount-filesystems" ]; then
    _assemble_qemu_mount_units
    ln -sf "/etc/dinit.d/mount-filesystems" "${ROOTFS_DIR}/etc/dinit.d/boot.d/mount-filesystems" 2>/dev/null || true
    if ! grep -q 'depends-on = mount-filesystems' "${ROOTFS_DIR}/etc/dinit.d/boot" 2>/dev/null; then
      printf 'depends-on = mount-filesystems\n' >> "${ROOTFS_DIR}/etc/dinit.d/boot"
    fi
  fi

  if ! _native_executable /usr/sbin/sdhcp; then
    if toybox_has udhcpc && toybox_has ifconfig && toybox_has route; then
      _assemble_minimal_toybox_networking
    fi
  fi

  if [ "${BUILD_PROFILE}" = "standard" ] && toybox_has syslogd && ! [ -f "${ROOTFS_DIR}/usr/sbin/syslogd" ]; then
    _assemble_minimal_toybox_syslogd
  fi

  if [ "${BUILD_PROFILE}" = "standard" ] && toybox_has crond && ! [ -f "${ROOTFS_DIR}/usr/sbin/crond" ]; then
    _assemble_minimal_toybox_crond
  fi

  _assemble_oil_runtime
  _assemble_common_rootfs_tail
  if [ -f "${ROOTFS_DIR}/etc/dinit.d/state-mount" ]; then
    printf '%s\n' 'waits-for = state-mount' >> "${ROOTFS_DIR}/etc/dinit.d/shell-ttyS0"
  fi
  _assemble_native_filter_services
  _assemble_native_validate_services
}

assemble_rootfs_config() {
  if [ "${BUILD_PROFILE}" = "minimal" ] || [ "${FAST:-0}" = "1" ]; then
    _assemble_minimal_rootfs
  else
    _assemble_production_rootfs
  fi
}
