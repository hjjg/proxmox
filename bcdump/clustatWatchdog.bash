#!/bin/bash
#
# License: GPLv2
# Author: Peter Maloney
#
# a watchdog script that watches the "clustat" output.
# When clustat does not say "Quorate" (either it says "Inquorate", or "Could not connect
# to CMAN: Connection refused"), then cman and pve-cluster are restarted in the hopes that 
# this node is then is quorate, and the next node to disconnect does not cause the whole
# cluster to become inquorate

date

# timeFile contains the last timestamp when cman and pve-cluster were restarted
timeFile=$(dirname "$0")/$(basename "$0" | sed -r "s/\.[^.]+$//").lastrestart

# now is the current time in seconds
now=$(date +%s)
# prevTime is the content of timeFile (the last timestamp when cman and pve-cluster were restarted)
if [ ! -e "$timeFile" ]; then
    prevTime=0
else
    prevTime=$(cat "${timeFile}")
fi
# nextRun is the earliest that cman and pve-cluster can be restarted again by this script
nextRun=$(($prevTime+5*60))

if [ "$now" -lt "$nextRun" ]; then
    echo "Skipping check"
    echo "    now      = $now"
    echo "    prevTime = $prevTime"
    echo "    nextRun  = $nextRun"
    date
    exit 1
fi

memberStatus=$(/usr/sbin/clustat | grep "Member Status:" | cut -f2 -d':' | sed -r "s/[ \t]+//g")

# test
#memberStatus=exploded

if [ "$memberStatus" != "Quorate" ]; then
    echo "not Quorate, so restarting cman and pve-cluster..."
    echo "    memberStatus = $memberStatus"
    echo "==============="
    echo "clustat output:"
    /usr/sbin/clustat
    echo "==============="
    /etc/init.d/cman restart
    /etc/init.d/pve-cluster restart
#    date +%s > "$timeFile"
else
    echo "Quorate; no action needed"
fi

date

