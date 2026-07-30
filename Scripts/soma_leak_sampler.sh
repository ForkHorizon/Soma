#!/bin/bash
# Auto-sampler: appends a Soma fingerprint every 120s for up to 4h.
PROBE="/Users/daliys/Daliys/Swift/Soma/Scripts/soma_leak_probe.sh"
for i in $(seq 1 120); do
  "$PROBE" >/dev/null 2>&1
  sleep 120
done
