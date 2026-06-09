# Tactical Mesh Network Simulation — Phase 1
## Feasibility Study & Lab Build Guide

**Project:** NMS Congestion Detection and Routing Studies
**Scope:** Proof-of-concept — 4–6 node mesh, open-source toolchain, Linux VM on Windows host
**Status:** Draft for review
**Version:** 1.0

---

# QUICK START — REPRODUCE THE LAB

This section contains everything a new teammate needs to go from a fresh Windows machine to a running lab. Complete these steps in order before touching anything in Part 6.

## Prerequisites

**Windows host:**
- 16 GB RAM, 8-core CPU, 100 GB SSD (see Part 5.1 for full spec)
- WSL2 enabled with Ubuntu 22.04 or later
- Docker Desktop **or** Docker Engine installed inside WSL

**Check Docker is working in WSL before continuing:**
```bash
docker run --rm hello-world
```

If you get a permission error, add your user to the docker group:
```bash
sudo usermod -aG docker $USER
newgrp docker
```

## Step 1 — Clone the repo

```bash
git clone <repo-url> ~/tactical-mesh
cd ~/tactical-mesh
```

## Step 2 — Install Containerlab (no sudo required)

The installer script requires sudo for the `.deb` path. Use the binary install instead — it drops `clab` into `~/.local/bin` and works without root for the install step itself (sudo is still required at deploy time):

```bash
mkdir -p ~/.local/bin
curl -sL https://github.com/srl-labs/containerlab/releases/download/v0.54.2/containerlab_0.54.2_linux_amd64.tar.gz \
  -o /tmp/clab.tar.gz
tar -xzf /tmp/clab.tar.gz -C /tmp/ containerlab
mv /tmp/containerlab ~/.local/bin/clab
chmod +x ~/.local/bin/clab
clab version   # should print v0.54.2
```

## Step 3 — Pull the FRR image

```bash
docker pull frrouting/frr:v8.4.1
```

## Step 4 — Start the monitoring stack

Tthe monitoring stack runs entirely in Docker:

```bash
cd ~/tactical-mesh
docker compose up -d
```

This starts Grafana (`:3000`), Prometheus (`:9090`), Mosquitto MQTT broker (`:1883`), and snmp_exporter (`:9116`).

## Step 5 — Make localhost work from Windows

By default WSL2 uses a private IP and `localhost` on Windows does not reach WSL services. Add one line to `.wslconfig` to enable mirrored networking:

Create or edit `C:\Users\<YourUsername>\.wslconfig`:
```ini
[wsl2]
networkingMode=mirrored
```

Then restart WSL from a Windows PowerShell:
```powershell
wsl --shutdown
```

Reopen your WSL terminal and run `docker compose up -d` again. After this, `http://localhost:3000` works from any Windows browser.

> **Mirrored networking** requires Windows 11 22H2 or later and WSL version 2.0.0+. Check with `wsl --version`. If your build is older, use the WSL IP directly: run `hostname -I | awk '{print $1}'` inside WSL to get it.

## Step 6 — Deploy the topology

```bash
cd ~/tactical-mesh
sudo bash deploy.sh
```

This deploys all 8 containers, waits 30 s for OSPF to converge, prints the neighbour and route tables, and applies the WAN link impairments.

**Expected output (OSPF neighbours on nodeA):**
```
Neighbor ID     Pri State     Up Time   Interface
2.2.2.2           1 Full/DR   ~30s      eth1:10.1.0.1
3.3.3.3           1 Full/DR   ~30s      eth2:10.2.0.1
5.5.5.5           1 Full/DR   ~30s      eth3:10.3.0.1
```

**Expected output (BGP summary on nodeA):**
```
Neighbor      AS     State/PfxRcd
192.168.1.1   65001  1            ← wanSAT
192.168.2.1   65002  1            ← wanRAD
192.168.3.1   65003  1            ← wan5G
```

BGP path preference: 5G (LOCAL_PREF 300) > Radio (200) > SATCOM (100).

## Step 7 — Verify end-to-end

```bash
# Start iperf3 server on nodeD
docker exec clab-tactical-mesh-nodeD iperf3 -s -D

# Run baseline throughput test from nodeA to nodeD
docker exec clab-tactical-mesh-nodeA iperf3 -c 4.4.4.4 -t 10
```

Open Grafana at `http://localhost:3000` (admin / admin) and confirm dashboards are populating. You are now ready to run Scenarios 1–5 from Part 4.

## Tear down

```bash
cd ~/tactical-mesh
sudo ~/.local/bin/clab destroy --topo tactical-mesh.yml
docker compose down
```

---

# EXECUTIVE SUMMARY

This document covers the feasibility assessment and build instructions for a tactical mesh network simulation lab. The lab demonstrates routing protocol behaviour, link failure and recovery, congestion detection, and multi-WAN path management using an entirely open-source toolchain on a Windows-hosted Linux VM.

**The lab is feasible within the stated scope and hardware constraints.** All required capabilities — OSPF routing, BGP multi-WAN policy, link impairment emulation, SNMP/NetFlow/MQTT telemetry, and Grafana visualisation — are achievable with the proposed stack.

**Headline decisions:**

- **Containerlab + FRRouting + Docker** as the emulation platform. Runs real Linux network stacks, real routing daemons, real monitoring agents — not simulated behaviour.
- **OSPF as the mesh routing protocol, BGP at the WAN boundary.** This is the industry-standard approach for NMS-focused lab work. MANET-specific protocols are documented as future work for Phase 2 when mobility is introduced.
- **Three telemetry layers in parallel:** SNMP (polling), NetFlow v9 (flow attribution), and MQTT (event-driven push). Each answers a different question; together they give the NMS the full picture.
- **EIGRP deferred.** FRR's EIGRP implementation is experimental and not Cisco-interoperable. Assessed and excluded from v1.
- **RIP included as a negative-example demonstration only**, to show why OSPF is required.

**Expected build time:** 2–3 days for an engineer familiar with Linux networking. The reproducibility section (Part 6) contains all commands.

---

# PART 1: SCOPE AND REQUIREMENTS MAPPING

## 1.1 Original Requirements

| Requirement | Approach in This Lab | Status |
|---|---|---|
| 4–6 node mesh with multiple paths | 5-node mesh, 6 links, 3+ paths per node pair | Covered |
| OSPF support | FRR — full OSPF implementation with BFD | Covered |
| RIP support | FRR — included as negative-example demo | Covered |
| BGP support | FRR — BGP for multi-WAN path policy | Covered |
| EIGRP support | FRR EIGRP is experimental, not Cisco-interoperable | **Deferred** |
| Normal operation scenario | Scenario 1 | Covered |
| Link failure and route failover | Scenario 2 | Covered |
| Congestion on selected links | Scenario 3 | Covered |
| Multiple WAN paths (SATCOM, Radio, 5G) | Scenario 4 | Covered |
| NMS Lite per-node deployment | snmpd + node_exporter + softflowd + MQTT publisher | Covered |
| SNMP telemetry | snmpd on each node → Prometheus | Covered |
| NetFlow/sFlow telemetry | softflowd (NetFlow v9) → pmacct → Prometheus | Covered |
| MQTT telemetry | Mosquitto broker + per-node publisher | Covered |
| Grafana visualisation | Prometheus → Grafana | Covered |
| Hardware/software requirements | Part 5 | Covered |
| Linux VM on Windows | Ubuntu 22.04 on VMware/VirtualBox | Covered |
| Steps to reproduce | Part 6 | Covered |
| AI/DA suitability assessment | Part 7 | Covered |

## 1.2 What This Lab Is and Is Not

**Is:** A functional emulation environment where real routing protocols run, real traffic flows, real telemetry is collected, and real congestion events are detected and visualised.

**Is not:** A radio-accurate tactical radio simulation. Links are emulated as point-to-point pipes with configurable bandwidth, latency, and loss using Linux tc/netem. The wireless broadcast medium, node mobility, jamming, and terrain effects are out of scope for Phase 1. These are Phase 2 additions (CORE + EMANE).

---

# PART 2: ROUTING PROTOCOL ASSESSMENT

## 2.1 Assessment Summary

| Protocol | Verdict | Reason |
|---|---|---|
| **OSPF** | **Primary mesh protocol** | Full FRR support, link-state, metric-based, sub-second convergence with BFD |
| **BGP** | **WAN boundary protocol** | Multi-path WAN selection, policy via LOCAL_PREF |
| **RIP** | Negative-example demo only | Hop-count only; picks SATCOM over 5G — wrong for tactical |
| **EIGRP** | Deferred | FRR implementation experimental, IPv4-only, not Cisco-interoperable |

## 2.2 OSPF — Why It Is the Right Choice for Phase 1

OSPF is the industry-standard interior gateway protocol for NMS-focused lab work. Every node maintains a complete topology map (built from Link State Advertisements flooded across the network) and runs Dijkstra to compute optimal paths. When a link fails, OSPF detects it, refloods the topology change, and reconverges — all observable by the NMS.

OSPF metric is derived from link bandwidth, so the lab naturally prefers faster links without manual route configuration:

```
OSPF metric = Reference Bandwidth / Link Bandwidth

5G   (50 Mbps):    metric 2       ← preferred
Radio (256 Kbps):  metric 390
SATCOM (1 Mbps):   metric 100

Reference bandwidth set to 100 Mbps (FRR default)
→ Adjust: auto-cost reference-bandwidth 100000 (for 100 Gbps scale)
```

Convergence times are tunable. Default OSPF (40–45 s dead interval) is too slow for tactical use. With tuned timers and BFD:

```
Tuned timers only:    5–6 s convergence
With BFD enabled:     sub-second (50 ms transmit/receive interval)

FRR configuration:
  ip ospf hello-interval 1
  ip ospf dead-interval 4
  timers throttle spf 50 100 5000
  
BFD (per interface):
  ip ospf bfd
```

## 2.3 BGP — WAN Boundary Only

BGP is not used inside the mesh. It runs only on gateway nodes to select between WAN uplinks (SATCOM, Radio, 5G). Path preference is controlled by LOCAL_PREF:

```
5G path:      LOCAL_PREF 300  (primary)
Radio path:   LOCAL_PREF 200  (secondary)
SATCOM path:  LOCAL_PREF 100  (last resort)

When 5G fails → BGP withdraws the route → Radio becomes preferred
When Radio fails → SATCOM becomes preferred
When 5G restores → BGP re-advertises → traffic returns to primary
```

## 2.4 RIP — Negative Example

RIP counts hops only. It would select a 1-hop SATCOM link (500 ms, 1 Mbps) over a 2-hop 5G path (20 ms, 50 Mbps). This is the wrong decision for any traffic class. RIP is included in the lab topology only to demonstrate this failure mode — then replaced with OSPF to show the improvement. It requires no additional tooling; FRR supports RIP natively.

## 2.5 EIGRP — Deferred

EIGRP is Cisco-proprietary. FRR added partial EIGRP support but it is marked experimental in the FRR documentation, is IPv4-only, and does not interoperate reliably with Cisco IOS in multi-vendor scenarios. Including it in a lab that uses only open-source tooling provides no meaningful value. Assessment: **investigated, not feasible for open-source v1.**


---

# PART 3: PROPOSED ARCHITECTURE

## 3.1 Topology

```
                    [Node A]  ← Gateway node
                   /    |    \
             SATCOM  Radio   5G
                 /     |      \
            [Node C] [Node B] [Node E]
                 \     |      /
                Radio  5G  Radio
                   \   |   /
                   [Node D]

WAN link characteristics (emulated via tc/netem):

  5G:      50 Mbps   |  20 ms RTT   |  0% loss
  Radio:   256 Kbps  | 125 ms RTT   |  3% loss
  SATCOM:  1 Mbps    | 500 ms RTT   |  0% loss
```

**Node A** is the gateway node — the only node with all three WAN uplinks. It mirrors a forward command post with SATCOM, radio, and cellular options. All other nodes are mesh-interior nodes connected by Radio and 5G links.

**Why 5 nodes:** Sufficient to demonstrate multi-hop routing, multiple failure paths, and WAN failover. Fits comfortably in 4 GB RAM with headroom for the monitoring stack.

**Why this link pattern:** Every node pair has at least two paths (A→D via B, via C, or via E). No single link failure isolates any node. This is the minimum topology that makes failover scenarios meaningful.

## 3.2 Node Roles and Daemons

```
All nodes run:
  FRRouting (ospfd + bgpd on Node A; ospfd only on B–E)
  snmpd                (SNMP agent — telemetry L1)
  node_exporter        (Prometheus host metrics — telemetry L2)
  MQTT publisher       (event-driven alerts — telemetry L3)
  softflowd            (NetFlow v9 exporter — telemetry L4)
  iperf3 server        (traffic generation target)

VM host runs (not inside containers):
  Prometheus           (time-series storage)
  Grafana              (visualisation)
  Mosquitto            (MQTT broker)
  pmacct / nfacctd     (NetFlow v9 collector → Prometheus)
  AlertManager         (alert routing)
```

## 3.3 IP Addressing

```
Management network (Containerlab):  172.20.20.0/24

Point-to-point links (/30):
  Node A ↔ Node B  (5G):      10.1.0.0/30
  Node A ↔ Node C  (SATCOM):  10.2.0.0/30
  Node A ↔ Node E  (Radio):   10.3.0.0/30
  Node B ↔ Node D  (Radio):   10.4.0.0/30
  Node C ↔ Node D  (5G):      10.5.0.0/30
  Node D ↔ Node E  (Radio):   10.6.0.0/30

Loopbacks (OSPF Router ID):
  Node A: 1.1.1.1/32   Node B: 2.2.2.2/32   Node C: 3.3.3.3/32
  Node D: 4.4.4.4/32   Node E: 5.5.5.5/32

BGP ASNs and uplink point-to-point links (Node A is AS 65000):
  SATCOM uplink (wanSAT):  AS 65001   Node A 192.168.1.2/30 ↔ 192.168.1.1/30
  Radio uplink  (wanRAD):  AS 65002   Node A 192.168.2.2/30 ↔ 192.168.2.1/30
  5G uplink     (wan5G):   AS 65003   Node A 192.168.3.2/30 ↔ 192.168.3.1/30
```

## 3.4 Telemetry Architecture

The NMS uses three telemetry layers, each answering a different question:

```
Layer         Technology      Question answered              Latency
─────────────────────────────────────────────────────────────────────
SNMP          snmpd           Is this interface busy/up?    15 s poll
Node Exporter Prometheus      Is this node healthy?         15 s poll
NetFlow v9    softflowd       Who is causing the traffic?   Per-flow
MQTT          Mosquitto       Did a threshold just fire?    < 1 s push
```

**Why all three are needed:**

SNMP tells you link A→C is at 95% utilisation. NetFlow tells you one iperf3 TCP flow from Node A to Node D is consuming 93% of it. MQTT tells you within 1 second that the threshold was crossed, rather than waiting up to 15 seconds for the next SNMP poll. Without NetFlow, the NMS can alert but cannot recommend a specific remedy. Without MQTT, detection on SATCOM links (500 ms RTT) is too slow for SNMP polling to be practical.

**Data flow:**

```
Each node:
  snmpd ──────────────────────────────► Prometheus (poll every 15s)
  node_exporter ──────────────────────► Prometheus (poll every 15s)
  softflowd ──── NetFlow v9 ──────────► pmacct ──► Prometheus
  MQTT publisher ─── topic/alerts ───► Mosquitto ──► AlertManager

Prometheus ──► Grafana (5 dashboards)
           ──► AlertManager ──► log / notification
```

## 3.5 NMS Congestion Detection Logic

The NMS uses a rule-based event classifier to distinguish two event types that produce similar raw metrics but require different responses:

```
DISRUPTION event:        CONGESTION event:
  Link flap                Queue buildup
  Radio fade               Sustained overload
  OSPF reconvergence       Elephant flow

  → Suppress re-routing    → Recommend re-route
    for 5–10 s               or shape the flow
  → Do not alert as          → Alert as congestion
    congestion
```

Classifier inputs per link (10-second sliding window):

| Input | Source | Disruption signal | Congestion signal |
|---|---|---|---|
| Loss rate vs baseline | SNMP | Short burst, then zero | Gradual onset, sustained |
| Queue depth trend | Node Exporter | Stable | Rising |
| RTT vs baseline | Active probe | Spike then recovery | Sustained inflation |
| Interface state changes | SNMP | > 0 in window | 0 |
| OSPF traffic rate | NetFlow proto=89 | Elevated (LSA flood) | Normal |
| Dominant flow fraction | NetFlow | N/A | Single flow > 50% load |

## 3.6 Grafana Dashboards

Five dashboards minimum:

1. **Topology overview** — live link health (green/amber/red per link)
2. **Per-link metrics** — bandwidth, latency, loss time-series per WAN class
3. **Event classifier** — NORMAL / DISRUPTION / CONGESTION label stream per link
4. **Routing events** — OSPF neighbour state changes, BGP path changes, convergence time
5. **Top-talkers** — top 10 flows by bytes from NetFlow, updated every 30 s

---

# PART 4: TEST SCENARIOS

All scenarios capture three data points: OSPF convergence time, NMS detection latency, and classifier accuracy.

## Scenario 1: Normal Operation

**Purpose:** Establish baseline. Validate the full toolchain. Produce reference metrics (RTT, bandwidth, loss) that all other scenarios compare against.

**Steps:**
1. Deploy topology: `containerlab deploy --topo tactical-mesh.yml`
2. Verify all OSPF neighbours reach FULL state within 30 s.
3. Ping all node pairs. Verify RTT matches netem configuration ± 5%.
4. iperf3 throughput test on each link. Verify bandwidth matches netem rate cap ± 5%.
5. Verify Prometheus scraping all nodes (check targets page).
6. Verify Grafana dashboards populating.
7. Verify NetFlow top-talkers panel shows iperf3 flows.

**Pass criteria:**
- All OSPF neighbours FULL within 30 s.
- Measured RTT and bandwidth within 5% of configured values.
- All five Grafana dashboards show live data.
- iperf3 flows visible in NetFlow top-talkers panel.

---

## Scenario 2: Link Failure and Route Failover

**Purpose:** Measure OSPF convergence time under link failure. Verify the NMS classifies the event as DISRUPTION (not CONGESTION) and applies the re-routing suppression window rather than triggering a false congestion alarm.

**Steps:**
1. Start continuous iperf3 stream: Node A → Node D.
2. Record baseline RTT and throughput.
3. Bring down link A–B (primary 5G path):
   `docker exec clab-tactical-mesh-nodeA ip link set eth1 down`
4. Measure: time from link-down to traffic resumption (OSPF convergence time).
5. Verify traffic resumed on alternative path (check `vtysh -c "show ip route"`).
6. Verify Grafana routing-events dashboard shows the OSPF neighbour state change.
7. Verify classifier output shows DISRUPTION (not CONGESTION) during the event.
8. Verify no false congestion alert was raised.
9. Restore link: `docker exec clab-tactical-mesh-nodeA ip link set eth1 up`
10. Verify traffic returns to primary path.

**Pass criteria:**
- Convergence time ≤ 10 s (tuned timers); ≤ 1 s (with BFD).
- Classifier output: DISRUPTION during event, NORMAL after recovery.
- Zero false CONGESTION alerts raised during the failover.
- NetFlow shows OSPF traffic (proto=89) spike during reconvergence.

---

## Scenario 3: Congestion on Selected Links

**Purpose:** Demonstrate that the NMS correctly detects sustained queue buildup as CONGESTION, identifies the responsible flow via NetFlow, and raises a timely alert. Produces labeled CONGESTION training data for Phase 2.

**Background traffic (mixed, to make the scenario realistic):**
```
Alongside the primary iperf3 overload flow, run competing traffic:
  UDP elephant flow:  iperf3 -u -b 200K -t 60   (competing background)
  TCP mice flows:     iperf3 -b 10K -t 60        (short-lived bursts)
```

**Steps:**
1. Apply SATCOM impairment to link A–C (run inside nodeA — eth2 is the SATCOM interface):
   `docker exec clab-tactical-mesh-nodeA tc qdisc add dev eth2 root netem rate 1mbit delay 250ms`
2. Start background competing traffic (see above).
3. Push primary flow at 5× capacity:
   `iperf3 -c <NodeC_IP> -b 5M -t 60`
4. Observe: packet loss, RTT inflation, queue depth rising.
5. Verify MQTT alert published within 1 s of threshold crossing.
6. Verify Grafana congestion dashboard shows the event.
7. Verify NetFlow top-talkers identifies the primary iperf3 flow as > 50% of load.
8. Verify classifier output: CONGESTION (not DISRUPTION).
9. Note: OSPF will not re-route — it does not react to load. This is expected and correct. Document it.

**Pass criteria:**
- Packet loss > 5% sustained under overload.
- RTT inflates ≥ 2× configured base latency.
- MQTT alert within 1 s.
- NetFlow attributes ≥ 80% of link load to the primary flow.
- Classifier output: CONGESTION.
- OSPF routes unchanged (expected — load-based routing is a Phase 2 capability).

---

## Scenario 4: Multi-WAN Path Failover

**Purpose:** Validate that BGP LOCAL_PREF policy produces the expected WAN priority ordering (5G → Radio → SATCOM) and that failover cascades correctly. Measures RTT and throughput at each stage.

**Steps:**
1. Verify baseline: all three WAN paths active, traffic using 5G (lowest metric).
   Check with: `vtysh -c "show ip bgp" | grep LOCAL_PREF`
2. Bring down 5G uplink on Node A.
3. Verify traffic shifts to Radio. Record RTT change (20 ms → 125 ms expected).
4. Bring down Radio uplink on Node A.
5. Verify traffic shifts to SATCOM. Record RTT change (125 ms → 500 ms expected).
6. Restore Radio. Verify traffic returns to Radio (not SATCOM).
7. Restore 5G. Verify traffic returns to 5G.
8. Verify Grafana routing-events dashboard shows each BGP path change.

**Pass criteria:**
- Traffic follows priority: 5G > Radio > SATCOM at each stage.
- Measured RTT at each stage matches WAN class configuration ± 10%.
- Each failover within the convergence time measured in Scenario 2.
- Grafana shows BGP path changes at correct timestamps.

---

## Scenario 5: Disruption vs Congestion Discrimination

**Purpose:** Validate that the NMS event classifier correctly distinguishes link disruption events from true congestion — the most critical NMS capability. Without this, every radio fade generates a false congestion alarm.

**Steps:**
1. Establish baseline iperf3 flow over Radio link (Node A → Node E).

2. **Treatment A — disruption:**
   Inject 500 ms link blackout, then revert:
   ```bash
   # Run inside nodeA — eth3 is the Radio-to-NodeE interface.
   # netem `change` replaces the full parameter set — restate rate/delay
   # on revert so the Radio link returns to its baseline impairment.
   docker exec clab-tactical-mesh-nodeA tc qdisc change dev eth3 root netem rate 256kbit delay 62ms loss 100%
   sleep 0.5
   docker exec clab-tactical-mesh-nodeA tc qdisc change dev eth3 root netem rate 256kbit delay 62ms loss 3%
   ```
   Record: classifier output, queue depth, RTT trajectory.

3. **Treatment B — congestion:**
   Sustain 2× offered load for 30 s:
   `iperf3 -c <NodeE_IP> -b 512K -t 30`
   Record: classifier output, queue depth, RTT trajectory.

4. Compare signatures.

**Expected signatures:**

```
Disruption (Treatment A):
  Loss:        Short burst → immediately zero
  Queue depth: No buildup (link was down, no queuing)
  RTT:         Spike from reorder, then returns to baseline
  OSPF proto=89: Spike (reconvergence flood)
  Classifier:  DISRUPTION

Congestion (Treatment B):
  Loss:        Gradual onset, sustained
  Queue depth: Rising trend
  RTT:         Sustained inflation (queuing delay)
  OSPF proto=89: Normal
  Classifier:  CONGESTION
```

**Pass criteria:**
- Classifier accuracy: correct label on both treatments.
- OSPF traffic rate from NetFlow correctly distinguishes the two events.
- Zero false CONGESTION labels during Treatment A.

---

# PART 5: HARDWARE AND SOFTWARE REQUIREMENTS

## 5.1 Hardware

```
Windows host machine:
  RAM:   16 GB minimum  (8 GB allocated to VM, 8 GB for host OS)
  CPU:   8 cores        (4 allocated to VM)
  Disk:  100 GB SSD     (60 GB for VM, remainder for host)
  NIC:   Standard — no special requirements

Ubuntu VM:
  RAM:   8 GB
  CPU:   4 cores
  Disk:  60 GB
  OS:    Ubuntu Server 22.04 LTS
  Kernel: 5.15+ (Ubuntu 22.04 default — required for BBR and tc/netem)
```

**Note on VM performance ceiling:** the 5 mesh nodes plus 3 lightweight WAN peer containers (8 FRR containers total) are well within these limits. Do not scale beyond 8–10 nodes on this hardware without increasing RAM. Each FRR container consumes approximately 150–200 MB RAM; the monitoring stack (Prometheus, Grafana, pmacct) consumes approximately 1 GB.

## 5.2 Software Stack

| Component | Version | Role | Install location |
|---|---|---|---|
| VMware Workstation / VirtualBox | Latest | Hypervisor | Windows host |
| Ubuntu Server | 22.04 LTS | VM OS | VM |
| Docker Engine | 24.x | Container runtime | VM |
| Containerlab | 0.54.x | Topology orchestrator | VM |
| FRRouting image | `frrouting/frr:v8.4.1` | Routing daemon | Container |
| snmpd | 5.9.x | SNMP agent | Container |
| snmp_exporter | 0.25.x | SNMP→Prometheus bridge (if_mib) | VM host |
| node_exporter | 1.7.x | Host metrics exporter | Container |
| softflowd | 1.0.0 | NetFlow v9 exporter | Container |
| Mosquitto | 2.0.x | MQTT broker | VM host |
| pmacct (nfacctd) | 1.7.x | NetFlow collector | VM host |
| nfdump | 1.7.x | NetFlow offline analysis | VM host |
| Prometheus | 2.x | Time-series storage | VM host |
| Grafana | 10.x | Visualisation | VM host |
| AlertManager | 0.26.x | Alert routing | VM host |
| iperf3 | 3.16 | Traffic generator | Container |
| Python | 3.10+ | Event classifier scripts | VM host |

---

# PART 6: STEPS TO REPRODUCE

## 6.1 Prepare the VM

```bash
# 1. Update system
sudo apt update && sudo apt upgrade -y

# 2. Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

# 3. Install Containerlab
bash -c "$(curl -sL https://get.containerlab.dev)"

# 4. Verify
docker --version
containerlab version

# 5. Pull FRR image
docker pull frrouting/frr:v8.4.1
```

## 6.2 Install the Monitoring Stack (VM host, not containers)

```bash
# Prometheus
wget https://github.com/prometheus/prometheus/releases/download/v2.48.0/prometheus-2.48.0.linux-amd64.tar.gz
tar xvf prometheus-2.48.0.linux-amd64.tar.gz
sudo mv prometheus-2.48.0.linux-amd64/prometheus /usr/local/bin/

# Grafana
sudo apt install -y apt-transport-https software-properties-common
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update && sudo apt install -y grafana

# Mosquitto (MQTT broker)
sudo apt install -y mosquitto mosquitto-clients

# snmp_exporter (SNMP → Prometheus bridge, listens on :9116)
wget https://github.com/prometheus/snmp_exporter/releases/download/v0.25.0/snmp_exporter-0.25.0.linux-amd64.tar.gz
tar xvf snmp_exporter-0.25.0.linux-amd64.tar.gz
sudo mv snmp_exporter-0.25.0.linux-amd64/snmp_exporter /usr/local/bin/

# pmacct (NetFlow collector)
sudo apt install -y pmacct

# nfdump (offline analysis)
sudo apt install -y nfdump

# Start services
sudo systemctl enable --now grafana-server mosquitto prometheus
```

## 6.3 Topology YAML

Save as `tactical-mesh.yml`:

```yaml
name: tactical-mesh

topology:
  nodes:
    nodeA:
      kind: linux
      image: frrouting/frr:v8.4.1
      binds:
        - configs/nodeA/frr.conf:/etc/frr/frr.conf
    nodeB:
      kind: linux
      image: frrouting/frr:v8.4.1
      binds:
        - configs/nodeB/frr.conf:/etc/frr/frr.conf
    nodeC:
      kind: linux
      image: frrouting/frr:v8.4.1
      binds:
        - configs/nodeC/frr.conf:/etc/frr/frr.conf
    nodeD:
      kind: linux
      image: frrouting/frr:v8.4.1
      binds:
        - configs/nodeD/frr.conf:/etc/frr/frr.conf
    nodeE:
      kind: linux
      image: frrouting/frr:v8.4.1
      binds:
        - configs/nodeE/frr.conf:/etc/frr/frr.conf

    # WAN uplink peers (eBGP) — represent SATCOM/Radio/5G provider edges
    wanSAT:
      kind: linux
      image: frrouting/frr:v8.4.1
      binds:
        - configs/wanSAT/frr.conf:/etc/frr/frr.conf
    wanRAD:
      kind: linux
      image: frrouting/frr:v8.4.1
      binds:
        - configs/wanRAD/frr.conf:/etc/frr/frr.conf
    wan5G:
      kind: linux
      image: frrouting/frr:v8.4.1
      binds:
        - configs/wan5G/frr.conf:/etc/frr/frr.conf

  links:
    - endpoints: ["nodeA:eth1", "nodeB:eth1"]   # 5G (mesh)
    - endpoints: ["nodeA:eth2", "nodeC:eth1"]   # SATCOM (mesh)
    - endpoints: ["nodeA:eth3", "nodeE:eth1"]   # Radio (mesh)
    - endpoints: ["nodeB:eth2", "nodeD:eth1"]   # Radio (mesh)
    - endpoints: ["nodeC:eth2", "nodeD:eth2"]   # 5G (mesh)
    - endpoints: ["nodeD:eth3", "nodeE:eth2"]   # Radio (mesh)
    - endpoints: ["nodeA:eth4", "wanSAT:eth1"]  # SATCOM WAN uplink (eBGP AS 65001)
    - endpoints: ["nodeA:eth5", "wanRAD:eth1"]  # Radio WAN uplink  (eBGP AS 65002)
    - endpoints: ["nodeA:eth6", "wan5G:eth1"]   # 5G WAN uplink     (eBGP AS 65003)
```

## 6.4 FRR Configuration (Node A — gateway node)

Save as `configs/nodeA/frr.conf`:

```
frr version 8.4.1
hostname nodeA
log syslog informational

interface lo
 ip address 1.1.1.1/32
!
! eth0 is reserved by containerlab for management — user links start at eth1
interface eth1
 description 5G-to-NodeB
 ip address 10.1.0.1/30
 ip ospf hello-interval 1
 ip ospf dead-interval 4
 ip ospf bfd
 ip ospf cost 2
!
interface eth2
 description SATCOM-to-NodeC
 ip address 10.2.0.1/30
 ip ospf hello-interval 1
 ip ospf dead-interval 4
 ip ospf bfd
 ip ospf cost 100
!
interface eth3
 description Radio-to-NodeE
 ip address 10.3.0.1/30
 ip ospf hello-interval 1
 ip ospf dead-interval 4
 ip ospf bfd
 ip ospf cost 390
!
! WAN uplink interfaces (BGP eBGP peers — not in OSPF)
interface eth4
 description WAN-SATCOM-uplink
 ip address 192.168.1.2/30
!
interface eth5
 description WAN-Radio-uplink
 ip address 192.168.2.2/30
!
interface eth6
 description WAN-5G-uplink
 ip address 192.168.3.2/30
!
router ospf
 ospf router-id 1.1.1.1
 auto-cost reference-bandwidth 100000
 timers throttle spf 50 100 5000
 network 1.1.1.1/32 area 0
 network 10.1.0.0/30 area 0
 network 10.2.0.0/30 area 0
 network 10.3.0.0/30 area 0
 redistribute bgp route-map FROM-BGP
!
router bgp 65000
 bgp router-id 1.1.1.1
 neighbor 192.168.1.1 remote-as 65001
 neighbor 192.168.2.1 remote-as 65002
 neighbor 192.168.3.1 remote-as 65003
 !
 address-family ipv4 unicast
  neighbor 192.168.1.1 route-map SET-PREF-SATCOM in
  neighbor 192.168.2.1 route-map SET-PREF-RADIO in
  neighbor 192.168.3.1 route-map SET-PREF-5G in
  redistribute ospf route-map FROM-OSPF
 exit-address-family
!
! --- Mutual-redistribution loop guard ---
! Tag routes as they cross each protocol boundary and deny re-injection
! of a protocol's own routes back into it. Prevents OSPF<->BGP feedback.
route-map FROM-OSPF permit 10
 match tag 100
 on-match goto 20
route-map FROM-OSPF deny 15
 match tag 200
route-map FROM-OSPF permit 20
 set tag 200
!
route-map FROM-BGP deny 5
 match tag 200
route-map FROM-BGP permit 10
 set tag 100
!
route-map SET-PREF-5G permit 10
 set local-preference 300
!
route-map SET-PREF-RADIO permit 10
 set local-preference 200
!
route-map SET-PREF-SATCOM permit 10
 set local-preference 100
!
bfd
 peer 10.1.0.2
  receive-interval 50
  transmit-interval 50
 !
 peer 10.2.0.2
  receive-interval 50
  transmit-interval 50
 !
 peer 10.3.0.2
  receive-interval 50
  transmit-interval 50
 !
```

Mesh-interior nodes (B–E) run only OSPF — no BGP. Same interface configuration, adjusted addresses and costs.

The three WAN peer nodes (`wanSAT` AS 65001, `wanRAD` AS 65002, `wan5G` AS 65003) each run a minimal `router bgp <asn>` with a single eBGP `neighbor` back to Node A's uplink address (`192.168.x.2 remote-as 65000`) and originate a default/test prefix so Scenario 4 failover has routes to shift between. They run no OSPF.

## 6.5 Apply WAN Link Impairments

Run after deploying the topology. Apply from inside each container or via `docker exec`:

```bash
# Alternatively, run apply-impairments.sh which handles all links and both directions:
bash apply-impairments.sh

# Or apply manually (shown for nodeA only — repeat equivalent commands on peer nodes):

# 5G link: Node A ↔ Node B  (nodeA:eth1)
docker exec clab-tactical-mesh-nodeA tc qdisc add dev eth1 root netem \
  rate 50mbit delay 10ms

# SATCOM link: Node A ↔ Node C  (nodeA:eth2)
docker exec clab-tactical-mesh-nodeA tc qdisc add dev eth2 root netem \
  rate 1mbit delay 250ms

# Radio link: Node A ↔ Node E  (nodeA:eth3)
docker exec clab-tactical-mesh-nodeA tc qdisc add dev eth3 root netem \
  rate 256kbit delay 62ms loss 3%
```

## 6.6 Configure NetFlow Export (softflowd)

Install and start inside each container:

```bash
# Inside each container (run via docker exec)
apt-get install -y softflowd
# eth0 is the containerlab management interface — monitor user-facing links starting at eth1
softflowd -i eth1 -n 172.20.20.1:9995 -v 9 -t maxlife=60
# Repeat for eth2, eth3 etc. on multi-interface nodes
```

pmacct configuration (`/etc/pmacct/nfacctd.conf` on host):

```
daemonize: false
pidfile: /var/run/pmacct/nfacctd.pid
collector_port: 9995
plugins: prometheus
prometheus_output: standard
prometheus_port: 9101
aggregate: src_host, dst_host, src_port, dst_port, proto, in_iface
```

## 6.7 Configure Prometheus Scrape

Add to `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'snmp'
    metrics_path: /snmp
    params:
      module: [if_mib]
    static_configs:
      - targets:
        - 172.20.20.2   # nodeA
        - 172.20.20.3   # nodeB
        - 172.20.20.4   # nodeC
        - 172.20.20.5   # nodeD
        - 172.20.20.6   # nodeE
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: localhost:9116   # snmp_exporter on VM host

  - job_name: 'node_exporter'
    static_configs:
      - targets:
        - 172.20.20.2:9100
        - 172.20.20.3:9100
        - 172.20.20.4:9100
        - 172.20.20.5:9100
        - 172.20.20.6:9100

  - job_name: 'pmacct_netflow'
    static_configs:
      - targets: ['localhost:9101']   # nfacctd Prometheus output (distinct from node_exporter 9100)
```

## 6.8 Deploy and Verify

```bash
# Deploy (use deploy.sh which also applies impairments)
sudo bash deploy.sh

# Verify OSPF
docker exec clab-tactical-mesh-nodeA vtysh -c "show ip ospf neighbor"

# Verify routing table
docker exec clab-tactical-mesh-nodeA vtysh -c "show ip route"

# Run a baseline iperf3 test
docker exec clab-tactical-mesh-nodeD iperf3 -s -D
docker exec clab-tactical-mesh-nodeA iperf3 -c 4.4.4.4 -t 10

# Check Grafana (open browser)
# http://localhost:3000

# Tear down
sudo ~/.local/bin/clab destroy --topo tactical-mesh.yml
docker compose down
```

---

# PART 7: SUITABILITY FOR AI/DA USE CASES

The requirement asks for an assessment of suitability for future AI/DA use cases including congestion detection, route recommendation, and network optimisation. This section answers that question concisely. Detailed AI/DA architecture is a Phase 2 document.

## 7.1 What This Lab Produces

Every scenario run produces structured, timestamped telemetry in Prometheus:

- Per-link metrics: bandwidth utilisation, packet loss rate, RTT, queue depth
- Per-flow records: source, destination, protocol, bytes, port (from NetFlow)
- Routing events: OSPF convergence timestamps, BGP path changes
- Classifier labels: NORMAL / DISRUPTION / CONGESTION per link per time window

This is labeled training data. Scenario 5 in particular produces matched pairs of DISRUPTION and CONGESTION events with identical surface metrics but different root causes — exactly the kind of data needed to train a classifier that is more sophisticated than the rule-based v1.

## 7.2 Three AI/DA Use Cases This Lab Enables

**1. Predictive congestion detection**
Train a model on the time-series signatures preceding congestion events (RTT trending upward, utilisation crossing 70%, specific flow types). Predict congestion 30–60 s before it becomes critical. Input data: Prometheus time-series from Scenarios 3 and 5.

**2. Route recommendation**
Train a model on the relationship between link metrics and routing decisions. Given current link states, recommend which path will produce the best outcome for a given traffic class. Input data: Prometheus metrics + OSPF route tables from Scenarios 2 and 4.

**3. Congestion root-cause attribution**
Use NetFlow traffic matrices to identify which application or node is the source of congestion, and recommend targeted remediation (re-route that flow, rate-limit that source) rather than generic alerts. Input data: NetFlow records from Scenario 3.

## 7.3 Honest Assessment

The lab is suitable for Phase 2 AI/DA development with two caveats:

**Caveat 1 — Static topology limits generalisation.** Models trained on this fixed 5-node topology may not generalise to larger or more dynamic networks. This is expected and acceptable for a Phase 1 lab; Phase 2 adds mobility and topology variation.

**Caveat 2 — Emulated traffic, not real applications.** iperf3 and generated traffic have different statistical signatures from real C2/voice/ISR applications. The classifier and any trained models should be re-validated against realistic traffic profiles before deployment.

---

# PART 8: RISKS AND LIMITATIONS

## 8.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| tc/netem cannot model correlated/bursty radio loss accurately | Medium | Reduced radio scenario fidelity | Use `loss X% Y%` (correlated) and `gemodel` parameters |
| FRR EIGRP not Cisco-interoperable | Certain | Requirement gap | Documented as assessed and deferred |
| softflowd CPU overhead in containers | Medium | Container resource contention | Set flow sampling rate; monitor via node_exporter |
| pmacct NetFlow → Prometheus bridge configuration | Medium | Missing L5 telemetry | Follow pmacct docs for nfacctd + prometheus plugin; test early |
| OSPF convergence >10 s without BFD | Medium | Slow failover | Enable BFD on all P2P links; verify in Scenario 2 |
| Windows host clock drift affecting OSPF timers | Low | Routing instability | Enable NTP on both Windows host and Ubuntu VM |

## 8.2 Scope Limitations

The following are explicitly out of scope for Phase 1 and documented as Phase 2 additions:

- **No RF realism.** Links are point-to-point pipes. Wireless broadcast medium, node mobility, jamming, terrain, and antenna effects are not modelled.
- **No MANET routing protocols.** OLSR, BATMAN-adv, and AODV are Phase 2 additions once mobility is introduced.
- **No application traffic profiles.** iperf3 is used for all traffic. Real C2, voice, and ISR traffic patterns are not modelled.
- **No security overlays.** IPsec/MACsec are out of scope. These change link MTU and CPU overhead and would need separate assessment.
- **Static topology only.** No node mobility. The five nodes are fixed for the duration of each scenario.

## 8.3 What Good Looks Like

The lab is successful when:

1. All five scenarios produce measurable, repeatable results.
2. The NMS correctly classifies DISRUPTION and CONGESTION events with < 5% false positive rate.
3. NetFlow top-talkers panel correctly identifies the responsible flow during Scenario 3.
4. OSPF convergence time meets the target (≤ 10 s tuned, ≤ 1 s with BFD).
5. The full stack can be deployed and torn down reproducibly from the commands in Part 6.

---

# PART 9: GLOSSARY

```
AlertManager    Prometheus component — routes alerts to destinations
BBR             Bottleneck Bandwidth & RTT — delay-based TCP CC (Google)
BFD             Bidirectional Forwarding Detection — sub-second link failure detection
BGP             Border Gateway Protocol — inter-AS and WAN path routing
CC              Congestion Control
Containerlab    Container-based network topology orchestrator (Nokia)
CWND            Congestion Window — bytes in-flight in TCP
FRR             FRRouting — open-source routing daemon suite
Grafana         Metrics visualisation platform
iperf3          Network throughput and traffic generation tool
LOCAL_PREF      BGP attribute for path preference within an AS
LSA             Link State Advertisement — OSPF topology update message
MQTT            Message Queuing Telemetry Transport — lightweight pub/sub protocol
netem           Linux network emulator (tc qdisc) — adds delay/loss/rate limits
NetFlow v9      Cisco flow export standard; exports per-flow records (RFC 3954)
NMS             Network Management System
OSPF            Open Shortest Path First — link-state interior gateway protocol
pmacct          Network accounting daemon; NetFlow/sFlow collector with Prometheus output
Prometheus      Time-series metrics database
PromQL          Prometheus query language
RTT             Round Trip Time — time for a packet to reach destination and ACK to return
SATCOM          Satellite communication link
SNMP            Simple Network Management Protocol — network device telemetry
softflowd       Lightweight NetFlow v9 exporter daemon for Linux
SPF             Shortest Path First — Dijkstra algorithm used by OSPF
tc              Linux traffic control — interface for netem and rate limiting
UHF             Ultra High Frequency — radio band used in tactical communications
WAN             Wide Area Network
```

---

*Phase 1 — Tactical Mesh Network Simulation*
*Version 1.0 — feasibility study and build guide*
*Phase 2 document (AI/DA roadmap, MANET protocols, MARLIN) is a separate deliverable*
