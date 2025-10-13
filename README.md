# DFQ+

DFQ+ is a dynamic fair queuing mechanism that uses a small number of priority queues to achieve both high utilization and fair bandwidth allocation.

This repository provides:

- A **P4 implementation** of DFQ+ on [**BMv2**](https://github.com/p4lang/behavioral-model).
- **Mininet** scripts to evaluate DFQ+.
- A patch enabling **multi-priority queues** and **Rotating Strict Priority (RSP)** scheduling on BMv2 (compatible with [A2FQ](https://github.com/ants-xjtu/a2fq)).

## Prerequisites

- Ubuntu 20.04/22.04 (recommended) or the official **P4 tutorials VM**
- `git`, `build-essential`, `cmake`, `python3`, `python3-pip`
- **p4c** (P4 compiler)
- **BMv2** (behavioral-model) with `simple_switch`
- **Mininet**
- `iperf` / `iperf3`

If you are new to P4, the easiest path is using the tutorials VM or following the official setup guide:  
<https://github.com/p4lang/tutorials#to-build-the-virtual-machine>

## Quick Start (already have p4c + BMv2)

> If `p4c` and `simple_switch` are already installed on your system:

```bash
# 1) Apply the patch (adjust paths to your environment)
# Replace p4c's v1model
sudo cp patch/final/p4include/v1model.p4 \
    "$(p4c --print-include-dir)/v1model.p4"

# Copy patched BMv2 sources into your BMv2 source tree, then rebuild
cp patch/final/simple_switch/*  ~/behavioral-model/targets/simple_switch/
cd ~/behavioral-model
make -j"$(nproc)"
sudo make install
sudo ldconfig

# 2) Run DFQ+ demo topology
cd projects/DFQ+/
sudo python3 topo.py

