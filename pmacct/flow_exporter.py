"""
NetFlow exporter bridge: reads pmacct JSON output, serves Prometheus metrics.
Exposes:
  netflow_bytes_total{src,dst,src_port,dst_port,proto}
  netflow_packets_total{src,dst,src_port,dst_port,proto}
"""
import json, time, os
from prometheus_client import start_http_server, Gauge, Counter

FLOWS_FILE   = os.getenv("FLOWS_FILE",   "/tmp/flows.json")
METRICS_PORT = int(os.getenv("METRICS_PORT", "9101"))
INTERVAL     = int(os.getenv("INTERVAL", "30"))

flow_bytes   = Gauge("netflow_bytes",   "Bytes per flow (30s window)",
                     ["src","dst","proto","src_port","dst_port"])
flow_packets = Gauge("netflow_packets", "Packets per flow (30s window)",
                     ["src","dst","proto","src_port","dst_port"])
top_src_bytes = Gauge("netflow_top_src_bytes", "Total bytes by source",
                      ["src"])

def parse_flows():
    if not os.path.exists(FLOWS_FILE):
        return []
    try:
        with open(FLOWS_FILE) as f:
            return [json.loads(line) for line in f if line.strip()]
    except Exception:
        return []

def update_metrics():
    flows = parse_flows()
    src_totals = {}
    for flow in flows:
        labels = {
            "src":      flow.get("ip_src", ""),
            "dst":      flow.get("ip_dst", ""),
            "proto":    str(flow.get("ip_proto", "")),
            "src_port": str(flow.get("port_src", "")),
            "dst_port": str(flow.get("port_dst", "")),
        }
        bytes_val   = float(flow.get("bytes",   0))
        packets_val = float(flow.get("packets", 0))
        flow_bytes.labels(**labels).set(bytes_val)
        flow_packets.labels(**labels).set(packets_val)
        src = labels["src"]
        src_totals[src] = src_totals.get(src, 0) + bytes_val

    for src, total in src_totals.items():
        top_src_bytes.labels(src=src).set(total)

def main():
    start_http_server(METRICS_PORT)
    print(f"Flow exporter metrics on :{METRICS_PORT}")
    while True:
        update_metrics()
        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
