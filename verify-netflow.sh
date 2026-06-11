#!/usr/bin/env bash
# Verify the NetFlow telemetry pipeline end to end:
#   softflowd (per-node sidecars) -> nfacctd -> flow_exporter (:9101) -> Prometheus (:9090)
#
# Checks, in order:
#   1. softflowd sidecars are running on `-i any` and not crash-looping
#   2. nfacctd is producing flow records, with peer_ip_src (exporter identity) populated
#   3. flow_exporter exposes netflow_bytes with a populated `exporter` label on :9101
#   4. Prometheus has scraped netflow_bytes and can break it down by exporter
#   5. management traffic (172.20.20.0/24) is NOT present — the BPF capture filter works
#
# Also prints the live exporter-IP -> node-name mapping, since containerlab assigns
# management IPs by start order (NOT by node name) and they change across redeploys.
# Use that mapping to build dedup queries, e.g. exclude the gateway node's redundant
# mesh observations:  netflow_bytes{exporter!="<nodeA mgmt IP>"}
#
# Run from anywhere; targets the host-network services on localhost.

PROM=http://localhost:9090
EXPORTER=http://localhost:9101
NODES="nodeA nodeB nodeC nodeD nodeE"
SIDECARS="softflowd-nodeA softflowd-nodeB softflowd-nodeC softflowd-nodeD softflowd-nodeE"

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; }

echo "=== exporter IP -> node mapping (NOT stable across redeploys) ==="
for c in $NODES; do
  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "clab-tactical-mesh-$c" 2>/dev/null)
  printf '  %-6s -> %s\n' "$c" "$ip"
done
echo

echo "=== 1. softflowd sidecars running on -i any, no crash loop ==="
for s in $SIDECARS; do
  status=$(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "$s" 2>/dev/null)
  iface=$(docker logs "$s" 2>&1 | grep -o 'Exporting flows from [a-z0-9]*' | tail -1)
  printf '  %-18s %s  [%s]\n' "$s" "$status" "$iface"
done
echo

echo "=== 2. nfacctd producing flows with exporter identity (peer_ip_src) ==="
nflows=$(docker exec nfacctd sh -c 'cat /tmp/flows.json 2>/dev/null | wc -l')
if [ "${nflows:-0}" -gt 0 ]; then pass "$nflows flow records in flows.json"; else fail "flows.json empty"; fi
npeer=$(docker exec nfacctd sh -c 'cat /tmp/flows.json 2>/dev/null' | grep -c 'peer_ip_src')
if [ "${npeer:-0}" -gt 0 ]; then pass "$npeer records carry peer_ip_src"; else fail "no peer_ip_src — check nfacctd aggregate key"; fi
echo "  distinct exporters in flows.json:"
docker exec nfacctd sh -c 'cat /tmp/flows.json 2>/dev/null' \
  | grep -o '"peer_ip_src": "[0-9.]*"' | sort | uniq -c | sed 's/^/    /'
echo

echo "=== 3. flow_exporter exposes netflow_bytes with exporter label (:9101) ==="
sample=$(curl -s "$EXPORTER/metrics" | grep '^netflow_bytes' | head -1)
if echo "$sample" | grep -q 'exporter="[0-9.]'; then
  pass "exporter label populated"
  echo "    e.g. $sample"
else
  fail "exporter label missing/empty — check flow_exporter.py reads peer_ip_src"
fi
echo

echo "=== 4. Prometheus scraped netflow_bytes, breaks down by exporter (:9090) ==="
cnt=$(curl -s "$PROM/api/v1/query?query=count(netflow_bytes)" \
  | grep -o '"value":\[[0-9.]*,"[0-9]*"\]' | grep -o '"[0-9]*"]' | tr -dc '0-9')
if [ "${cnt:-0}" -gt 0 ]; then pass "$cnt netflow_bytes series in Prometheus"; else fail "Prometheus has no netflow_bytes — check scrape config / target"; fi
echo "  series by exporter:"
curl -s "$PROM/api/v1/query?query=count%20by(exporter)(netflow_bytes)" \
  | grep -o '"exporter":"[0-9.]*"' | sort | uniq -c | sed 's/^/    /'
echo

echo "=== 5. management traffic filtered out (BPF: not net 172.20.20.0/24) ==="
leak=$(curl -s "$PROM/api/v1/query?query=netflow_bytes%7Bsrc=~%22172.20.20..%2B%22%7D" \
  | grep -o '"src":"172\.20\.20\.[0-9]*"' | sort -u)
if [ -z "$leak" ]; then pass "no 172.20.20.x flows — capture filter working"; else fail "management traffic leaked:"; echo "$leak" | sed 's/^/    /'; fi
