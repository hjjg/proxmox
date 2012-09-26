#!/bin/bash
# 
# License: GPLv2
# Author: Peter Maloney - peter.maloney ahhtt brockmann-consult.de
#
# Replaces vzdump because vzdump often hangs while running vmtar, never to work again
# It handles one vmid per loop.
# In the loop:
#    - first some paranoid checking happens to make sure lvm isn't hung or vms aren't locked (but no guarantee that the vm is not locked between the check and the finish of the dump); this script does not lock the vm (todo?)
#    - dump the vm images and config together in a gzipped tar, with a .tgz.tmp name
#    - dumping includes creating a snapshot, mounting the snapshot, running tar czf ..., unmounting the snapshot, and removing the snapshot
#    - when dump is complete, rename the .tgz.tmp to a .tgz file

# hardcoded backup base directory (and /bcdump/ will be appended later)
# This directory is not checked to make sure it is mounted; if not, it will ignorantly create a $dest/bcdump/xxxxx.tgz for each vm
# This is an NFS share that is mounted by proxmox
dest=/mnt/pve/bcnas1san

vmids="$@"

# if snapshot exists before anything here, give up now
if [ -e /dev/mapper/pve-bcvmdumpsnap ]; then
    echo "ERROR: /dev/mapper/pve-bcvmdumpsnap already exists"
    exit 1
fi

for vmid in $vmids; do
    echo "========================================================="
    echo "Beginning dump for vmid $vmid - $(date)"
    echo "========================================================="
    echo

    # if snapshot exists in between loops, try to remove, and give up if it fails
    if [ -e /dev/mapper/pve-bcvmdumpsnap ]; then
        echo "WARNING: \"bcvmdumpsnap\" snapshot still exists... trying to remove it"
        if lvremove -f /dev/mapper/pve-bcvmdumpsnap; then
            echo "Snapshot removed successfully."
        else
            echo "ERROR: snapshot removal failed... aborting backup"
            exit 2
        fi
    fi

    #if snapshots (especially ones other than "bcvmdumpsnap") exist
    if lvscan 2>&1 | grep -i snapshot; then
        echo "ERROR: snapshot other than bcvmdumpsnap found; aborting backup"
        exit 3
    fi
        
    #if lvscan or lvs have any errors
    if lvscan 2>&1 | grep -i "Input/output error"; then
        echo "ERROR: error running lvscan; aborting backup"
        exit 4
    fi
    if lvs >/dev/null 2>&1 | grep -i "Input/output error"; then
        echo "ERROR: error running lvs; aborting backup"
        exit 5
    fi

    #if vzdump is running
    if ps -ef | grep vzdump | grep -v grep >/dev/null 2>&1; then
        echo "ERROR: vzdump appears to be running; aborting backup"
        ps -ef | grep vzdump | grep -v grep
        exit 6
    fi
    
    #if the target vm is locked
    if qm config $vmid 2>&1 | grep lock >/dev/null 2>&1; then
        echo "ERROR: vm $vmid is locked; aborting backup"
        qm config $vmid | grep lock
        exit 7
    fi

    echo "Creating lvm snapshot"
    lvcreate --size 4G --snapshot --name bcvmdumpsnap /dev/mapper/pve-data
    trap "umount -l /dev/mapper/pve-bcvmdumpsnap; lvremove -f /dev/mapper/pve-bcvmdumpsnap" SIGHUP SIGINT SIGQUIT SIGABRT SIGKILL SIGALRM SIGTERM
    lvdisplay /dev/mapper/pve-bcvmdumpsnap
    
    echo "Mounting lvm snapshot"
    mkdir -p /mnt/bcvmdumpsnap
    mount -o ro /dev/mapper/pve-bcvmdumpsnap /mnt/bcvmdumpsnap
    
    echo "Making backup archive"
    date=$(date --iso-8601=second)
    mkdir -p "${dest}/bcdump"
    tar czf "${dest}/bcdump/bcdump_${vmid}_${date}.tgz.tmp" "/etc/pve/qemu-server/${vmid}".* "/mnt/bcvmdumpsnap/images/${vmid}"
    status=$?
    echo "Done backup; status = $status"
    if [ "$status" = 0 ]; then
        # using a .tmp extension and then removing it makes it clear which files are failed in the middle, and which are complete
        mv "${dest}/bcdump/bcdump_${vmid}_${date}.tgz.tmp" "${dest}/bcdump/bcdump_${vmid}_${date}.tgz"
    fi
    
    echo "Unounting lvm snapshot"
    umount /dev/mapper/pve-bcvmdumpsnap
    status=$?
    if [ "$status" != "0" ]; then
        echo "Unmounting failed... trying again with -l"
        umount -l /dev/mapper/pve-bcvmdumpsnap
    fi
    rmdir /mnt/bcvmdumpsnap
    
    lvdisplay /dev/mapper/pve-bcvmdumpsnap
    echo "Removing snapshot"
    lvremove -f /dev/mapper/pve-bcvmdumpsnap
    
    echo "Done removing snapshot"

    echo "lvs:"
    lvs
    echo

    echo "lvscan:"
    lvscan
    echo

    echo "lvdisplay /dev/mapper/pve-bcvmdumpsnap"
    lvdisplay /dev/mapper/pve-bcvmdumpsnap
    echo

done

echo "========================================================="
echo "Done all vms - $(date)"
echo "========================================================="

