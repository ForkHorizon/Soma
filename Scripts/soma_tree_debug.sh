#!/bin/bash
# Process-tree debugger for the Soma APP. Logs:
#  - every descendant of the Soma app pid (ppid BFS) = what the app really spawns
#  - Soma's own model servers if they detached (asr_server.py / voice_*.py)
#  - NEW pids since last sample = spawn-storm detector
# Ignores soma_mcp_server.py (those are MCP servers spawned by editors/Claude, not the app).
LOG="$HOME/soma_tree_debug.log"
PREV="/tmp/soma_tree_prev_pids"
SNAP="/tmp/soma_ps_snap.$$"
ps -Ao pid,ppid,pcpu,rss,command > "$SNAP"
APP=$(pgrep -x Soma | head -1)

PIDS=$(awk -v root="$APP" '
  { pid[NR]=$1; ppid[NR]=$2; cmd[$1]=$0 }
  END {
    if (root != "") keep[root]=1
    changed=1
    while (changed) { changed=0
      for (i=1;i<=NR;i++) if (root!="" && keep[ppid[i]] && !keep[pid[i]]) { keep[pid[i]]=1; changed=1 } }
    # Soma-owned model servers even if reparented to launchd (NOT soma_mcp_server)
    for (i=1;i<=NR;i++) if (cmd[pid[i]] ~ /asr_server\.py|voice_asr_backend|voice_server\.py/) keep[pid[i]]=1
    for (p in keep) if (p!="") print p
  }' "$SNAP")

NPROC=$(echo "$PIDS" | grep -c '[0-9]')
DETAIL=$(echo "$PIDS" | while read p; do [ -n "$p" ] && awk -v P="$p" '$1==P{print}' "$SNAP"; done)
TOT=$(echo "$DETAIL" | awk '{rss+=$4; cpu+=$3} END{printf "rss=%.0fMB cpu=%.1f%%", rss/1024, cpu}')
BY=$(echo "$DETAIL" | awk '{n=split($5,a,"/"); b=a[n]; if(b~/Python/)b="python"; c[b]++} END{for(k in c) printf " %dx%s",c[k],k}')

NEWP=0; DIED=0
if [ -f "$PREV" ]; then
  NEWP=$(comm -13 <(sort "$PREV") <(echo "$PIDS"|grep '[0-9]'|sort) 2>/dev/null | grep -c '[0-9]')
  DIED=$(comm -23 <(sort "$PREV") <(echo "$PIDS"|grep '[0-9]'|sort) 2>/dev/null | grep -c '[0-9]')
fi
echo "$PIDS" | grep '[0-9]' | sort > "$PREV"

SWAP=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*M\).*/\1/p')
WS=$(ps -o pcpu= -p "$(pgrep -x WindowServer|head -1)" | tr -d ' ')
echo "$(date '+%H:%M:%S') app=${APP:-none} tree=$NPROC NEW=$NEWP died=$DIED tree_$TOT | swap=$SWAP WinServer=${WS}% |$BY" | tee -a "$LOG"
rm -f "$SNAP"
