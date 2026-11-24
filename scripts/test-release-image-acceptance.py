#!/usr/bin/env python3
"""Exact-image console/state/DHCP acceptance in an empty network namespace.

Run as root through unshare --net. Credentials and serial buffers stay in
memory; private overlays containing test password hashes are always deleted.
Only assertion summaries are printed, never serial transcripts or credentials.
"""

import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class Console:
    def __init__(self, proc, path):
        self.proc = proc
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.buffer = b""
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            require(proc.poll() is None, "QEMU exited before serial connection")
            try:
                self.sock.connect(str(path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.1)
        else:
            raise RuntimeError("serial connection timed out")
        self.sock.settimeout(0.5)

    def send(self, value):
        self.sock.sendall(value.encode() + b"\n")

    def expect(self, pattern, stage, timeout=120, reject=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if reject and re.search(reject, self.buffer, re.I | re.M):
                raise RuntimeError("unexpected console state during " + stage)
            match = re.search(pattern, self.buffer, re.I | re.M)
            if match:
                value = self.buffer[:match.end()]
                self.buffer = self.buffer[match.end():]
                return value
            require(self.proc.poll() is None, "QEMU exited during " + stage)
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            require(data, "serial closed during " + stage)
            self.buffer = (self.buffer + data)[-262144:]
        raise RuntimeError("timeout during " + stage)

    def command(self, command, stage, timeout=90):
        token = secrets.token_hex(16)
        # Split the response token so terminal command echo cannot satisfy it.
        self.send(command + "; result=$?; printf '\\n%s%s:%s\\n' '" + token[:16]
                  + "' '" + token[16:] + "' \"$result\"")
        result = self.expect(token.encode() + rb":([0-9]+)\r?\n", stage, timeout)
        status = re.search(token.encode() + rb":([0-9]+)", result).group(1)
        require(status == b"0", stage + " failed (guest exit " + status.decode() + ")")

    def close(self):
        self.buffer = b""
        self.sock.close()


def dhcp_events(path):
    if not path.exists():
        return []
    data = path.read_bytes()
    if len(data) < 24:
        return []
    require(data[:4] == b"\xd4\xc3\xb2\xa1", "unexpected pcap encoding")
    require(struct.unpack_from("<I", data, 20)[0] == 1, "expected Ethernet capture")
    events = []
    offset = 24
    while offset + 16 <= len(data):
        sec, usec, size, _ = struct.unpack_from("<IIII", data, offset)
        if offset + 16 + size > len(data):
            break  # tcpdump may still be flushing the next packet.
        frame = data[offset + 16:offset + 16 + size]
        offset += 16 + size
        if len(frame) < 42 or frame[12:14] != b"\x08\x00":
            continue
        ip = frame[14:]
        if ip[9] != 17:
            continue
        udp = ip[(ip[0] & 15) * 4:]
        if len(udp) < 248 or set(struct.unpack_from("!HH", udp)) != {67, 68}:
            continue
        bootp = udp[8:]
        require(bootp[236:240] == b"\x63\x82\x53\x63", "invalid DHCP cookie")
        options = {}
        pos = 240
        while pos < len(bootp):
            code = bootp[pos]
            pos += 1
            if code == 255:
                break
            if code == 0:
                continue
            require(pos < len(bootp), "truncated DHCP option length")
            length = bootp[pos]
            pos += 1
            options[code] = bootp[pos:pos + length]
            require(len(options[code]) == length, "truncated DHCP option")
            pos += length
        message = options.get(53, b"\0")[0]
        if message in (3, 5):
            require(len(options.get(51, b"")) == 4, "DHCP REQUEST/ACK lease option is not four bytes")
            require(int.from_bytes(options[51], "big") == 120, "unexpected DHCP lease duration")
        events.append((sec + usec / 1_000_000, message, ip[16:20], bootp[4:8]))
    return events


def check_renewal(path):
    events = dhcp_events(path)
    acks = [event for event in events if event[1] == 5]
    if not acks:
        return False
    first = acks[0]
    renewals = [event for event in events if event[1] == 3
                and event[0] - first[0] >= 110
                and event[2] == socket.inet_aton("192.0.2.1") and event[3] == first[3]]
    return any(ack[0] >= request[0] and ack[3] == request[3]
               for request in renewals for ack in acks[1:])


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def firmware_paths():
    root = Path(__file__).resolve().parent.parent
    return run("sh", "-ec", '. "$1/scripts/lib/qemu-boot-x86_64.sh"; '
               'code=$(qemu_ovmf_code); printf "%s\\n" "$code"; qemu_ovmf_vars "$code"',
               "sh", str(root)).decode().splitlines()


def validate(image, work):
    links = json.loads(run("ip", "-j", "link", "show"))
    require([link["ifname"] for link in links] == ["lo"], "requires an empty unshare --net namespace")
    require(not json.loads(run("ip", "-j", "route", "show")), "namespace has an external route")
    run("ip", "link", "set", "lo", "up")
    run("ip", "tuntap", "add", "dev", "agtap0", "mode", "tap")
    run("ip", "addr", "add", "192.0.2.1/24", "dev", "agtap0")
    run("ip", "link", "set", "agtap0", "up")
    # A client without an address must be able to receive its broadcast offer.
    run("sysctl", "-qw", "net.ipv4.conf.all.rp_filter=0", "net.ipv4.conf.agtap0.rp_filter=0")
    print("PASS: isolated loopback/tap namespace, no external interface or default route", flush=True)
    disk = work / "disk.img"
    with disk.open("wb") as output:
        subprocess.run(["zstd", "-dc", str(image)], stdout=output, check=True)
    code, variables = firmware_paths()
    for name in ("seabios", "ovmf"):
        overlay = work / (name + ".qcow2")
        run("qemu-img", "create", "-q", "-f", "qcow2", "-F", "raw", "-b", str(disk), str(overlay))
        pcap = work / (name + ".pcap")
        capture = subprocess.Popen(["tcpdump", "-U", "-i", "agtap0", "-w", str(pcap),
                                    "udp port 67 or udp port 68"], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        server = subprocess.Popen([
            "dnsmasq", "--keep-in-foreground", "--conf-file=/dev/null", "--user=root",
            "--interface=agtap0", "--bind-interfaces", "--port=0", "--dhcp-authoritative",
            "--dhcp-range=192.0.2.20,192.0.2.20,255.255.255.0,120s",
            "--dhcp-option=option:router,192.0.2.1", "--dhcp-option=option:dns-server,192.0.2.1",
            "--dhcp-leasefile=" + str(work / (name + ".leases")),
            "--pid-file=" + str(work / (name + ".pid")),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        password = "Ag!" + secrets.token_urlsafe(24)
        wrong_password = "Wrong!" + secrets.token_urlsafe(24)
        marker = secrets.token_hex(16)
        paths = ["/state/.acceptance-marker", "/home/.acceptance-marker", "/opt/oil/.acceptance-marker"]
        serial = work / (name + ".sock")
        args = ["qemu-system-x86_64", "-machine", "q35", "-m", "768", "-smp", "2",
                "-display", "none", "-monitor", "none", "-no-reboot",
                "-serial", "unix:" + str(serial) + ",server=on,wait=off",
                "-drive", "file=" + str(overlay) + ",format=qcow2,if=virtio",
                "-netdev", "tap,id=isolated,ifname=agtap0,script=no,downscript=no",
                "-device", "virtio-net-pci,netdev=isolated,mac=52:54:00:62:60:01"]
        if name == "ovmf":
            varstore = work / "ovmf-vars.fd"
            shutil.copyfile(variables, varstore)
            args += ["-drive", "if=pflash,format=raw,readonly=on,file=" + code,
                     "-drive", "if=pflash,format=raw,file=" + str(varstore)]
        try:
            time.sleep(1)
            require(server.poll() is None and capture.poll() is None, "isolated DHCP/capture startup failed")
            for boot in (0, 1):
                serial.unlink(missing_ok=True)
                proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                console = None
                try:
                    console = Console(proc, serial)
                    if boot == 0:
                        console.expect(rb"new password:", "first-login password provisioning")
                        console.send(password)
                        console.expect(rb"retype password:", "password confirmation")
                        console.send(password)
                    console.expect(rb"login:", "login prompt", reject=rb"first login on this machine" if boot else None)
                    console.send("root")
                    console.expect(rb"password:", "password authentication")
                    if boot == 1:
                        console.send(wrong_password)
                        console.expect(rb"login incorrect", "wrong-password rejection",
                                       reject=rb"(?:^|\n)[^\r\n]*[#$] $")
                        console.expect(rb"login:", "login retry")
                        console.send("root")
                        console.expect(rb"password:", "persisted-password authentication")
                    console.send(password)
                    console.expect(rb"(?:^|\n)[^\r\n]*[#$] $", "authenticated root shell")
                    console.command(
                        "/bin/busybox awk '$2 == \"/state\" && $3 == \"bcachefs\" && "
                        "$4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' /proc/mounts && "
                        "test -s /state/etc/root-shadow && "
                        "test \"$(/bin/busybox stat -c %a /state/etc/root-shadow)\" = 600 && "
                        "(grep '^root:' /etc/shadow | /bin/busybox cmp - /state/etc/root-shadow)",
                        name + " writable state and saved root password")
                    console.command(
                        "i=0; until /bin/busybox ifconfig eth0 | grep -q '192.0.2.20'; do "
                        "i=$((i+1)); [ \"$i\" -lt 30 ] || break; sleep 1; done; "
                        "/bin/busybox ifconfig eth0 | grep -q '192.0.2.20' && "
                        "/bin/busybox route -n | /bin/busybox awk '$1 == \"0.0.0.0\" && "
                        "$2 == \"192.0.2.1\" {ok=1} END {exit !ok}' && "
                        "/bin/busybox ping -c 1 -W 2 192.0.2.1 >/dev/null && "
                        "grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf && "
                        "/bin/busybox nslookup alpenglow 127.0.0.1 >/dev/null 2>&1 && "
                        "(for service in sdhcp dropbear chronyd dnsmasq; do "
                        "/bin/busybox pidof \"$service\" >/dev/null || exit 1; done)",
                        name + " automatic DHCP route, isolated reachability, local DNS and services")
                    with socket.create_connection(("192.0.2.20", 22), timeout=10) as ssh:
                        require(ssh.recv(255).startswith(b"SSH-2.0-"), "missing SSH server greeting")
                    if boot == 0:
                        console.command(" && ".join("(umask 077; printf '%s\\n' '" + marker + "' > " + path + ")"
                                                     for path in paths) + " && /bin/busybox sync",
                                        name + " persistent bind writes")
                        deadline = time.monotonic() + 160
                        while time.monotonic() < deadline and not check_renewal(pcap):
                            require(server.poll() is None and capture.poll() is None, "DHCP server/capture stopped")
                            time.sleep(1)
                        require(check_renewal(pcap), name + " missing four-byte unicast DHCP renewal/ACK after real lease interval")
                        print(name + ": PASS initial login, writable state/home/Oil, DHCP address/route, local DNS, "
                              "SSH greeting, service processes and real 120-second DHCP renewal/ACK", flush=True)
                        console.send("/bin/busybox sync; /bin/busybox reboot -f")
                        require(proc.wait(timeout=120) == 0, name + " guest reboot failed")
                    else:
                        console.command(" && ".join("test \"$(cat " + path + ")\" = '" + marker + "'" for path in paths)
                                        + " && rm -f " + " ".join(paths) + " && /bin/busybox sync",
                                        name + " state/home/Oil persistence across reboot")
                        print(name + ": PASS reboot, wrong-password rejection, original-password login, "
                              "persisted state/home/Oil and automatic network recovery", flush=True)
                finally:
                    if console:
                        console.close()
                    stop(proc)
        finally:
            password = wrong_password = ""
            stop(capture)
            stop(server)
            overlay.unlink(missing_ok=True)
    print("PASS: combined acceptance; no credentials, hashes, serial transcripts or used overlays retained", flush=True)


if __name__ == "__main__":
    try:
        require(os.geteuid() == 0, "run with sudo unshare --net")
        require(len(sys.argv) == 2 and Path(sys.argv[1]).is_file(), "expected a compressed disk image")
        # The hosted runner's temporary disk has room for the uncompressed image.
        # Never place credential-bearing overlays in artifacts or the orb backup
        # tree. TemporaryDirectory is private and removes them even on failure.
        base = os.environ.get("RUNNER_TEMP", "/var/tmp")
        with tempfile.TemporaryDirectory(prefix="alpenglow-acceptance-", dir=base) as tmp:
            validate(Path(sys.argv[1]).resolve(), Path(tmp))
    except Exception as error:
        # Error text contains stage names only, not commands, serial or passwords.
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
