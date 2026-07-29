#!/bin/bash
# Runs the tree debugger every 8s for ~4h. Catches spawn storms while you use Soma.
for i in $(seq 1 1800); do
  /Users/daliys/Daliys/Swift/Soma/Scripts/soma_tree_debug.sh >/dev/null 2>&1
  sleep 8
done
