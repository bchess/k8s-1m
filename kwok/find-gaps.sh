#!/usr/bin/env bash
awk '/kwok-node-/ { match($1, /kwok-node-([0-9]+)/, arr); if (arr[1] != "") print arr[1]; }' $1 | sort -n | awk 'NR>1 && $1 != prev+1 { print "Gap detected: " prev+1 " to " $1-1 } { prev=$1 }'
