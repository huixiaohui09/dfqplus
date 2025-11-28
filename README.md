# DFQ+

DFQ+ is a dynamic fair queuing mechanism that uses a small number of priority queues to achieve both high utilization and fair bandwidth allocation.

---

## Repository Contents

This repository provides:

-  A **P4 implementation** of DFQ+ on [**BMv2**](https://github.com/p4lang/behavioral-model)
-  **Mininet scripts** to evaluate DFQ+
-  A **patch** enabling **multi-priority queues** and **Rotating Strict Priority (RSP)** scheduling on BMv2 (following the [**A2FQ**](https://github.com/ants-xjtu/a2fq) model)

---

## Prerequisites

### Supported Operating Systems

- **Ubuntu 20.04 / 22.04** (recommended)
- **P4 Tutorials VM** (official image)
- **WSL2 on Windows** is suitable for development, but **BMv2 + Mininet is recommended on a Linux host/VM**

---

### Core Toolchain

| Requirement     | Versions / Tools                   |
|----------------|------------------------------------|
| Build tools     | `git`, `build-essential`, `cmake`, `pkg-config` |
| Python          | `Python 3.8+`, `python3-pip`       |
| Network Testing | `iperf3` (or `iperf`), `tcpdump` *(optional)* |

---

### P4 Toolchain

| Component          | Description |
|-------------------|-------------|
| `p4c`             | P4-16 Compiler (v1model backend) |
| `BMv2`            | behavioral-model with `simple_switch` and `simple_switch_CLI` |
| `Mininet`         | Version ≥ 2.3 |

---

### Java / NetBench

| Requirement | Recommended |
|-------------|-------------|
| JDK         | 11+ (Java 17 preferred) |
| Build Tool  | Maven 3.8+ or Gradle 7+ |

---

## Quick Version Check

Run the following commands to verify your environment:

```bash
p4c --version
simple_switch --version 2>/dev/null || which simple_switch
simple_switch_CLI --version 2>/dev/null || which simple_switch_CLI
mn --version
python3 --version
java -version
mvn -v   # if using Maven
```

## Environment Setup: Use the P4 Tutorials VM

If you are new to P4, the easiest way to get started is by using the **P4 Tutorials VM** or following the official setup guide:

🔗 [https://github.com/p4lang/tutorials#to-build-the-virtual-machine](https://github.com/p4lang/tutorials#to-build-the-virtual-machine)

---

## Quick Start (Already Have `p4c` + BMv2 Installed)

If `p4c` and `simple_switch` are already installed on your system, follow these steps:

1) Apply the patch to enable Multi-priority queues and RSP scheduling
```bash
cp "dfqplus/BMv2 prototype/patch/final/p4include/v1model.p4" /usr/local/share/p4c/p4include/
cp "dfqplus/BMv2 prototype/patch/final/simple_switch/"* ~/behavioral-model/targets/simple_switch/

cd ~/behavioral-model
./autogen.sh
./configure
make -j"$(nproc)"
sudo make install
```
 2) Run DFQ+
```bash
cd "dfqplus/BMv2 prototype/projects/DFQ+"
sudo ./run_iperf_experiment.sh
```
