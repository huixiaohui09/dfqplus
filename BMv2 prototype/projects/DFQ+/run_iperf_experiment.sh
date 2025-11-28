#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FLOWS=8           # Number of concurrent UDP flows (2~32, e.g., 2/4/8/...)
INTERVAL=5         # Interval (seconds) between starting each flow
RATE="10M"         # Target sending rate per flow
DURATION=60        # Duration (seconds) of each flow
SERVER_IP="10.0.1.2"
SERVER_PORT_BASE=5000   # Flow 1 uses 5001, and the rest increment by 1
LINK_RATE_MBPS=10       # Bandwidth of the link in the topology
# ---------------------------------------------------

echo "[DFQ+] Cleaning Mininet state..."
sudo mn -c >/dev/null 2>&1 || true

echo "[DFQ+] Starting DFQ+ experiment with ${FLOWS} UDP flows..."

sudo python3 - << 'EOF'
import os, time, textwrap
from mininet.net import Mininet
from mininet.link import TCLink
from mininet.log import setLogLevel, info, output

from topo import SimpleTopo, JSON_PATH, LOG_PATH, THRIFT_PORT

setLogLevel('info')

# These parameters must match the variables in the bash section above
FLOWS        = int(os.environ.get("DFQ_FLOWS", "8"))
INTERVAL     = int(os.environ.get("DFQ_INTERVAL", "5"))
RATE         = os.environ.get("DFQ_RATE", "10M")
DURATION     = int(os.environ.get("DFQ_DURATION", "60"))
SERVER_IP    = os.environ.get("DFQ_SERVER_IP", "10.0.1.2")
SERVER_PORT_BASE = int(os.environ.get("DFQ_SERVER_PORT_BASE", "5000"))
LINK_RATE_MBPS   = int(os.environ.get("DFQ_LINK_RATE_MBPS", "10"))

if not os.path.exists(JSON_PATH):
    raise SystemExit(f"[FATAL] DFQ JSON not found: {JSON_PATH}")

info("*** Start Mininet with DFQ+ topology\n")
net = Mininet(topo=SimpleTopo(), controller=None, link=TCLink,
              autoSetMacs=False, autoStaticArp=False)
net.start()

s1 = net.get('s1')
h1, h2 = net.get('h1', 'h2')

# Configure host IP addresses
h1.cmd('ip link set h1-eth0 up')
h1.cmd('ip addr flush dev h1-eth0')
h1.cmd('ip addr add 10.0.1.1/24 dev h1-eth0')
h1.cmd('ip link set lo up')

h2.cmd('ip link set h2-eth0 up')
h2.cmd('ip addr flush dev h2-eth0')
h2.cmd('ip addr add 10.0.1.2/24 dev h2-eth0')
h2.cmd('ip link set lo up')

info("*** Start BMv2 (simple_switch)\n")
s1.cmd(
    f"simple_switch --log-file {LOG_PATH} --log-level debug "
    f"--thrift-port {THRIFT_PORT} "
    f"-i 0@s1-eth1 -i 1@s1-eth2 "
    f"{JSON_PATH} &"
)

info("*** Wait for Thrift port to be ready\n")
for _ in range(50):
    out = s1.cmd(f"ss -ltnp | grep -w {THRIFT_PORT}")
    if out.strip() != "":
        break
    time.sleep(0.1)
else:
    output(f"[FATAL] Thrift port {THRIFT_PORT} not listening, check log: {LOG_PATH}\n")
    net.stop()
    raise SystemExit(1)

# Install IPv4 LPM forwarding rules
info("*** Install IPv4 LPM rules\n")
rules = textwrap.dedent("""
    table_add MyIngress.ipv4_lpm MyIngress.ipv4_forward 10.0.1.1/32 => 00:00:00:00:00:01 0
    table_add MyIngress.ipv4_lpm MyIngress.ipv4_forward 10.0.1.2/32 => 00:00:00:00:00:02 1
""").strip() + "\n"

s1.cmd("bash -lc 'cat > /tmp/dfq_rules.txt << \"EOF\"\n" + rules + "EOF\n'")
cli_out = s1.cmd(f"simple_switch_CLI --thrift-port {THRIFT_PORT} < /tmp/dfq_rules.txt")
info(cli_out)

# Dump the table for verification
dump = s1.cmd(f"simple_switch_CLI --thrift-port {THRIFT_PORT} <<< 'table_dump MyIngress.ipv4_lpm'")
info(dump)

# Static ARP
h1.cmd('arp -s 10.0.1.2 00:00:00:00:00:02')
h2.cmd('arp -s 10.0.1.1 00:00:00:00:00:01')

# Connectivity test
info("*** Connectivity test: h1 -> h2\n")
info(h1.cmd('ping -c 3 -W 1 10.0.1.2'))

# ---------------- UDP experiment section ----------------
info("*** Start UDP iperf server on h2\n")
# iperf server logs will be saved in the current directory: iperf_server.log
h2.cmd(f"iperf -s -u -i 1 > iperf_server.log 2>&1 &")

info(f"*** Start {FLOWS} UDP flows from h1 to {SERVER_IP}, interval={INTERVAL}s, rate={RATE}, duration={DURATION}s\n")

for i in range(1, FLOWS + 1):
    port = SERVER_PORT_BASE + i
    info(f"*** Launch flow {i}/{FLOWS} on UDP port {port}\n")
    # Each flow writes to its own log file: iperf_client_1.log, iperf_client_2.log, ...
    h1.cmd(
        f"iperf -c {SERVER_IP} -u -b {RATE} -l 1400 "
        f"-t {DURATION} -p {port} > iperf_client_{i}.log 2>&1 &"
    )
    if i != FLOWS:
        time.sleep(INTERVAL)

# Wait for all flows to complete
total_wait = DURATION + INTERVAL + 5
info(f"*** Waiting {total_wait} seconds for all flows to complete\n")
time.sleep(total_wait)

info("*** Stopping network\n")
net.stop()
EOF

echo "[DFQ+] Experiment finished."
echo "[DFQ+] iperf logs are saved in: $SCRIPT_DIR (iperf_server.log, iperf_client_*.log)"
