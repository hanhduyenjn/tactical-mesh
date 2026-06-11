FROM alpine:3.18
RUN apk add --no-cache net-snmp
COPY snmpd.conf /etc/snmp/snmpd.conf
# -f foreground, -Lo log to stdout, listen UDP 161 in the shared node netns
ENTRYPOINT ["snmpd", "-f", "-Lo", "-c", "/etc/snmp/snmpd.conf", "udp:161"]
