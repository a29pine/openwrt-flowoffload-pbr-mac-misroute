---
name: Bug report
about: Flow offload + PBR + NAT wrong-MAC reproduction
labels: bug
---

**Device / target**
- Device model / SoC:
- OpenWrt version (e.g., 24.10.0 snapshot hash):
- Flow offload type: software / hardware (SoC if HW)

**Network setup**
- PBR marks/rules (e.g., fwmark 0xff -> table 100):
- NAT in use (DNAT redirect? SNAT masquerade?):
- LAN/VPN gateway MAC address:

**Reproduction steps**
- Flow offload enabled? (yes/no)
- Traffic pattern (e.g., concurrent A+AAAA DNS queries):
- Observed result (wrong dest MAC, which MAC?):

**Collected artifacts**
- Attach outputs: `nft list ruleset`, `nft list flowtable`, `ip rule`, `ip route show table all`, `ip -s neigh`, `conntrack -L` (if available)
- Packet captures with `tcpdump -e` showing wrong L2 dest MAC and correct IP tuple

**Mitigation status**
- Mitigation applied? (meta mark / NAT skip rules): yes/no
- If applied, did issue resolve?

**Notes**
- Any hardware offload or switch driver specifics (e.g., mt7621) and timing sensitivity (dual A/AAAA) observations.
