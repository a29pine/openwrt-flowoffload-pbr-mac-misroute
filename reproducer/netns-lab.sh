#!/usr/bin/env bash
set -euo pipefail

# Netns lab that mimics OpenWrt PBR + NAT + flow offload.
# Namespaces: ns_client (10.0.0.2), ns_router, ns_vpngw (10.0.0.3), ns_wan (203.0.113.2 DNS server).
# Toggle flow offload with FLOW_OFFLOAD=1; toggle mitigation with MITIGATION=1; toggle marking with USE_PBR_MARK=1.

CMD=${1:-run}
FLOW_OFFLOAD=${FLOW_OFFLOAD:-0}
MITIGATION=${MITIGATION:-1}
USE_PBR_MARK=${USE_PBR_MARK:-1}
DNS_QUERIES=${DNS_QUERIES:-4}
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
LOG_DIR=${LOG_DIR:-"${ROOT_DIR}/reproducer/output"}
CLEAN_LOGS=${CLEAN_LOGS:-0}
TCPDUMP_TIMEOUT=${TCPDUMP_TIMEOUT:-180}

NS_C=ns_client
NS_R=ns_router
NS_V=ns_vpngw
NS_W=ns_wan

VETH_C=c-veth
VETH_R_C=rtr-c
VETH_V=vpn-veth
VETH_R_V=rtr-vpn
VETH_W=wan-veth
VETH_R_W=rtr-wan

LAN_NET=10.0.0.0/24
CLIENT_IP=10.0.0.2
RTR_LAN1_IP=10.0.0.1
VPNGW_IP=10.0.0.3
RTR_LAN2_IP=10.0.0.254
RTR_WAN_IP=203.0.113.1
WAN_IP=203.0.113.2
DNS_PORT=53
PBR_MARK=0xff

mkdir -p "${LOG_DIR}"

log() {
  echo "[netns-lab] $*"
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
  fi
}

clean() {
  for ns in "${NS_C}" "${NS_R}" "${NS_V}" "${NS_W}"; do
    if ip netns list | grep -q "^${ns}\b"; then
      ip netns del "${ns}" || true
    fi
  done
  if [ "${CLEAN_LOGS}" -eq 1 ]; then
    rm -f "${LOG_DIR}"/*.pcap "${LOG_DIR}"/*.log
  fi
  log "cleaned namespaces (logs kept unless CLEAN_LOGS=1)"
}

create_ns() {
  for ns in "${NS_C}" "${NS_R}" "${NS_V}" "${NS_W}"; do
    ip netns add "${ns}" >/dev/null
  done
}

setup_links() {
  ip link add "${VETH_C}" type veth peer name "${VETH_R_C}"
  ip link add "${VETH_V}" type veth peer name "${VETH_R_V}"
  ip link add "${VETH_W}" type veth peer name "${VETH_R_W}"

  ip link set "${VETH_C}" netns "${NS_C}"
  ip link set "${VETH_R_C}" netns "${NS_R}"
  ip link set "${VETH_V}" netns "${NS_V}"
  ip link set "${VETH_R_V}" netns "${NS_R}"
  ip link set "${VETH_W}" netns "${NS_W}"
  ip link set "${VETH_R_W}" netns "${NS_R}"

  for ns in "${NS_C}" "${NS_R}" "${NS_V}" "${NS_W}"; do
    ip netns exec "${ns}" ip link set lo up
  done
}

configure_client() {
  ip netns exec "${NS_C}" ip addr add "${CLIENT_IP}/24" dev "${VETH_C}"
  ip netns exec "${NS_C}" ip link set "${VETH_C}" up
  ip netns exec "${NS_C}" ip route add default via "${RTR_LAN1_IP}"
}

configure_vpngw() {
  ip netns exec "${NS_V}" ip addr add "${VPNGW_IP}/24" dev "${VETH_V}"
  ip netns exec "${NS_V}" ip link set "${VETH_V}" up
  ip netns exec "${NS_V}" sysctl -q -w net.ipv4.ip_forward=1
  ip netns exec "${NS_V}" ip route add default via "${RTR_LAN2_IP}"
}

configure_wan() {
  ip netns exec "${NS_W}" ip addr add "${WAN_IP}/24" dev "${VETH_W}"
  ip netns exec "${NS_W}" ip link set "${VETH_W}" up
  ip netns exec "${NS_W}" ip route add default via "${RTR_WAN_IP}"
}

configure_router() {
  ip netns exec "${NS_R}" ip addr add "${RTR_LAN1_IP}/24" dev "${VETH_R_C}"
  ip netns exec "${NS_R}" ip addr add "${RTR_LAN2_IP}/24" dev "${VETH_R_V}"
  ip netns exec "${NS_R}" ip addr add "${RTR_WAN_IP}/24" dev "${VETH_R_W}"

  for dev in "${VETH_R_C}" "${VETH_R_V}" "${VETH_R_W}"; do
    ip netns exec "${NS_R}" ip link set "${dev}" up
  done

  ip netns exec "${NS_R}" sysctl -q -w net.ipv4.ip_forward=1
  ip netns exec "${NS_R}" sysctl -q -w net.ipv4.conf.all.rp_filter=0
  ip netns exec "${NS_R}" sysctl -q -w net.ipv4.conf.default.rp_filter=0
  for dev in "${VETH_R_C}" "${VETH_R_V}" "${VETH_R_W}"; do
    ip netns exec "${NS_R}" sysctl -q -w net.ipv4.conf."${dev}".rp_filter=0
  done

  ip netns exec "${NS_R}" ip route add default via "${WAN_IP}" dev "${VETH_R_W}"
  ip netns exec "${NS_R}" ip route add table 100 default via "${VPNGW_IP}" dev "${VETH_R_V}"
  ip netns exec "${NS_R}" ip rule add fwmark "${PBR_MARK}" lookup 100
}

start_dns_server() {
  # Lightweight UDP responder that mirrors payload; runs inside ns_wan.
  ip netns exec "${NS_W}" sh -c "python3 -u - <<'PY' >/dev/null 2>&1 & echo \$!" >"${LOG_DIR}/dns.pid" <<'PY'
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", 53))
while True:
    data, addr = sock.recvfrom(512)
    # echo payload back to mimic a DNS reply
    sock.sendto(data, addr)
PY
  log "started UDP echo DNS server in ${NS_W}"
}

stop_dns_server() {
  if [[ -f "${LOG_DIR}/dns.pid" ]]; then
    pid=$(cat "${LOG_DIR}/dns.pid")
    ip netns exec "${NS_W}" kill "${pid}" 2>/dev/null || true
    rm -f "${LOG_DIR}/dns.pid"
  fi
}

install_nft_rules() {
  local ft_block=""
  if [[ "${FLOW_OFFLOAD}" == "1" ]]; then
    ft_block="flow add @ftoffload"
  fi

  local mitigation_skip=""
  if [[ "${MITIGATION}" == "1" ]]; then
    mitigation_skip=$'    meta mark != 0 return\n    ct status { dnat, snat } return'
  fi

  local mark_rule=""
  if [[ "${USE_PBR_MARK}" == "1" ]]; then
    mark_rule="  iifname ${VETH_R_C} udp dport ${DNS_PORT} meta mark set ${PBR_MARK}"
  fi

  ip netns exec "${NS_R}" nft -f - <<EOF
flush ruleset

table inet filter {
  flowtable ftoffload {
    hook ingress priority 0; devices = { ${VETH_R_C}, ${VETH_R_V}, ${VETH_R_W} };
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname ${VETH_R_C} oifname ${VETH_R_W} ct state new counter accept
    iifname ${VETH_R_C} oifname ${VETH_R_V} ct state new counter accept
    iifname ${VETH_R_V} oifname ${VETH_R_W} ct state new counter accept
    iifname ${VETH_R_W} oifname ${VETH_R_C} ct state new counter accept
    iifname ${VETH_R_W} oifname ${VETH_R_V} ct state new counter accept
${mitigation_skip}
${ft_block:+    ${ft_block}}
  }
}

table inet mangle {
  chain prerouting {
    type filter hook prerouting priority -150; policy accept;
${mark_rule}
  }
}

table ip nat {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
  }
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    oifname ${VETH_R_W} snat to ${RTR_WAN_IP}
  }
}
EOF
  log "installed nft rules (flow offload=${FLOW_OFFLOAD}, mitigation=${MITIGATION}, pbr mark=${USE_PBR_MARK})"
}

generate_traffic() {
  log "sending ${DNS_QUERIES} UDP queries (A+AAAA style) from client"
  ip netns exec "${NS_C}" python3 - <<PY
import socket, threading, time
server=("${WAN_IP}", ${DNS_PORT})
payloads=[b"A-query", b"AAAA-query"] * (${DNS_QUERIES}//2)

def send(payload):
    s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    s.sendto(payload, server)
    try:
        s.recvfrom(512)
    except socket.timeout:
        pass
    s.close()

threads=[threading.Thread(target=send, args=(p,)) for p in payloads]
[t.start() for t in threads]
[t.join() for t in threads]
PY
}

capture_mac_checks() {
  if ! command -v tcpdump >/dev/null 2>&1; then
    log "tcpdump missing; skipping MAC validation"
    generate_traffic
    return 0
  fi
  local pcap="${LOG_DIR}/lan-capture.pcap"
  local txt="${LOG_DIR}/lan-capture.log"
  local run_capture_once
  run_capture_once() {
    local queries="${1:-${DNS_QUERIES}}"
    timeout --foreground --kill-after=10 "${TCPDUMP_TIMEOUT}" \
      ip netns exec "${NS_R}" tcpdump -nn -e -i "${VETH_R_C}" udp port ${DNS_PORT} and dst host ${CLIENT_IP} -c "${queries}" -w "${pcap}" >"${txt}" 2>&1 &
    local tcpdump_pid=$!
    DNS_QUERIES="${queries}" generate_traffic
    wait "${tcpdump_pid}" || true
    ip netns exec "${NS_R}" tcpdump -nn -e -r "${pcap}" >"${txt}" 2>/dev/null || true
  }

  run_capture_once "${DNS_QUERIES}" || true

  local expected_mac
  expected_mac=$(ip netns exec "${NS_C}" cat /sys/class/net/"${VETH_C}"/address)
  local observed_mac
  observed_mac=$(awk '/ethertype IPv4/ {gsub(",", "", $4); print $4}' "${txt}" | sort -u)

  if [ -z "${observed_mac}" ]; then
    log "no packets captured; retrying capture with more queries"
    run_capture_once 12 || true
    observed_mac=$(awk '/ethertype IPv4/ {gsub(",", "", $4); print $4}' "${txt}" | sort -u)
  fi

  if [ -z "${observed_mac}" ]; then
    log "still no packets captured; skipping MAC validation"
    return 0
  fi

  log "expected client MAC: ${expected_mac}"
  log "observed destination MACs on LAN egress: ${observed_mac:-none}"

  if echo "${observed_mac}" | grep -qi "${expected_mac}"; then
    log "MAC delivery OK (matches client)"
    return 0
  else
    log "MAC delivery MISMATCH (possible reproduction)"
    return 1
  fi
}

show_state() {
  ip netns exec "${NS_R}" nft list ruleset >"${LOG_DIR}/nft-ruleset.log"
  ip netns exec "${NS_R}" nft list flowtable inet filter ftoffload >"${LOG_DIR}/flowtable.log" 2>/dev/null || true
  ip netns exec "${NS_R}" ip rule show >"${LOG_DIR}/ip-rule.log"
  ip netns exec "${NS_R}" ip route show table all >"${LOG_DIR}/ip-route.log"
  ip netns exec "${NS_R}" ip -s neigh show >"${LOG_DIR}/ip-neigh.log"
  ip netns exec "${NS_R}" conntrack -L >"${LOG_DIR}/conntrack.log" 2>/dev/null || true
  log "state dumped to ${LOG_DIR}"
}

run_lab() {
  require_root
  clean
  create_ns
  setup_links
  configure_client
  configure_vpngw
  configure_wan
  configure_router
  install_nft_rules
  start_dns_server
  trap cleanup INT TERM EXIT

  # small delay for routes to settle
  sleep 1

  log "capturing responses while generating traffic"
  capture_mac_checks || true
  show_state

  log "lab complete (namespaces remain until clean)"
}

cleanup() {
  stop_dns_server
  clean
}

case "${CMD}" in
  run)
    run_lab
    ;;
  clean)
    cleanup
    ;;
  *)
    echo "Usage: $0 [run|clean]" >&2
    exit 1
    ;;
esac
