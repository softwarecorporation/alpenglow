#!/bin/sh
# Real x86_64 musl sdhcp + dnsmasq renewal, never on the host network.
# Needs privileged Docker; takes about 120 seconds plus image preparation.
# Usage: DOCKER='sudo -n docker' sh scripts/test-sdhcp-renewal.sh
# Evidence stays under .amp/in/orb-backup; the disposable image/container is removed.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
mkdir -p "${ROOT}/.amp/in/orb-backup"
out="$(mktemp -d "${ROOT}/.amp/in/orb-backup/sdhcp-renewal.XXXXXX")"
image="alpenglow-sdhcp-test:$$"
container="alpenglow-sdhcp-test-$$"
docker_cmd() { ${DOCKER:-docker} "$@"; }
cleanup() {
  docker_cmd rm -f "${container}" >/dev/null 2>&1 || true
  docker_cmd image rm "${image}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "sdhcp test evidence: ${out}"
cp "${ROOT}/scripts/lib/sdhcp-option51.patch" "${out}/"
cat > "${out}/Dockerfile" <<'DOCKERFILE'
FROM alpine:3.21
RUN apk add --no-cache gcc musl-dev make curl tar patch dnsmasq iproute2 tcpdump python3
WORKDIR /test
RUN curl -fsSL https://dl.2f30.org/releases/sdhcp-0.1.tar.gz -o sdhcp.tar.gz && \
    echo '08e43f3d540f62ba9b4a72774fee39074d81f272955c84dd283d8fbaef44deed  sdhcp.tar.gz' | sha256sum -c - && \
    tar -xzf sdhcp.tar.gz
COPY sdhcp-option51.patch verify-width.c network.sh verify-packets.py /test/
RUN cd sdhcp-0.1 && patch -p1 < /test/sdhcp-option51.patch && \
    make CC=gcc CFLAGS='-Os -D_BSD_SOURCE' LDFLAGS='-static -s'
RUN gcc -Os -D_BSD_SOURCE -static -o verify-width verify-width.c \
    sdhcp-0.1/util/strlcpy.c sdhcp-0.1/util/eprintf.c && ./verify-width
DOCKERFILE
cat > "${out}/verify-width.c" <<'C'
#define main sdhcp_main
#include "sdhcp-0.1/sdhcp.c"
#undef main
#include <assert.h>
int main(void)
{
    unsigned char sent[6] = {0};
    unsigned char lease[] = {0x12, 0x34, 0x56, 0x78};
    Bootp offer = {0};
    unsigned char *p;
    assert(sizeof(unsigned long) == 8);
    assert(sizeof(t1) == 4);
    t1 = 0x12345678;
    p = hnoptput(sent, ODlease, t1, sizeof(t1));
    assert(p == sent + 6 && sent[0] == 51 && sent[1] == 4);
    assert(memcmp(sent + 2, lease, 4) == 0);
    p = optput(offer.optdata, ODlease, lease, sizeof(lease));
    *p = OBend;
    t1 = 0;
    optget(&offer, &t1, ODlease, sizeof(t1));
    assert(ntohl(t1) == 0x12345678);
    puts("x86_64 musl: option51 send length=4, receive width=4, value=0x12345678");
    return 0;
}
C
cat > "${out}/network.sh" <<'NETWORK'
#!/bin/sh
set -eu
[ "$(uname -m)" = x86_64 ]
/test/verify-width
dnsmasq --version | head -n 1
ip netns add server
ip netns add client
ip link add server0 type veth peer name client0
ip link set server0 netns server
ip link set client0 netns client
ip -n server link set lo up
ip -n client link set lo up
ip -n server addr add 192.0.2.1/24 dev server0
ip -n server link set server0 up
ip -n client link set client0 up
# The orb inherits loose reverse-path filtering on new interfaces. Before
# DHCP creates a route it drops offers; disable it only in this client netns.
ip netns exec client sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.client0.rp_filter=0
ip netns exec server tcpdump -U -i server0 -w /evidence/renewal.pcap 'udp port 67 or udp port 68' > /evidence/tcpdump.log 2>&1 &
capture=$!
ip netns exec server dnsmasq --keep-in-foreground --conf-file=/dev/null --user=root \
  --interface=server0 --bind-interfaces --port=0 --dhcp-authoritative \
  --dhcp-range=192.0.2.20,192.0.2.20,255.255.255.0,120s \
  --dhcp-option=option:router,192.0.2.1 --dhcp-option=option:dns-server,192.0.2.1 \
  --dhcp-leasefile=/evidence/leases --pid-file=/evidence/dnsmasq.pid \
  --log-dhcp --log-facility=/evidence/dnsmasq.log > /evidence/dnsmasq-stderr.log 2>&1 &
server=$!
cat > /evidence/lease-hook <<'HOOK'
#!/bin/sh
date +%s >> /evidence/bound-events
HOOK
chmod 755 /evidence/lease-hook
sleep 1
kill -0 "${capture}" "${server}"
ip netns exec client /test/sdhcp-0.1/sdhcp -d -e /evidence/lease-hook client0 > /evidence/sdhcp.log 2>&1 &
# sdhcp 0.1 renews at the full lease duration. Do not accelerate its clock
# or change its state machine: observe the actual 120-second renewal.
count=0
while [ "${count}" -lt 150 ]; do
  # Wait for libpcap to flush the renewal too, not just the client hook.
  if [ -f /evidence/bound-events ] && [ "$(wc -l < /evidence/bound-events)" -ge 2 ] &&
    python3 /test/verify-packets.py /evidence/renewal.pcap > /evidence/packets.log 2>&1; then
    break
  fi
  sleep 1
  count=$((count + 1))
done
[ -f /evidence/bound-events ] && [ "$(wc -l < /evidence/bound-events)" -ge 2 ] || {
  echo 'DHCP client did not complete the second lease hook before timeout' >&2
  exit 1
}
kill -INT "${capture}"
wait "${capture}"
python3 /test/verify-packets.py /evidence/renewal.pcap
NETWORK
cat > "${out}/verify-packets.py" <<'PY'
import ipaddress
import struct
import sys

data = open(sys.argv[1], "rb").read()
assert data[:4] == b"\xd4\xc3\xb2\xa1", "expected little-endian microsecond pcap"
assert struct.unpack_from("<I", data, 20)[0] == 1, "expected Ethernet"
offset = 24
events = []
while offset < len(data):
    sec, usec, size, _ = struct.unpack_from("<IIII", data, offset)
    frame = data[offset + 16:offset + 16 + size]
    offset += 16 + size
    if frame[12:14] != b"\x08\x00":
        continue
    ip = frame[14:]
    if ip[9] != 17:
        continue
    udp = ip[(ip[0] & 15) * 4:]
    src, dst = struct.unpack_from("!HH", udp)
    if {src, dst} != {67, 68}:
        continue
    bootp = udp[8:]
    assert bootp[236:240] == b"\x63\x82\x53\x63"
    options = {}
    pos = 240
    while pos < len(bootp):
        code = bootp[pos]
        pos += 1
        if code == 255:
            break
        if code == 0:
            continue
        length = bootp[pos]
        pos += 1
        options[code] = bootp[pos:pos + length]
        assert len(options[code]) == length
        pos += length
    message = options.get(53, b"\0")[0]
    timestamp = sec + usec / 1_000_000
    destination = str(ipaddress.ip_address(ip[16:20]))
    xid = bootp[4:8]
    events.append((timestamp, message, options, destination, xid))
    if message in (3, 5):
        lease = options.get(51, b"")
        print(f"t={timestamp:.6f} type={message} destination={destination} xid={xid.hex()} "
              f"option51.length={len(lease)} value={int.from_bytes(lease, 'big')}")
        assert len(lease) == 4, "REQUEST/ACK must carry four-byte option51"
acks = [event for event in events if event[1] == 5]
assert acks, "no initial ACK"
first = acks[0]
renewals = [event for event in events if event[1] == 3 and event[0] - first[0] >= 110
            and event[3] == "192.0.2.1" and event[4] == first[4]]
assert renewals, "no real unicast renewal REQUEST after initial lease"
renewal = renewals[0]
assert any(event[0] >= renewal[0] and event[4] == renewal[4] for event in acks[1:]), "no renewal ACK"
print(f"PASS: four-byte option51 in unicast renewal REQUEST and matching ACK, "
      f"{renewal[0] - first[0]:.3f}s after initial ACK")
PY
# Host networking is used only to fetch build dependencies (orb Docker bridge
# forwarding can be disabled). DHCP itself runs below with --network none.
if docker_cmd build --force-rm --network host --platform linux/amd64 -t "${image}" "${out}" > "${out}/build.log" 2>&1; then
  cat "${out}/build.log"
else
  cat "${out}/build.log" >&2
  exit 1
fi
# No external network exists during DHCP; both veth ends live inside this
# disposable container. The timeout also bounds failure when DHCP never binds.
if docker_cmd run --rm --name "${container}" --platform linux/amd64 --privileged --network none \
  -v "${out}:/evidence" "${image}" timeout -s KILL 165 sh /test/network.sh > "${out}/network.log" 2>&1; then
  cat "${out}/network.log"
else
  cat "${out}/network.log" "${out}/dnsmasq-stderr.log" >&2
  exit 1
fi
