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
#
# Usage:
#   bcdump
#       - dump all vms that are: ( running OR set to run on boot ) AND have local disks
#   bcdump $vmid
#       - dump a specific vm
#   bcdump $vmid1 $vmid2 ...
#       - dump a few specific vms
#
# Limitations/assumptions:
#   "have local disks" assumes that all disks are either ide or virtio
#   no locks are created; this assumes that it doesn't matter... eg. the disk in LVM is assumed to match the vm config which is not part of the same atomic snapshot

# hardcoded backup base directory (and /bcdump/ will be appended later)
# This directory is not checked to make sure it is mounted; if not, it will ignorantly create a $dest/bcdump/xxxxx.tgz for each vm
# This is an NFS share that is mounted by proxmox

# TODO: this script has not been tested since modularizing these variables
dest=/mnt/pve/bcnas1san
lv=/dev/mapper/pve-data
lvMountpoint=/mnt/testlv
snap=/dev/mapper/testvg-bcvmdumpsnap
snapMountpoint=/mnt/bcvmdumpsnap

vmids="$@"

if [ "$#" = 0 ]; then
    # if no vmids were given, then automatically select all that seem useful
    # Wasn't sure on how to detect. Here are the ideas
    # include:
    # - vms currently running
    # - vms that have run since the last backup
    # - vms that have onboot:1 set
    # exclude:
    # - vms with no local disks
    #
    # Here is the decision for now:
    # - union of "onboot:1 set" and "currently running"

    # Next command lists vmids with onboot:1 set
    vmids1=$(grep onboot /etc/pve/qemu-server/*.conf | cut -d'/' -f5 | cut -d'.' -f1 | sort | uniq)
#vmids1=$'1\n2\n5'

    # Next command lists vmids running now
    vmids2=$(qm list | grep -Eo "^[ ]+[0-9]+" | tr -d ' ' | sort | uniq)
#vmids2=$'2\n3'

    # Next command lists vms with local disks
    vmids3=$(egrep "ide.*local|virtio.*local:" /etc/pve/qemu-server/*.conf | cut -d'/' -f5 | cut -d'.' -f1 | sort | uniq)
#vmids3=$'1\n5'

    # ( vmids1 union vmids2 )
    vmids=$(echo "$vmids1"$'\n'"$vmids2" | sort | uniq)

    # ( vmids1 union vmids2 ) intersection vmids3
    vmids=$(comm -12 <(echo "$vmids") <(echo "$vmids3"))

#    echo "auto vmids:"
#    echo "$vmids"
#    exit 2
fi

# if snapshot exists before anything here, give up now
if [ -e "${snap}" ]; then
    echo "ERROR: "${snap}" already exists"
    exit 1
fi

for vmid in $vmids; do
    echo "========================================================="
    echo "Beginning dump for vmid $vmid - $(date)"
    echo "========================================================="
    echo

    # if snapshot exists in between loops, try to remove, and give up if it fails
    if [ -e "${snap}" ]; then
        echo "WARNING: \"bcvmdumpsnap\" snapshot still exists... trying to remove it"
        if lvremove -f "${snap}"; then
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
    lvcreate --size 4G --snapshot --name bcvmdumpsnap "${lv}"
    trap "umount -l \"${snap}\"; lvremove -f \"${snap}\"" SIGHUP SIGINT SIGQUIT SIGABRT SIGKILL SIGALRM SIGTERM
    lvdisplay "${snap}"
    
    echo "Mounting lvm snapshot"
    mkdir -p "${snapMountpoint}"
    mount -o ro "${snap}" "${snapMountpoint}"
    
    echo "Making backup archive"
    date=$(date --iso-8601=second)
    mkdir -p "${dest}/bcdump"
    tar czf "${dest}/bcdump/bcdump_${vmid}_${date}.tgz.tmp" "/etc/pve/qemu-server/${vmid}".* "${snapMountpoint}/images/${vmid}"
    status=$?
    echo "Done backup; status = $status"
    if [ "$status" = 0 ]; then
        # using a .tmp extension and then removing it makes it clear which files are failed in the middle, and which are complete
        mv "${dest}/bcdump/bcdump_${vmid}_${date}.tgz.tmp" "${dest}/bcdump/bcdump_${vmid}_${date}.tgz"
    fi
    
    echo "Unounting lvm snapshot"
    umount "${snap}"
    status=$?
    if [ "$status" != "0" ]; then
        echo "Unmounting failed... trying again with -l"
        umount -l "${snap}"
    fi
    rmdir "${snapMountpoint}"
    
    lvdisplay "${snap}"
    echo "Removing snapshot"
    lvremove -f "${snap}"
    
    echo "Done removing snapshot"

    echo "lvs:"
    lvs
    echo

    echo "lvscan:"
    lvscan
    echo

    echo "lvdisplay \"${snap}\""
    lvdisplay "${snap}"
    echo

done

echo "========================================================="
echo "Done all vms - $(date)"
echo "========================================================="

