from mininet.net import Mininet
from mininet.topo import Topo
from mininet.cli import CLI
from mininet.link import TCLink
from mininet.log import setLogLevel, info, error
import os, time, textwrap

JSON_PATH = "/p4-deps/A_DFQ/DFQ/dfq.json"
LOG_PATH  = "/p4-deps/A_DFQ/DFQ/bmv2.log"
THRIFT_PORT = 9090

class SimpleTopo(Topo):
    def __init__(self):
        Topo.__init__(self)
        h1 = self.addHost('h1', ip="10.0.1.1/24", mac="00:00:00:00:00:01")
        h2 = self.addHost('h2', ip="10.0.1.2/24", mac="00:00:00:00:00:02")
        s1 = self.addSwitch('s1', cls=None)

        self.addLink(h1, s1, port1=0, port2=1, intfName1='h1-eth0', intfName2='s1-eth1',
                     cls=TCLink, bw=10)
        self.addLink(h2, s1, port1=0, port2=2, intfName1='h2-eth0', intfName2='s1-eth2',
                     cls=TCLink, bw=10)

def start_network():
    os.system("mn -c >/dev/null 2>&1")

    if not os.path.exists(JSON_PATH):
        error(f"[FATAL] no P4 JSON: {JSON_PATH}\n"); return

    info("*** Start Mininet\n")
    net = Mininet(topo=SimpleTopo(), controller=None, link=TCLink, autoSetMacs=False, autoStaticArp=False)
    net.start()

    s1 = net.get('s1')
    h1, h2 = net.get('h1', 'h2')

    h1.cmd('ip link set h1-eth0 up; ip addr flush dev h1-eth0; ip addr add 10.0.1.1/24 dev h1-eth0; ip link set lo up')
    h2.cmd('ip link set h2-eth0 up; ip addr flush dev h2-eth0; ip addr add 10.0.1.2/24 dev h2-eth0; ip link set lo up')


    info("*** Start BMv2 (simple_switch)\n")
    s1.cmd(
        f"simple_switch --log-file {LOG_PATH} --log-level debug "
        f"--thrift-port {THRIFT_PORT} "
        f"-i 0@s1-eth1 -i 1@s1-eth2 "
        f"{JSON_PATH} &"
    )

    info("*** Wait for Thrift port to be ready\n")
    for _ in range(50):
        if s1.cmd(f"ss -ltnp | grep -w {THRIFT_PORT}") != "":
            break
        time.sleep(0.1)
    else:
        error(f"[FATAL] Thrift port not listening: {THRIFT_PORT}, check log: {LOG_PATH}\n")
        net.stop(); return

    # Install minimal IPv4 forwarding rules (keep original ports 0/1)
    info("*** Install minimal IPv4 forwarding rules (ports 0/1)\n")
    rules = textwrap.dedent("""
        table_add MyIngress.ipv4_lpm MyIngress.ipv4_forward 10.0.1.1/32 => 00:00:00:00:00:01 0
        table_add MyIngress.ipv4_lpm MyIngress.ipv4_forward 10.0.1.2/32 => 00:00:00:00:00:02 1
    """).strip() + "\n"
    s1.cmd(f"bash -lc \"cat > /tmp/rules.txt <<'EOF'\n{rules}\nEOF\"")
    out = s1.cmd(f"simple_switch_CLI --thrift-port {THRIFT_PORT} < /tmp/rules.txt")
    info(out)

    # Optional: dump table for verification
    dump = s1.cmd(f"simple_switch_CLI --thrift-port {THRIFT_PORT} <<< 'table_dump MyIngress.ipv4_lpm'")
    info(dump)

    # Optional: initialize DFQ registers
    info("*** Initialize DFQ queue registers (optional)\n")
    for i in range(4):
        s1.cmd(f"simple_switch_CLI --thrift-port {THRIFT_PORT} <<< 'register_write queue_head {i} 0'")
        s1.cmd(f"simple_switch_CLI --thrift-port {THRIFT_PORT} <<< 'register_write queue_tail {i} 0'")
        s1.cmd(f"simple_switch_CLI --thrift-port {THRIFT_PORT} <<< 'register_write queue_size {i} 0'")

    # Static ARP
    h1.cmd('arp -s 10.0.1.2 00:00:00:00:00:02')
    h2.cmd('arp -s 10.0.1.1 00:00:00:00:00:01')

    # Connectivity test
    info("*** Connectivity test: h1 -> h2\n")
    info(h1.cmd('ping -c 3 -W 1 10.0.1.2'))

    CLI(net)
    net.stop()

if __name__ == '__main__':
    setLogLevel('info')
    start_network()
