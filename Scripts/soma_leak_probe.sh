#!/bin/bash
# Soma memory-pressure probe. Appends one line to ~/soma_leak_probe.log each run.
LOG="$HOME/soma_leak_probe.log"
PID=$(pgrep -x Soma | head -1)
# System swap + memory pressure (the real signal on a RAM-bound box)
SWAP=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*M\).*/\1/p')
FREEPCT=$(memory_pressure 2>/dev/null | awk -F: '/free percentage/{gsub(/ /,"",$2);print $2}')
# Model/child RSS: Whisper (asr_server) + ollama runner + Soma app
ASR=$(ps -Ao rss,command | grep -i 'asr_server.py' | grep -v grep | awk '{s+=$1} END{printf "%.0f", s/1024}')
OLL=$(ps -Ao rss,command | grep -iE 'ollama' | grep -v grep | awk '{s+=$1} END{printf "%.0f", s/1024}')
APP=$([ -n "$PID" ] && ps -o rss= -p "$PID" | awk '{printf "%.0f",$1/1024}' || echo 0)
ET=$([ -n "$PID" ] && ps -o etime= -p "$PID" | tr -d ' ' || echo "-")
LINE=$(printf "%s  swap_used=%-8s free=%-4s | Soma_app=%-5sMB asr_model=%-6sMB ollama=%-6sMB  uptime=%s" \
  "$(date '+%H:%M:%S')" "${SWAP:-?}" "${FREEPCT:-?}" "$APP" "${ASR:-0}" "${OLL:-0}" "$ET")
echo "$LINE" | tee -a "$LOG"
