"""
NMS Event Classifier — Phase 1
Queries Prometheus every 10 s, applies rule table per link, publishes:
  - MQTT topic  mesh/classifier/<link_id>  payload: NORMAL|DISRUPTION|CONGESTION
  - Prometheus gauge  mesh_link_classifier_state{link, node_a, node_b}  0=NORMAL 1=DISRUPTION 2=CONGESTION
"""

import time
import subprocess
import os
import requests
import paho.mqtt.client as mqtt
from prometheus_client import start_http_server, Gauge

# ── configuration ────────────────────────────────────────────────────────────
PROMETHEUS_URL  = os.getenv("PROMETHEUS_URL",  "http://localhost:9090")
MQTT_HOST       = os.getenv("MQTT_HOST",       "localhost")
MQTT_PORT       = int(os.getenv("MQTT_PORT",   "1883"))
METRICS_PORT    = int(os.getenv("METRICS_PORT","9102"))
INTERVAL        = int(os.getenv("INTERVAL",    "10"))   # seconds

# Links: (link_id, node_a_instance, node_b_instance, iface_on_a, iface_on_b)
# Instances match what Prometheus labels as "instance" from node_exporter
LINKS = [
    ("A-B", "172.20.20.7", "172.20.20.6", "eth1", "eth1"),  # 5G
    ("A-C", "172.20.20.7", "172.20.20.3", "eth2", "eth1"),  # SATCOM
    ("A-E", "172.20.20.7", "172.20.20.2", "eth3", "eth1"),  # Radio
    ("B-D", "172.20.20.6", "172.20.20.5", "eth2", "eth1"),  # Radio
    ("C-D", "172.20.20.3", "172.20.20.5", "eth2", "eth2"),  # 5G
    ("D-E", "172.20.20.5", "172.20.20.2", "eth3", "eth2"),  # Radio
]

# Container names for RTT probing
NODE_CONTAINERS = {
    "172.20.20.7": "clab-tactical-mesh-nodeA",
    "172.20.20.6": "clab-tactical-mesh-nodeB",
    "172.20.20.3": "clab-tactical-mesh-nodeC",
    "172.20.20.5": "clab-tactical-mesh-nodeD",
    "172.20.20.2": "clab-tactical-mesh-nodeE",
}

# Data-plane IPs to ping — these go through the actual netem-impaired interfaces.
# Using node_b's IP on the shared link subnet so impairments are observed.
# Format: (container_a_to_exec_ping_from, peer_ip_on_data_plane)
LINK_PEER_IPS = {
    "A-B": ("clab-tactical-mesh-nodeA", "10.1.0.2"),   # nodeA→nodeB via eth1
    "A-C": ("clab-tactical-mesh-nodeA", "10.2.0.2"),   # nodeA→nodeC via eth2 (SATCOM)
    "A-E": ("clab-tactical-mesh-nodeA", "10.3.0.2"),   # nodeA→nodeE via eth3
    "B-D": ("clab-tactical-mesh-nodeB", "10.4.0.2"),   # nodeB→nodeD via eth2
    "C-D": ("clab-tactical-mesh-nodeC", "10.5.0.2"),   # nodeC→nodeD via eth2
    "D-E": ("clab-tactical-mesh-nodeD", "10.6.0.2"),   # nodeD→nodeE via eth3
}

# Baseline RTTs in ms (from README netem config)
RTT_BASELINE = {
    "A-B": 20,    # 5G
    "A-C": 500,   # SATCOM
    "A-E": 125,   # Radio
    "B-D": 125,   # Radio
    "C-D": 20,    # 5G
    "D-E": 125,   # Radio
}

# ── Prometheus gauge ──────────────────────────────────────────────────────────
classifier_state = Gauge(
    "mesh_link_classifier_state",
    "Link event classification: 0=NORMAL 1=DISRUPTION 2=CONGESTION",
    ["link", "node_a", "node_b"]
)

# ── helpers ───────────────────────────────────────────────────────────────────
def prom_query(expr):
    """Return list of (labels, float_value) for an instant query."""
    try:
        r = requests.get(f"{PROMETHEUS_URL}/api/v1/query",
                         params={"query": expr}, timeout=5)
        results = r.json()["data"]["result"]
        return [(m["metric"], float(m["value"][1])) for m in results]
    except Exception:
        return []

def prom_query_one(expr):
    """Return single float or None."""
    res = prom_query(expr)
    return res[0][1] if res else None

def probe_rtt_ms(container, peer_ip):
    """
    Exec ping inside the mesh container so it uses the data-plane interface
    and traverses netem impairments. Returns avg RTT in ms or None.
    """
    try:
        cmd = ["docker", "exec", container, "ping", "-c", "4", "-W", "3", peer_ip]
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=20).decode()
        for line in out.splitlines():
            if "avg" in line and "=" in line:
                stats = line.split("= ")[1].split("/")
                return float(stats[1])
    except Exception:
        return None

def tx_drop_rate(instance, iface, window="10s"):
    v = prom_query_one(
        f'rate(node_network_transmit_drop_total{{instance="{instance}",device="{iface}"}}[{window}])'
    )
    return v or 0.0

def rx_error_rate(instance, iface, window="10s"):
    v = prom_query_one(
        f'rate(node_network_receive_errs_total{{instance="{instance}",device="{iface}"}}[{window}])'
        f' + rate(node_network_receive_drop_total{{instance="{instance}",device="{iface}"}}[{window}])'
    )
    return v or 0.0

def iface_up(instance, iface):
    v = prom_query_one(
        f'node_network_up{{instance="{instance}",device="{iface}"}}'
    )
    return bool(v) if v is not None else True   # assume up if no data

def queue_depth_trend(instance, iface, window="30s"):
    """Positive = rising queue, negative = draining, 0 = stable."""
    now = prom_query_one(
        f'node_network_transmit_queue_length{{instance="{instance}",device="{iface}"}}'
    )
    if now is None:
        return 0.0
    # rate of change over window
    delta = prom_query_one(
        f'deriv(node_network_transmit_queue_length{{instance="{instance}",device="{iface}"}}[{window}])'
    )
    return delta or 0.0

# ── classifier rule table ─────────────────────────────────────────────────────
def classify_link(link_id, node_a, node_b, iface_a, iface_b):
    """
    Returns (state_str, reason_str) where state_str is NORMAL|DISRUPTION|CONGESTION.

    Rule table (from README section 3.5):
      DISRUPTION signals:
        - Interface state change (went down/up in window)
        - Short loss burst then zero (rx_error_rate spike on both sides)
        - RTT spike then recovery (RTT >> baseline but no queue buildup)

      CONGESTION signals:
        - Sustained tx drops (queue overflow)
        - Rising queue depth trend
        - RTT sustained above 2x baseline
        - No interface state changes in window
    """
    reasons = []

    # 1. Interface up/down
    a_up = iface_up(node_a, iface_a)
    b_up = iface_up(node_b, iface_b)
    if not a_up or not b_up:
        return "DISRUPTION", f"interface down: a_up={a_up} b_up={b_up}"

    # 2. TX drop rate (congestion indicator)
    drops_a = tx_drop_rate(node_a, iface_a)
    drops_b = tx_drop_rate(node_b, iface_b)
    sustained_drops = drops_a > 1.0 or drops_b > 1.0

    # 3. RX errors (disruption indicator — radio loss burst)
    errs_a = rx_error_rate(node_a, iface_a)
    errs_b = rx_error_rate(node_b, iface_b)
    rx_error_burst = errs_a > 5.0 or errs_b > 5.0

    # 4. Queue depth trend
    q_trend_a = queue_depth_trend(node_a, iface_a)
    queue_rising = q_trend_a > 0.5

    # 5. RTT active probe — ping data-plane IP from inside the mesh container
    container_a, peer_ip = LINK_PEER_IPS.get(link_id, (None, None))
    rtt_ms = probe_rtt_ms(container_a, peer_ip) if peer_ip else None
    baseline = RTT_BASELINE.get(link_id, 100)
    rtt_inflated  = rtt_ms is not None and rtt_ms > baseline * 1.5
    rtt_sustained = rtt_ms is not None and rtt_ms > baseline * 2.0

    # ── decision logic ────────────────────────────────────────────────────────
    # DISRUPTION: RX error burst without queue buildup → radio fade / link flap
    if rx_error_burst and not queue_rising and not sustained_drops:
        return "DISRUPTION", f"rx_errors={errs_a:.2f}/{errs_b:.2f} no queue buildup"

    # DISRUPTION: RTT spike without sustained drops → transient reorder event
    if rtt_inflated and not rtt_sustained and not sustained_drops and not queue_rising:
        return "DISRUPTION", f"rtt={rtt_ms:.0f}ms (baseline {baseline}ms) transient"

    # CONGESTION: sustained drops + rising queue
    if sustained_drops and queue_rising:
        return "CONGESTION", f"drops={drops_a:.2f}/{drops_b:.2f} queue_trend={q_trend_a:.2f}"

    # CONGESTION: RTT >4x baseline (severe queueing) — rate limiter causing deep bufferbloat
    rtt_severe = rtt_ms is not None and rtt_ms > baseline * 4.0
    if rtt_severe:
        return "CONGESTION", f"rtt={rtt_ms:.0f}ms >> 4x baseline {baseline}ms (bufferbloat)"

    if rtt_sustained and queue_rising:
        return "CONGESTION", f"rtt={rtt_ms:.0f}ms sustained queue_trend={q_trend_a:.2f}"

    if sustained_drops:
        return "CONGESTION", f"drops={drops_a:.2f}/{drops_b:.2f} (no queue data)"

    return "NORMAL", f"rtt={rtt_ms}ms drops={drops_a:.2f} errs={errs_a:.2f}"

# ── main loop ─────────────────────────────────────────────────────────────────
STATE_MAP = {"NORMAL": 0, "DISRUPTION": 1, "CONGESTION": 2}

def main():
    # Start Prometheus metrics endpoint
    start_http_server(METRICS_PORT)
    print(f"Classifier metrics on :{METRICS_PORT}")

    # Connect MQTT
    mq = mqtt.Client(client_id="nms-classifier")
    mq.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    mq.loop_start()
    print(f"MQTT connected to {MQTT_HOST}:{MQTT_PORT}")

    print(f"Classifying {len(LINKS)} links every {INTERVAL}s")

    while True:
        for link_id, node_a, node_b, iface_a, iface_b in LINKS:
            state, reason = classify_link(link_id, node_a, node_b, iface_a, iface_b)

            # Publish to MQTT
            topic = f"mesh/classifier/{link_id}"
            payload = f'{{"link":"{link_id}","state":"{state}","reason":"{reason}"}}'
            mq.publish(topic, payload, qos=1, retain=True)

            # Update Prometheus gauge
            classifier_state.labels(
                link=link_id, node_a=node_a, node_b=node_b
            ).set(STATE_MAP[state])

            print(f"[{link_id}] {state:12s} — {reason}")

        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
