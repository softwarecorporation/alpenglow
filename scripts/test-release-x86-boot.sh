#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ ! -s "$1" ]; then
  echo "usage: $0 path/to/release-x86_64.img.zst" >&2
  exit 2
fi

echo 'NOTE: This boot gate does not verify the build host FAT assembly path.'
echo 'NOTE: Experimental FUSE FAT assembly is not verified for release reproducibility.'

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "${root}/scripts/lib/qemu-boot-x86_64.sh"
OVMF_CODE=$(qemu_ovmf_code) || { echo 'missing OVMF firmware' >&2; exit 1; }
OVMF_VARS_TEMPLATE=$(qemu_ovmf_vars "$OVMF_CODE") || { echo 'missing OVMF variable store template' >&2; exit 1; }
export OVMF_CODE OVMF_VARS_TEMPLATE

umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
zstd -dc -- "$1" > "$tmp/disk.img"
export ALPENGLOW_EDITION="${ALPENGLOW_EDITION:-potato}"

python3 - "$tmp" <<'PY'
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time

tmp = sys.argv[1]
firmware = os.environ['OVMF_CODE']
persistent = os.environ['ALPENGLOW_EDITION'] != 'fast'

def run_boot(name, args, serial, command, token, boot, password, wrong_password):
    log = bytearray()
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    deadline = time.monotonic() + 240
    stage = 'connect serial'
    try:
        while True:
            if proc.poll() is not None:
                raise RuntimeError('QEMU exited before the check completed')
            if time.monotonic() >= deadline:
                raise RuntimeError('timed out waiting for ' + stage)
            try:
                conn.connect(serial)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.1)
        conn.settimeout(0.5)
        stage = 'login prompt'
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError('QEMU exited while waiting for ' + stage)
            try:
                data = conn.recv(65536)
            except socket.timeout:
                continue
            if not data:
                raise RuntimeError('serial connection closed while waiting for ' + stage)
            log.extend(data)
            if stage in ('reject wrong password', 'authentication rejected'):
                if b'first login on this machine' in log.lower() or b'new password:' in log.lower():
                    raise RuntimeError('saved password was not restored after reboot')
                if re.search(rb'(?m)(?:^|\n)[^\r\n]*[#$] $', log):
                    raise RuntimeError('wrong-password check unexpectedly reached a root shell')
            if stage == 'login prompt' and b'login:' in log and b'[  OK  ] boot' in log:
                conn.sendall(b'root\n')
                stage = 'provision password' if boot == 0 or not persistent else 'reject wrong password'
                log.clear()
            elif stage == 'provision password' and b'new password:' in log.lower():
                conn.sendall(password.encode() + b'\n')
                stage = 'confirm password'
                log.clear()
            elif stage == 'confirm password' and b'retype password:' in log.lower():
                conn.sendall(password.encode() + b'\n')
                stage = 'authenticate password'
                log.clear()
            elif stage == 'reject wrong password' and b'password:' in log.lower():
                conn.sendall(wrong_password.encode() + b'\n')
                stage = 'authentication rejected'
                log.clear()
            elif stage == 'authentication rejected' and b'login incorrect' in log.lower():
                stage = 'login retry'
                if b'login:' in log:
                    conn.sendall(b'root\n')
                    stage = 'authenticate password'
                    log.clear()
            elif stage == 'login retry' and b'login:' in log:
                conn.sendall(b'root\n')
                stage = 'authenticate password'
                log.clear()
            elif stage == 'authenticate password' and b'password:' in log.lower():
                conn.sendall(password.encode() + b'\n')
                stage = 'root shell prompt'
                log.clear()
            elif stage == 'root shell prompt' and re.search(rb'(?m)(?:^|\n)[^\r\n]*[#$] $', log):
                conn.sendall(command.encode())
                stage = 'bcachefs mount and write verification'
                log.clear()
            elif stage == 'bcachefs mount and write verification' and token.encode() in log:
                if boot == 0:
                    print(name + ': authenticated boot checks passed; rebooting', flush=True)
                    conn.sendall(b'/bin/busybox reboot -f\n')
                    try:
                        status = proc.wait(timeout=120)
                    except subprocess.TimeoutExpired:
                        raise RuntimeError('timed out waiting for guest reboot')
                    if status != 0:
                        raise RuntimeError('QEMU exited with status ' + str(status) + ' during reboot')
                else:
                    print(name + (': password and state persisted across reboot; wrong password rejected; marker removed'
                                  if persistent else ': stateless reboot required fresh password provisioning'), flush=True)
                break
        else:
            raise RuntimeError('timed out waiting for ' + stage)
    except Exception as exc:
        print(name + ': ' + str(exc), file=sys.stderr)
        # Serial buffers can contain disposable credentials. Never publish them.
        for label in (b'login incorrect', b'login:', b'new password:', b'retype password:', b'password:'):
            if label in log.lower():
                print('Observed prompt category: ' + label.decode(), file=sys.stderr)
        raise SystemExit(1)
    finally:
        log.clear()
        conn.close()
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        errors = proc.stderr.read().decode(errors='replace')
        if errors:
            print(errors, file=sys.stderr)

for name in ('seabios', 'ovmf'):
    serial = os.path.join(tmp, name + '.sock')
    overlay = os.path.join(tmp, name + '.qcow2')
    subprocess.run(['qemu-img', 'create', '-q', '-f', 'qcow2', '-F', 'raw',
                    '-b', os.path.join(tmp, 'disk.img'), overlay], check=True)
    marker = 'ALPENGLOW_STATE_' + secrets.token_hex(16)
    path = '/state/.release-boot-test-' + secrets.token_hex(16)
    token = 'ALPENGLOW_RELEASE_OK_' + secrets.token_hex(16)
    mount_check = (
        "/bin/busybox awk '$2 == \"/state\" && $3 == \"bcachefs\" && "
        "$4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' /proc/mounts && test -d /state"
    )
    success = " && printf '%s%s\\n' '" + token[:20] + "' '" + token[20:] + "'\n"
    commands = [
        mount_check + " && ( umask 077; printf '%s\\n' '" + marker + "' > '" + path + "' )"
        + " && test \"$(cat '" + path + "')\" = '" + marker + "' && /bin/busybox sync" + success,
        mount_check + " && test \"$(cat '" + path + "')\" = '" + marker + "'"
        + " && rm -f '" + path + "' && /bin/busybox sync" + success,
    ]
    if not persistent:
        commands = ["! grep -q ' /state ' /proc/mounts" + success] * 2
    password = 'Ag!' + secrets.token_urlsafe(24)
    wrong_password = 'Wrong!' + secrets.token_urlsafe(24)
    args = [
        'qemu-system-x86_64', '-machine', 'q35', '-m', '768', '-smp', '2',
        '-display', 'none', '-monitor', 'none', '-no-reboot', '-nic', 'none',
        '-serial', 'unix:' + serial + ',server=on,wait=off',
        '-drive', 'file=' + overlay + ',format=qcow2,if=virtio',
    ]
    if name == 'ovmf':
        varstore = os.path.join(tmp, 'ovmf-vars.fd')
        shutil.copyfile(os.environ['OVMF_VARS_TEMPLATE'], varstore)
        args += ['-drive', 'if=pflash,format=raw,readonly=on,file=' + firmware,
                 '-drive', 'if=pflash,format=raw,file=' + varstore]
    for boot, command in enumerate(commands):
        print('Booting ' + name + (' (initial)' if boot == 0 else ' (after reboot)'), flush=True)
        if os.path.exists(serial):
            os.unlink(serial)
        run_boot(name, args, serial, command, token, boot, password, wrong_password)
PY
