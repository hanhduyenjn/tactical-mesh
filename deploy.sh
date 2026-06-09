#!/usr/bin/env bash
# Full lab deploy sequence.
# Run from the tactical-mesh directory with: sudo bash deploy.sh

set -e
cd "$(dirname "$0")"

# clab is installed in the invoking user's ~/.local/bin — find it regardless of sudo PATH
SUDO_USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
CLAB=$(command -v clab 2>/dev/null || echo "$SUDO_USER_HOME/.local/bin/clab")

echo "=== Deploying tactical-mesh topology ==="
"$CLAB" deploy --topo tactical-mesh.yml

echo "=== Waiting 30s for OSPF to converge ==="
sleep 30

echo "=== OSPF neighbours (nodeA) ==="
docker exec clab-tactical-mesh-nodeA vtysh -c "show ip ospf neighbor"

echo "=== BGP summary (nodeA) ==="
docker exec clab-tactical-mesh-nodeA vtysh -c "show ip bgp summary"

echo "=== Applying WAN link impairments ==="
bash apply-impairments.sh

echo "=== Route table (nodeA) ==="
docker exec clab-tactical-mesh-nodeA vtysh -c "show ip route"

echo ""
echo "=== Lab is up. Next steps: ==="
echo "  - Run Scenario 1 baseline: docker exec clab-tactical-mesh-nodeD iperf3 -s -D"
echo "                             docker exec clab-tactical-mesh-nodeA iperf3 -c 4.4.4.4 -t 10"
echo "  - Grafana: http://localhost:3000"
echo "  - Tear down: sudo bash -c 'clab destroy --topo tactical-mesh.yml || ~/.local/bin/clab destroy --topo tactical-mesh.yml'"
