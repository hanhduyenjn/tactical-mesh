#!/usr/bin/env bash
# Install monitoring stack on WSL/Ubuntu host.
# Run with: sudo bash install-monitoring.sh
# Must be run with sudo (uses apt, systemctl).

set -e

echo "=== Installing monitoring stack ==="

# Grafana
echo "--- Grafana ---"
apt-get install -y apt-transport-https software-properties-common wget gnupg
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y grafana

# Mosquitto (MQTT broker)
echo "--- Mosquitto ---"
apt-get install -y mosquitto mosquitto-clients

# pmacct (NetFlow collector)
echo "--- pmacct ---"
apt-get install -y pmacct

# nfdump (offline analysis)
echo "--- nfdump ---"
apt-get install -y nfdump

# Prometheus (binary install)
echo "--- Prometheus ---"
PROM_VER="2.48.0"
if [ ! -f /usr/local/bin/prometheus ]; then
    wget -q https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-amd64.tar.gz \
        -O /tmp/prometheus.tar.gz
    tar -xzf /tmp/prometheus.tar.gz -C /tmp/
    mv /tmp/prometheus-${PROM_VER}.linux-amd64/prometheus /usr/local/bin/
    mv /tmp/prometheus-${PROM_VER}.linux-amd64/promtool /usr/local/bin/
    mkdir -p /etc/prometheus /var/lib/prometheus
    cp /tmp/prometheus-${PROM_VER}.linux-amd64/{consoles,console_libraries} /etc/prometheus/ -r
    rm -f /tmp/prometheus.tar.gz
fi

# Copy prometheus config from project (script lives in the project directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/prometheus.yml" /etc/prometheus/prometheus.yml

# Create prometheus systemd service
cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.listen-address=:9090
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# snmp_exporter
echo "--- snmp_exporter ---"
SNMP_VER="0.25.0"
if [ ! -f /usr/local/bin/snmp_exporter ]; then
    wget -q https://github.com/prometheus/snmp_exporter/releases/download/v${SNMP_VER}/snmp_exporter-${SNMP_VER}.linux-amd64.tar.gz \
        -O /tmp/snmp_exporter.tar.gz
    tar -xzf /tmp/snmp_exporter.tar.gz -C /tmp/
    mv /tmp/snmp_exporter-${SNMP_VER}.linux-amd64/snmp_exporter /usr/local/bin/
    rm -f /tmp/snmp_exporter.tar.gz
fi

cat > /etc/systemd/system/snmp_exporter.service << 'EOF'
[Unit]
Description=SNMP Exporter
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/snmp_exporter --web.listen-address=:9116
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Enable and start all services
echo "--- Starting services ---"
systemctl daemon-reload
systemctl enable --now grafana-server mosquitto prometheus snmp_exporter

echo "=== Monitoring stack installed and started ==="
echo "  Grafana:       http://localhost:3000  (admin/admin)"
echo "  Prometheus:    http://localhost:9090"
echo "  SNMP exporter: http://localhost:9116"
echo "  MQTT broker:   localhost:1883"
