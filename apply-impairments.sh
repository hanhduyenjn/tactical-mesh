#!/usr/bin/env bash
# Apply WAN link impairments via tc/netem after topology is deployed.
# Run from the tactical-mesh directory.
# Note: containerlab linux nodes reserve eth0 for management; user links start at eth1.

set -e

echo "=== Applying WAN link impairments ==="

# 5G links: 50 Mbps, 10 ms one-way (20 ms RTT)
echo "  nodeA eth1 <-> nodeB eth1  (5G)"
docker exec clab-tactical-mesh-nodeA tc qdisc add dev eth1 root netem rate 50mbit delay 10ms
docker exec clab-tactical-mesh-nodeB tc qdisc add dev eth1 root netem rate 50mbit delay 10ms

echo "  nodeC eth2 <-> nodeD eth2  (5G)"
docker exec clab-tactical-mesh-nodeC tc qdisc add dev eth2 root netem rate 50mbit delay 10ms
docker exec clab-tactical-mesh-nodeD tc qdisc add dev eth2 root netem rate 50mbit delay 10ms

# SATCOM link: 1 Mbps, 250 ms one-way (500 ms RTT)
echo "  nodeA eth2 <-> nodeC eth1  (SATCOM)"
docker exec clab-tactical-mesh-nodeA tc qdisc add dev eth2 root netem rate 1mbit delay 250ms
docker exec clab-tactical-mesh-nodeC tc qdisc add dev eth1 root netem rate 1mbit delay 250ms

# Radio links: 256 Kbps, 62 ms one-way (125 ms RTT), 3% loss
echo "  nodeA eth3 <-> nodeE eth1  (Radio)"
docker exec clab-tactical-mesh-nodeA tc qdisc add dev eth3 root netem rate 256kbit delay 62ms loss 3%
docker exec clab-tactical-mesh-nodeE tc qdisc add dev eth1 root netem rate 256kbit delay 62ms loss 3%

echo "  nodeB eth2 <-> nodeD eth1  (Radio)"
docker exec clab-tactical-mesh-nodeB tc qdisc add dev eth2 root netem rate 256kbit delay 62ms loss 3%
docker exec clab-tactical-mesh-nodeD tc qdisc add dev eth1 root netem rate 256kbit delay 62ms loss 3%

echo "  nodeD eth3 <-> nodeE eth2  (Radio)"
docker exec clab-tactical-mesh-nodeD tc qdisc add dev eth3 root netem rate 256kbit delay 62ms loss 3%
docker exec clab-tactical-mesh-nodeE tc qdisc add dev eth2 root netem rate 256kbit delay 62ms loss 3%

echo "=== Impairments applied ==="
