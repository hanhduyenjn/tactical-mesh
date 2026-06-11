"""
NetFlow exporter bridge: reads pmacct JSON output, serves Prometheus metrics.
Exposes:
  netflow_bytes{src,dst,src_port,dst_port,proto,exporter}
  netflow_packets{src,dst,src_port,dst_port,proto,exporter}

The exporter label carries peer_ip_src (the management IP of the softflowd
sidecar that reported the flow). Both ends of a link report the same flow,
so dedup in PromQL with `max without(exporter) (netflow_bytes)` — this
collapses the duplicate observations regardless of which management IP each
node got (containerlab assigns those by start order, not node name).
Top-talker ranking is derived from netflow_bytes at query time, e.g.
  topk(10, sum by(src) (max without(exporter) (netflow_bytes)))
"""
import json, time, os
from prometheus_client import start_http_server, Gauge

FLOWS_FILE   = os.getenv("FLOWS_FILE",   "/tmp/flows.json")
METRICS_PORT = int(os.getenv("METRICS_PORT", "9101"))
INTERVAL     = int(os.getenv("INTERVAL", "30"))

flow_bytes   = Gauge("netflow_bytes",   "Bytes per flow (30s window)",
                     ["src", "dst", "proto", "src_port", "dst_port", "exporter"])
flow_packets = Gauge("netflow_packets", "Packets per flow (30s window)",
                     ["src", "dst", "proto", "src_port", "dst_port", "exporter"])

def parse_flows():
    if not os.path.exists(FLOWS_FILE):
        return []
    try:
        with open(FLOWS_FILE) as f:
            return [json.loads(line) for line in f if line.strip()]
    except Exception:
        return []

def update_metrics():
    # nfacctd writes a fresh snapshot each cycle (not an append). Clear the
    # gauges so flows absent from the current window don't retain stale values.
    flow_bytes.clear()
    flow_packets.clear()
    for flow in parse_flows():
        labels = {
            "src":      flow.get("ip_src", ""),
            "dst":      flow.get("ip_dst", ""),
            "proto":    str(flow.get("ip_proto", "")),
            "src_port": str(flow.get("port_src", "")),
            "dst_port": str(flow.get("port_dst", "")),
            "exporter": flow.get("peer_ip_src", ""),
        }
        flow_bytes.labels(**labels).set(float(flow.get("bytes", 0)))
        flow_packets.labels(**labels).set(float(flow.get("packets", 0)))

def main():
    start_http_server(METRICS_PORT)
    print(f"Flow exporter metrics on :{METRICS_PORT}")
    while True:
        update_metrics()
        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
