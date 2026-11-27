#!/bin/bash
# SPDX-License-Identifier: MIT
# The cellular data link's details for the mobile network card, one JSON
# line: its interface, address, bytes in and out since it came up, one
# ping's time through it (ms, -1 for none), and whether it carries the
# internet now (the default route; a speed test would test it). Nothing when no rmnet link has
# an address. The ping goes out the cellular link even with Wi-Fi up.
# OMAMOBILE_CELL_SYSFS: a fake /sys/class/net for the tests.
net=${OMAMOBILE_CELL_SYSFS:-/sys/class/net}
probe=1.1.1.1
for d in "$net"/rmnet*; do
  [[ -d $d ]] || continue
  i=${d##*/}
  [[ $(cat "$d/operstate" 2>/dev/null) == down ]] && continue
  addr=$(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
  [[ -n $addr ]] || addr=$(ip -6 -o addr show dev "$i" scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
  [[ -n $addr ]] || continue
  rx=$(cat "$d/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx=$(cat "$d/statistics/tx_bytes" 2>/dev/null || echo 0)
  ms=-1
  if [[ ${1:-} != --no-ping ]] && command -v ping >/dev/null; then
    t=$(LC_ALL=C ping -n -c 1 -W 2 -I "$i" "$probe" 2>/dev/null | awk -F'time[=<]' '/time[=<]/ { split($2, p, " "); print p[1]; exit }')
    [[ -n $t ]] && ms=$t
  fi
  def=false
  [[ $(ip route get "$probe" 2>/dev/null) == *" dev $i "* ]] && def=true
  printf '{"iface":"%s","address":"%s","rx":%s,"tx":%s,"ping":%s,"default":%s}\n' "$i" "$addr" "${rx:-0}" "${tx:-0}" "$ms" "$def"
  exit 0
done
