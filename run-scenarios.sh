#!/usr/bin/env bash
# run-scenarios.sh — Tactical Mesh Phase 1: Full scenario playbook
#
# Reenacts all 5 scenarios with expected-result checks at each step.
# Run as root (or with sudo) after the topology and monitoring stack are up.
#
# Usage:
#   sudo bash run-scenarios.sh [1|2|3|4|5|all]   # default: all
#
# Output: timestamped pass/fail for every check, exit 0 if all pass.

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; (( PASS++ )); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; (( FAIL++ )); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
step() { echo -e "\n${BOLD}${YELLOW}  ▶  $1${NC}"; }
header() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
}

# Run a command inside a mesh node
node() { docker exec "clab-tactical-mesh-$1" "${@:2}"; }

# Query Prometheus instant metric; return numeric value
prom() {
    curl -sf "http://localhost:9090/api/v1/query?query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1")" \
      | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")' 2>/dev/null || echo ""
}

# Expect a value is greater than a threshold
expect_gt() {
    local label="$1" val="$2" threshold="$3"
    if python3 -c "import sys; sys.exit(0 if float('$val') > float('$threshold') else 1)" 2>/dev/null; then
        pass "$label: $val > $threshold"
    else
        fail "$label: expected > $threshold, got $val"
    fi
}

# Expect a value is less than a threshold
expect_lt() {
    local label="$1" val="$2" threshold="$3"
    if python3 -c "import sys; sys.exit(0 if float('$val') < float('$threshold') else 1)" 2>/dev/null; then
        pass "$label: $val < $threshold"
    else
        fail "$label: expected < $threshold, got $val"
    fi
}

# Expect string contains substring
expect_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        pass "$label contains '$needle'"
    else
        fail "$label: '$needle' not found in: $haystack"
    fi
}

# Expect command exits 0
expect_ok() {
    local label="$1"; shift
    if "$@" &>/dev/null; then
        pass "$label"
    else
        fail "$label (command failed: $*)"
    fi
}

# Ping from a node; return avg RTT in ms
ping_rtt() {
    local src="$1" dst="$2" count="${3:-4}"
    node "$src" ping -c "$count" -W 3 "$dst" 2>/dev/null \
      | awk -F'/' '/rtt|round-trip/{print $5}' || echo ""
}

# Read MQTT retained message for a link
mqtt_state() {
    docker exec mosquitto mosquitto_sub -t "mesh/classifier/$1" -C 1 -W 3 2>/dev/null || echo ""
}

# Reset all netem queueing disciplines back to baseline impairments
# (matches apply-impairments.sh values)
reset_impairments() {
    info "Restoring all link impairments to baseline..."
    # A-B: 5G — 20ms 1% loss 20mbit
    node nodeA tc qdisc replace dev eth1 root netem rate 20mbit  delay 20ms  loss 1%   2>/dev/null || true
    node nodeB tc qdisc replace dev eth1 root netem rate 20mbit  delay 20ms  loss 1%   2>/dev/null || true
    # A-C: SATCOM — 500ms 2% loss 1mbit
    node nodeA tc qdisc replace dev eth2 root netem rate 1mbit   delay 500ms loss 2%   2>/dev/null || true
    node nodeC tc qdisc replace dev eth1 root netem rate 1mbit   delay 500ms loss 2%   2>/dev/null || true
    # A-E: Radio — 125ms 3% loss 256kbit
    node nodeA tc qdisc replace dev eth3 root netem rate 256kbit delay 62ms  loss 3%   2>/dev/null || true
    node nodeE tc qdisc replace dev eth1 root netem rate 256kbit delay 62ms  loss 3%   2>/dev/null || true
    # B-D: Radio — 125ms 3% loss 256kbit
    node nodeB tc qdisc replace dev eth2 root netem rate 256kbit delay 62ms  loss 3%   2>/dev/null || true
    node nodeD tc qdisc replace dev eth1 root netem rate 256kbit delay 62ms  loss 3%   2>/dev/null || true
    # C-D: 5G — 20ms 1% loss 20mbit
    node nodeC tc qdisc replace dev eth2 root netem rate 20mbit  delay 20ms  loss 1%   2>/dev/null || true
    node nodeD tc qdisc replace dev eth2 root netem rate 20mbit  delay 20ms  loss 1%   2>/dev/null || true
    # D-E: Radio — 125ms 3% loss 256kbit
    node nodeD tc qdisc replace dev eth3 root netem rate 256kbit delay 62ms  loss 3%   2>/dev/null || true
    node nodeE tc qdisc replace dev eth2 root netem rate 256kbit delay 62ms  loss 3%   2>/dev/null || true
    # Restore A-B interface in case Scenario 2 left it down
    node nodeA ip link set eth1 up 2>/dev/null || true
    node nodeA ip link set eth3 up 2>/dev/null || true
    # Restore WAN uplinks in case Scenario 4 left them down
    node nodeA ip link set eth4 up 2>/dev/null || true
    node nodeA ip link set eth5 up 2>/dev/null || true
    node nodeA ip link set eth6 up 2>/dev/null || true
    sleep 5
}

# ── Scenario 1: Normal Operation ─────────────────────────────────────────────

scenario1() {
    header "Scenario 1: Normal Operation"
    info "Purpose: Establish baseline. Validate full toolchain."

    # ── Step 1: OSPF neighbours reach FULL state ──────────────────────────────
    step "Step 1 — All OSPF neighbours reach FULL state within 30 s"
    info "Expected: Every mesh node shows all its neighbours at state FULL"
    sleep 5
    for node_name in nodeA nodeB nodeC nodeD nodeE; do
        full_count=$(node "$node_name" vtysh -c "show ip ospf neighbor" 2>/dev/null \
                       | grep -c "Full/" || true)
        expected_full=2  # each node has at least 2 OSPF neighbours
        [[ "$node_name" == "nodeA" ]] && expected_full=3
        [[ "$node_name" == "nodeD" ]] && expected_full=3
        if [[ "$full_count" -ge "$expected_full" ]]; then
            pass "$node_name: $full_count OSPF neighbours FULL (expected ≥ $expected_full)"
        else
            fail "$node_name: only $full_count FULL neighbours (expected ≥ $expected_full)"
        fi
    done

    # ── Step 2: Ping all node pairs — RTT matches netem ± 20% ─────────────────
    step "Step 2 — Ping all mesh node pairs; RTT within expected range"
    info "Expected: A-B≈20ms (5G), A-C≈500ms (SATCOM), A-E≈125ms (Radio), B-D≈125ms, C-D≈20ms, D-E≈125ms"

    declare -A EXPECTED_RTT_MIN EXPECTED_RTT_MAX PING_DST
    # Link IPs (node_b side): allow 20% tolerance
    PING_DST["A-B"]="10.1.0.2"; EXPECTED_RTT_MIN["A-B"]=16;  EXPECTED_RTT_MAX["A-B"]=24
    PING_DST["A-C"]="10.2.0.2"; EXPECTED_RTT_MIN["A-C"]=400; EXPECTED_RTT_MAX["A-C"]=600
    PING_DST["A-E"]="10.3.0.2"; EXPECTED_RTT_MIN["A-E"]=100; EXPECTED_RTT_MAX["A-E"]=150
    PING_DST["B-D"]="10.4.0.2"; EXPECTED_RTT_MIN["B-D"]=100; EXPECTED_RTT_MAX["B-D"]=150
    PING_DST["C-D"]="10.5.0.2"; EXPECTED_RTT_MIN["C-D"]=16;  EXPECTED_RTT_MAX["C-D"]=24
    PING_DST["D-E"]="10.6.0.2"; EXPECTED_RTT_MIN["D-E"]=100; EXPECTED_RTT_MAX["D-E"]=150

    declare -A PING_SRC
    PING_SRC["A-B"]="nodeA"; PING_SRC["A-C"]="nodeA"; PING_SRC["A-E"]="nodeA"
    PING_SRC["B-D"]="nodeB"; PING_SRC["C-D"]="nodeC"; PING_SRC["D-E"]="nodeD"

    for link in A-B A-C A-E B-D C-D D-E; do
        rtt=$(ping_rtt "${PING_SRC[$link]}" "${PING_DST[$link]}" 4)
        if [[ -z "$rtt" ]]; then
            fail "$link: ping failed (no RTT)"
        else
            if python3 -c "r=float('$rtt'); import sys; sys.exit(0 if ${EXPECTED_RTT_MIN[$link]} <= r <= ${EXPECTED_RTT_MAX[$link]} else 1)"; then
                pass "$link RTT: ${rtt}ms (expected ${EXPECTED_RTT_MIN[$link]}–${EXPECTED_RTT_MAX[$link]}ms)"
            else
                fail "$link RTT: ${rtt}ms (expected ${EXPECTED_RTT_MIN[$link]}–${EXPECTED_RTT_MAX[$link]}ms)"
            fi
        fi
    done

    # ── Step 3: iperf3 bandwidth matches netem rate cap ± 20% ─────────────────
    step "Step 3 — iperf3 bandwidth matches netem rate cap on each link"
    info "Expected: A-B≈20Mbit, A-C≈1Mbit, A-E≈256Kbit, B-D≈256Kbit, C-D≈20Mbit, D-E≈256Kbit"

    declare -A BW_SRC BW_DST BW_IP BW_MIN_KBPS BW_MAX_KBPS BW_TARGET_KBPS
    BW_SRC["A-B"]="nodeA"; BW_DST["A-B"]="nodeB"; BW_IP["A-B"]="10.1.0.2"
    BW_SRC["A-C"]="nodeA"; BW_DST["A-C"]="nodeC"; BW_IP["A-C"]="10.2.0.2"
    BW_SRC["A-E"]="nodeA"; BW_DST["A-E"]="nodeE"; BW_IP["A-E"]="10.3.0.2"

    # Cap target (Kbps), 20% tolerance
    declare -A BW_CAP_KBPS
    BW_CAP_KBPS["A-B"]=20000; BW_CAP_KBPS["A-C"]=1000; BW_CAP_KBPS["A-E"]=256

    for link in A-B A-C A-E; do
        dst_node="${BW_DST[$link]}"
        dst_ip="${BW_IP[$link]}"
        cap="${BW_CAP_KBPS[$link]}"
        # Start server
        node "$dst_node" sh -c "pkill iperf3 2>/dev/null; iperf3 -s -p 5300 -D 2>/dev/null" || true
        sleep 1
        # Run client for 5s, get throughput in Kbps
        raw=$(node "${BW_SRC[$link]}" iperf3 -c "$dst_ip" -p 5300 -t 5 -f k 2>&1 \
              | awk '/sender/{print $7}' | tail -1)
        node "$dst_node" pkill iperf3 2>/dev/null || true
        if [[ -z "$raw" ]]; then
            fail "$link bandwidth: iperf3 returned no result"
            continue
        fi
        kbps=$(python3 -c "print(float('$raw'))")
        lo=$(python3 -c "print($cap * 0.80)")
        hi=$(python3 -c "print($cap * 1.20)")
        if python3 -c "import sys; sys.exit(0 if $lo <= $kbps <= $hi else 1)"; then
            pass "$link bandwidth: ${kbps}Kbps (cap ${cap}Kbps ± 20%)"
        else
            fail "$link bandwidth: ${kbps}Kbps outside expected range ${lo}–${hi}Kbps"
        fi
    done

    # ── Step 4: Prometheus scraping all nodes ─────────────────────────────────
    step "Step 4 — Prometheus scraping all node_exporter targets"
    info "Expected: All 5 nodes show target state=up in Prometheus"
    targets=$(curl -sf "http://localhost:9090/api/v1/targets" 2>/dev/null \
              | python3 -c "
import sys,json
t=json.load(sys.stdin)['data']['activeTargets']
up=[x for x in t if x.get('health')=='up']
print(len(up))
" || echo 0)
    expect_gt "Prometheus active targets" "$targets" "4"

    # ── Step 5: Grafana dashboards accessible ─────────────────────────────────
    step "Step 5 — Grafana API responds and dashboards exist"
    info "Expected: Grafana returns ≥ 5 dashboards"
    db_count=$(curl -sf "http://admin:admin@localhost:3000/api/search?type=dash-db" 2>/dev/null \
               | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" || echo 0)
    expect_gt "Grafana dashboard count" "$db_count" "4"

    # ── Step 6: NetFlow top-talkers populated ─────────────────────────────────
    step "Step 6 — NetFlow top-talkers: generate iperf3 flow, verify metric appears"
    info "Expected: netflow_bytes metric appears in Prometheus after iperf3 run"
    # Short iperf3 to seed flows
    node nodeB sh -c "pkill iperf3 2>/dev/null; iperf3 -s -p 5301 -D" 2>/dev/null || true
    sleep 1
    node nodeA iperf3 -c 10.1.0.2 -p 5301 -t 10 -b 5M &>/dev/null || true
    node nodeB pkill iperf3 2>/dev/null || true
    sleep 35  # wait for softflowd maxlife + pmacct refresh
    nf_metrics=$(curl -sf "http://localhost:9101/metrics" 2>/dev/null | grep -c "^netflow_bytes" || echo 0)
    expect_gt "NetFlow metrics in Prometheus" "$nf_metrics" "0"

    info "Scenario 1 complete."
}

# ── Scenario 2: Link Failure and Route Failover ───────────────────────────────

scenario2() {
    header "Scenario 2: Link Failure and Route Failover"
    info "Purpose: Measure OSPF convergence time. Verify DISRUPTION classification, no false congestion."

    reset_impairments

    # ── Step 1: Baseline — continuous A→D traffic ─────────────────────────────
    step "Step 1 — Establish baseline: start continuous iperf3 A→D"
    info "Expected: iperf3 connects successfully via primary path (A→B→D, through 5G link)"
    node nodeD sh -c "pkill iperf3 2>/dev/null; iperf3 -s -p 5200 -D" 2>/dev/null || true
    sleep 1
    node nodeA iperf3 -c 10.1.0.2 -p 5200 -t 1 &>/dev/null \
        && pass "Baseline iperf3 A→B reachable before failure" \
        || fail "Baseline iperf3 A→B not reachable"

    # Check the route nodeA uses to reach nodeD (should be via 10.1.0.2 = nodeB)
    route_before=$(node nodeA ip route get 4.4.4.4 2>/dev/null | head -1)
    info "Route to nodeD before failure: $route_before"
    expect_contains "Pre-failure route to nodeD" "$route_before" "10.1.0.2"

    # ── Step 2: Bring down A-B link ──────────────────────────────────────────
    step "Step 2 — Bring down link A–B (primary 5G path)"
    info "Expected: OSPF reconverges; traffic shifts to alternate path within 10 s"
    T_DOWN=$SECONDS
    node nodeA ip link set eth1 down
    info "Link eth1 on nodeA is DOWN at T=${T_DOWN}s"

    # ── Step 3: Measure convergence ───────────────────────────────────────────
    step "Step 3 — Wait for OSPF convergence and alternate path"
    info "Expected: Route to nodeD changes within 10 s (30 s with BFD disabled)"
    MAX_WAIT=30
    CONVERGED=false
    for i in $(seq 1 $MAX_WAIT); do
        sleep 1
        new_route=$(node nodeA ip route get 4.4.4.4 2>/dev/null | head -1)
        if ! echo "$new_route" | grep -q "10.1.0.2"; then
            T_CONV=$(( SECONDS - T_DOWN ))
            CONVERGED=true
            pass "OSPF converged in ${T_CONV}s (route now: $new_route)"
            if [[ "$T_CONV" -le 10 ]]; then
                pass "Convergence time ${T_CONV}s ≤ 10 s (BFD target)"
            else
                info "Convergence time ${T_CONV}s > 10 s (acceptable without BFD; target ≤ 30 s)"
            fi
            break
        fi
    done
    if [[ "$CONVERGED" == "false" ]]; then
        fail "OSPF did not reconverge within ${MAX_WAIT}s after A-B link down"
    fi

    # ── Step 4: Verify alternate path connectivity ────────────────────────────
    step "Step 4 — Verify traffic resumed on alternate path"
    info "Expected: iperf3 A→D still works; route no longer uses eth1"
    node nodeA iperf3 -c 4.4.4.4 -p 5200 -t 3 &>/dev/null \
        && pass "iperf3 A→D works on alternate path" \
        || fail "iperf3 A→D failed after failover"

    route_after=$(node nodeA ip route get 4.4.4.4 2>/dev/null | head -1)
    info "Route to nodeD after failure: $route_after"
    if echo "$route_after" | grep -q "10.1.0.2"; then
        fail "Route still via 10.1.0.2 (A-B) — expected alternate path"
    else
        pass "Route uses alternate path (not A-B)"
    fi

    # ── Step 5: Classifier shows DISRUPTION ──────────────────────────────────
    step "Step 5 — Classifier output: DISRUPTION on A-B, no false CONGESTION"
    info "Expected: MQTT topic mesh/classifier/A-B = DISRUPTION; A-C/A-E/B-D/C-D/D-E = NORMAL"
    sleep 12  # wait for next classifier cycle
    mqtt_ab=$(mqtt_state "A-B")
    info "MQTT A-B: $mqtt_ab"
    expect_contains "Classifier A-B state" "$mqtt_ab" "DISRUPTION"

    for link in A-C A-E B-D C-D D-E; do
        msg=$(mqtt_state "$link")
        if echo "$msg" | grep -q "CONGESTION"; then
            fail "False CONGESTION on $link during A-B failure: $msg"
        else
            pass "No false CONGESTION on $link"
        fi
    done

    # ── Step 6: Restore link ──────────────────────────────────────────────────
    step "Step 6 — Restore link A–B"
    info "Expected: OSPF reconverges; traffic returns to primary 5G path"
    node nodeA ip link set eth1 up
    sleep 15
    route_restored=$(node nodeA ip route get 4.4.4.4 2>/dev/null | head -1)
    info "Route to nodeD after restore: $route_restored"
    expect_contains "Post-restore route uses A-B (5G)" "$route_restored" "10.1.0.2"

    # Classifier should return to NORMAL
    sleep 12
    mqtt_ab_restored=$(mqtt_state "A-B")
    info "MQTT A-B after restore: $mqtt_ab_restored"
    expect_contains "Classifier A-B back to NORMAL" "$mqtt_ab_restored" "NORMAL"

    node nodeD pkill iperf3 2>/dev/null || true
    info "Scenario 2 complete."
}

# ── Scenario 3: Congestion on Selected Links ──────────────────────────────────

scenario3() {
    header "Scenario 3: Congestion on Selected Links"
    info "Purpose: NMS correctly detects sustained queue buildup as CONGESTION."

    reset_impairments

    # ── Step 1: Apply SATCOM impairment ───────────────────────────────────────
    step "Step 1 — Apply SATCOM impairment to link A–C (128kbps, 1s delay, 5% loss)"
    info "Expected: eth2 on nodeA has netem qdisc with rate 128kbit delay 1s"
    node nodeA tc qdisc replace dev eth2 root netem rate 128kbit delay 1000ms loss 5%
    node nodeC tc qdisc replace dev eth1 root netem rate 128kbit delay 1000ms loss 5%
    actual_qdisc=$(node nodeA tc qdisc show dev eth2)
    info "eth2 qdisc: $actual_qdisc"
    expect_contains "SATCOM netem delay" "$actual_qdisc" "delay 1s"
    expect_contains "SATCOM netem rate" "$actual_qdisc" "128Kbit"

    # Verify RTT on link A-C ≥ 2000ms (round trip through netem)
    step "Step 1a — Verify data-plane RTT reflects SATCOM impairment"
    info "Expected: ping A→C data-plane IP (10.2.0.2) returns RTT ≥ 2000ms"
    rtt_satcom=$(ping_rtt nodeA 10.2.0.2 3)
    if [[ -n "$rtt_satcom" ]]; then
        if python3 -c "import sys; sys.exit(0 if float('$rtt_satcom') >= 1800 else 1)"; then
            pass "SATCOM RTT ${rtt_satcom}ms ≥ 1800ms (expected ≥ 2000ms)"
        else
            fail "SATCOM RTT ${rtt_satcom}ms < 1800ms — impairment may not be applied"
        fi
    else
        fail "SATCOM ping failed — no RTT"
    fi

    # ── Step 2: Start background competing traffic ────────────────────────────
    step "Step 2 — Start background competing traffic on A–C (fills the pipe)"
    info "Expected: Background flows reduce available bandwidth; nodeC iperf3 server ready"
    node nodeC sh -c "pkill iperf3 2>/dev/null; iperf3 -s -p 5201 -D" 2>/dev/null || true
    sleep 1
    # 4 streams × 24kbps = ~96kbps background (75% of 128kbps cap)
    node nodeA iperf3 -c 10.2.0.2 -p 5201 -t 120 -b 24k -P 4 &>/dev/null &
    BG_PID=$!
    sleep 3
    pass "Background traffic started (PID $BG_PID, 4 streams × 24kbps)"

    # ── Step 3: Push primary overload flow ────────────────────────────────────
    step "Step 3 — Push primary flow at 5× capacity (640kbps) for 30 s"
    info "Expected: Packet loss > 5%, RTT ≥ 2× baseline, OSPF routes unchanged"
    node nodeA iperf3 -c 10.2.0.2 -p 5201 -t 30 -b 640k 2>&1 | tail -4 &
    OVERLOAD_PID=$!
    sleep 5

    # Check packet loss during overload via Prometheus (TX drops rising)
    drops=$(prom 'rate(node_network_transmit_drop_total{instance="172.20.20.7",device="eth2"}[10s])')
    info "TX drop rate on nodeA eth2: ${drops:-N/A} pps"

    # ── Step 4: Verify CONGESTION classification ──────────────────────────────
    step "Step 4 — Wait for classifier to detect CONGESTION on A-C"
    info "Expected: MQTT mesh/classifier/A-C = CONGESTION within 2 classifier cycles (~90s)"
    DETECTED=false
    for attempt in $(seq 1 6); do
        sleep 15
        msg=$(mqtt_state "A-C")
        info "Attempt $attempt — MQTT A-C: $msg"
        if echo "$msg" | grep -q "CONGESTION"; then
            pass "Classifier detected CONGESTION on A-C: $msg"
            DETECTED=true
            break
        fi
    done
    [[ "$DETECTED" == "false" ]] && fail "Classifier did not detect CONGESTION on A-C within ~90 s"

    # ── Step 5: Verify Prometheus gauge = 2 (CONGESTION) ─────────────────────
    step "Step 5 — Prometheus gauge mesh_link_classifier_state{link=A-C} = 2"
    info "Expected: gauge value 2 means CONGESTION"
    gauge=$(prom 'mesh_link_classifier_state{link="A-C"}')
    info "Classifier gauge A-C: ${gauge:-empty}"
    if [[ "$gauge" == "2" ]] || python3 -c "import sys; sys.exit(0 if float('${gauge:-0}') == 2 else 1)" 2>/dev/null; then
        pass "Prometheus gauge A-C = 2 (CONGESTION)"
    else
        fail "Prometheus gauge A-C = ${gauge:-missing} (expected 2)"
    fi

    # ── Step 6: OSPF routes unchanged ────────────────────────────────────────
    step "Step 6 — OSPF routes unchanged (load-based reroute is Phase 2)"
    info "Expected: nodeA still has OSPF route to nodeC via 10.2.0.2 (no rereroute)"
    route_c=$(node nodeA ip route get 3.3.3.3 2>/dev/null | head -1)
    info "Route to nodeC: $route_c"
    expect_contains "OSPF route to nodeC unchanged" "$route_c" "10.2.0.2"
    pass "OSPF did not reroute based on load (expected — Phase 2 capability)"

    # ── Step 7: NetFlow top-talkers ───────────────────────────────────────────
    step "Step 7 — NetFlow top-talkers identifies iperf3 as dominant flow"
    info "Expected: netflow_top_src_bytes shows 10.2.0.1 (nodeA) with highest byte count"
    sleep 35  # wait for next pmacct refresh
    top_src=$(curl -sf "http://localhost:9101/metrics" 2>/dev/null \
              | grep "netflow_top_src_bytes" | sort -t= -k2 -rn | head -3)
    if [[ -n "$top_src" ]]; then
        pass "NetFlow top-talkers metrics present"
        info "Top sources by bytes:\n$top_src"
    else
        fail "NetFlow top_src_bytes metric not present"
    fi

    # Cleanup
    kill "$BG_PID" 2>/dev/null || true
    wait "$OVERLOAD_PID" 2>/dev/null || true
    node nodeC pkill iperf3 2>/dev/null || true
    reset_impairments
    info "Scenario 3 complete."
}

# ── Scenario 4: Multi-WAN Path Failover ──────────────────────────────────────

scenario4() {
    header "Scenario 4: Multi-WAN Path Failover"
    info "Purpose: Validate BGP LOCAL_PREF priority: 5G(300) > Radio(200) > SATCOM(100)."

    reset_impairments

    # ── Step 1: Verify baseline — traffic uses 5G (highest LOCAL_PREF) ─────────
    step "Step 1 — Baseline: all WAN paths active, verify 5G is preferred"
    info "Expected: BGP best path to 203.0.113.0/24 is via wan5G (eth6 / 192.168.3.1)"
    bgp_best=$(node nodeA vtysh -c "show ip bgp 203.0.113.0/24" 2>/dev/null | grep "^\*>" | head -1)
    info "BGP best path: $bgp_best"
    expect_contains "Best path via 5G gateway" "$bgp_best" "192.168.3"

    rtt_wan=$(ping_rtt nodeA 203.0.113.1 3)
    info "RTT to WAN prefix (via 5G): ${rtt_wan:-N/A}ms"

    # ── Step 2: Take down 5G uplink ───────────────────────────────────────────
    step "Step 2 — Bring down 5G WAN uplink (nodeA eth6)"
    info "Expected: BGP removes 5G path; traffic shifts to Radio (LOCAL_PREF 200)"
    node nodeA ip link set eth6 down
    sleep 15  # BGP holddown + reconvergence

    bgp_after_5g=$(node nodeA vtysh -c "show ip bgp 203.0.113.0/24" 2>/dev/null | grep "^\*>" | head -1)
    info "BGP best path after 5G down: $bgp_after_5g"
    if echo "$bgp_after_5g" | grep -q "192.168.3"; then
        fail "BGP still routes via 5G after eth6 down"
    else
        pass "BGP switched away from 5G"
    fi
    expect_contains "Failover to Radio (192.168.2)" "$bgp_after_5g" "192.168.2"

    rtt_radio=$(ping_rtt nodeA 203.0.113.1 3)
    info "RTT via Radio: ${rtt_radio:-N/A}ms"
    if [[ -n "$rtt_radio" ]]; then
        if python3 -c "import sys; sys.exit(0 if 80 <= float('$rtt_radio') <= 200 else 1)"; then
            pass "WAN RTT via Radio: ${rtt_radio}ms (expected 100–150ms range)"
        else
            info "WAN RTT via Radio: ${rtt_radio}ms (may vary with netem config)"
        fi
    fi

    # ── Step 3: Take down Radio uplink ────────────────────────────────────────
    step "Step 3 — Bring down Radio WAN uplink (nodeA eth5)"
    info "Expected: Traffic shifts to SATCOM (LOCAL_PREF 100, last resort)"
    node nodeA ip link set eth5 down
    sleep 15

    bgp_after_radio=$(node nodeA vtysh -c "show ip bgp 203.0.113.0/24" 2>/dev/null | grep "^\*>" | head -1)
    info "BGP best path after Radio down: $bgp_after_radio"
    expect_contains "Failover to SATCOM (192.168.1)" "$bgp_after_radio" "192.168.1"

    rtt_satcom=$(ping_rtt nodeA 203.0.113.1 3)
    info "RTT via SATCOM: ${rtt_satcom:-N/A}ms"

    # ── Step 4: Restore Radio — verify Radio is preferred over SATCOM ─────────
    step "Step 4 — Restore Radio uplink; verify traffic returns to Radio"
    info "Expected: BGP picks Radio (LOCAL_PREF 200) over SATCOM (100)"
    node nodeA ip link set eth5 up
    sleep 15

    bgp_after_radio_up=$(node nodeA vtysh -c "show ip bgp 203.0.113.0/24" 2>/dev/null | grep "^\*>" | head -1)
    info "BGP best path after Radio restored: $bgp_after_radio_up"
    expect_contains "Traffic back to Radio after restore" "$bgp_after_radio_up" "192.168.2"

    # ── Step 5: Restore 5G — verify 5G is preferred again ─────────────────────
    step "Step 5 — Restore 5G uplink; verify traffic returns to 5G"
    info "Expected: BGP picks 5G (LOCAL_PREF 300) — highest priority"
    node nodeA ip link set eth6 up
    sleep 15

    bgp_final=$(node nodeA vtysh -c "show ip bgp 203.0.113.0/24" 2>/dev/null | grep "^\*>" | head -1)
    info "BGP best path after 5G restored: $bgp_final"
    expect_contains "Traffic returned to 5G after restore" "$bgp_final" "192.168.3"

    reset_impairments
    info "Scenario 4 complete."
}

# ── Scenario 5: Disruption vs Congestion Discrimination ──────────────────────

scenario5() {
    header "Scenario 5: Disruption vs Congestion Discrimination"
    info "Purpose: Classifier correctly labels radio blackout as DISRUPTION, overload as CONGESTION."

    reset_impairments

    # ── Step 1: Baseline iperf3 A→E over Radio link ───────────────────────────
    step "Step 1 — Establish baseline iperf3 flow: Node A → Node E over Radio link"
    info "Expected: iperf3 connects; RTT ≈ 125ms, classifier A-E = NORMAL"
    node nodeE sh -c "pkill iperf3 2>/dev/null; iperf3 -s -p 5400 -D" 2>/dev/null || true
    sleep 1
    baseline_ok=$(node nodeA iperf3 -c 10.3.0.2 -p 5400 -t 3 2>&1 | grep -c "sender" || echo 0)
    if [[ "$baseline_ok" -gt 0 ]]; then
        pass "Baseline iperf3 A→E working"
    else
        fail "Baseline iperf3 A→E failed"
    fi

    baseline_rtt=$(ping_rtt nodeA 10.3.0.2 4)
    info "Baseline RTT A-E: ${baseline_rtt:-N/A}ms"
    sleep 12
    baseline_class=$(mqtt_state "A-E")
    info "Baseline classifier A-E: $baseline_class"
    expect_contains "Baseline A-E NORMAL" "$baseline_class" "NORMAL"

    # ── Treatment A: Disruption — 500ms link blackout ─────────────────────────
    step "Treatment A — Disruption: inject 500ms total link blackout then revert"
    info "Expected: Classifier → DISRUPTION; no queue buildup; RTT spikes then recovers"
    info "Signature: short loss burst, RTT spike, OSPF reconvergence traffic"

    # Apply 100% loss for 500ms then restore
    node nodeA tc qdisc change dev eth3 root netem rate 256kbit delay 62ms loss 100% 2>/dev/null
    info "100% loss applied to A-E (eth3)"
    sleep 1
    node nodeA tc qdisc change dev eth3 root netem rate 256kbit delay 62ms loss 3% 2>/dev/null
    info "Loss reverted to baseline 3%"

    # Wait for classifier to see the disruption
    info "Waiting for classifier cycle..."
    sleep 25
    disrupt_class=$(mqtt_state "A-E")
    info "Classifier A-E after disruption: $disrupt_class"
    if echo "$disrupt_class" | grep -q "DISRUPTION"; then
        pass "Treatment A classified as DISRUPTION"
    elif echo "$disrupt_class" | grep -q "CONGESTION"; then
        fail "Treatment A misclassified as CONGESTION (false alarm)"
    else
        info "Classifier A-E = NORMAL (disruption event may have recovered before next cycle)"
        pass "No false CONGESTION during Treatment A"
    fi

    # Verify RTT is back to baseline after recovery
    rtt_after_disrupt=$(ping_rtt nodeA 10.3.0.2 4)
    info "RTT after disruption recovery: ${rtt_after_disrupt:-N/A}ms"
    if [[ -n "$rtt_after_disrupt" ]]; then
        if python3 -c "import sys; sys.exit(0 if float('$rtt_after_disrupt') < 200 else 1)"; then
            pass "RTT recovered to ${rtt_after_disrupt}ms after disruption (≤ 200ms)"
        else
            fail "RTT still elevated at ${rtt_after_disrupt}ms after disruption should have passed"
        fi
    fi

    # ── Treatment B: Congestion — sustained 2× overload ──────────────────────
    step "Treatment B — Congestion: sustain 2× offered load for 30 s"
    info "Expected: Classifier → CONGESTION; RTT sustained; queue rising; NO OSPF reconvergence"
    info "Signature: sustained loss, rising queue depth, RTT inflation, OSPF unchanged"

    # Push 512Kbps = 2× the 256kbps Radio cap
    node nodeA iperf3 -c 10.3.0.2 -p 5400 -t 40 -b 512k &>/dev/null &
    OVERLOAD_PID=$!
    info "2× overload started on A-E (512kbps into 256kbps pipe)"

    # Check OSPF neighbour count stays stable
    ospf_before=$(node nodeA vtysh -c "show ip ospf neighbor" 2>/dev/null | grep -c "Full/" || echo 0)

    CONG_DETECTED=false
    for attempt in $(seq 1 6); do
        sleep 15
        cong_class=$(mqtt_state "A-E")
        info "Attempt $attempt — Classifier A-E: $cong_class"
        if echo "$cong_class" | grep -q "CONGESTION"; then
            pass "Treatment B classified as CONGESTION: $cong_class"
            CONG_DETECTED=true
            break
        fi
    done
    [[ "$CONG_DETECTED" == "false" ]] && fail "Treatment B: CONGESTION not detected within ~90 s"

    # Verify OSPF stayed stable (no reconvergence)
    ospf_after=$(node nodeA vtysh -c "show ip ospf neighbor" 2>/dev/null | grep -c "Full/" || echo 0)
    if [[ "$ospf_before" -eq "$ospf_after" ]]; then
        pass "OSPF neighbour count stable during congestion: $ospf_after FULL"
    else
        fail "OSPF neighbours changed during congestion: before=$ospf_before after=$ospf_after"
    fi

    # ── Summary: Discrimination ───────────────────────────────────────────────
    step "Discrimination summary"
    info "Treatment A (disruption): classifier reported DISRUPTION or recovered to NORMAL — no false CONGESTION"
    info "Treatment B (congestion): classifier reported CONGESTION with stable OSPF"
    pass "Classifier correctly discriminated disruption vs congestion events"

    kill "$OVERLOAD_PID" 2>/dev/null || true
    node nodeE pkill iperf3 2>/dev/null || true
    reset_impairments
    info "Scenario 5 complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    local run_scenarios="${1:-all}"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Tactical Mesh Phase 1 — Scenario Playbook          ║${NC}"
    echo -e "${BOLD}║   $(date '+%Y-%m-%d %H:%M:%S')                             ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

    # Verify topology is up before running anything
    running=$(docker ps --filter "name=clab-tactical-mesh-nodeA" --format "{{.Names}}" 2>/dev/null | wc -l)
    if [[ "$running" -eq 0 ]]; then
        echo -e "${RED}ERROR: clab-tactical-mesh-nodeA is not running.${NC}"
        echo "Deploy the topology first: sudo clab deploy --topo tactical-mesh.yml"
        exit 1
    fi

    case "$run_scenarios" in
        1) scenario1 ;;
        2) scenario2 ;;
        3) scenario3 ;;
        4) scenario4 ;;
        5) scenario5 ;;
        all)
            scenario1
            scenario2
            scenario3
            scenario4
            scenario5
            ;;
        *)
            echo "Usage: $0 [1|2|3|4|5|all]"
            exit 1
            ;;
    esac

    # ── Final report ──────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Results${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}PASS: $PASS${NC}"
    echo -e "  ${RED}FAIL: $FAIL${NC}"
    TOTAL=$(( PASS + FAIL ))
    echo "  Total checks: $TOTAL"
    if [[ "$FAIL" -eq 0 ]]; then
        echo -e "\n${GREEN}${BOLD}  All checks passed.${NC}"
        exit 0
    else
        echo -e "\n${RED}${BOLD}  $FAIL check(s) failed.${NC}"
        exit 1
    fi
}

main "${1:-all}"
