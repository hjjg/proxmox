#!/bin/bash
#
# License: GPLv2
# Author: Peter Maloney - peter.maloney ahhtt brockmann-consult.de
#
# bcdump cleanup
# Removes all but the latest valid file

# This is the dump directory, including the "bcdump" subdirectory
dumpDir=/mnt/pve/bcnas1san/bcdump




# lists pids from "ps auxww" excluding grep and this script
listBcdumpProcesses() {
    ps auxww | grep bcdump | grep -vE "grep|bcdump\.bash|bcdump_clean\.bash" | sed -r "s/[ ]{2,}/ /g" | cut -f2 -d' '
    # returns zero if something found, non-zero if nothing found
    return ${PIPESTATUS[2]}
}

rm2() {
    rm "$@"
}

cd "$dumpDir"

if listBcdumpProcesses >/dev/null 2>&1; then
    echo "WARNING: bcdump appears to be running..."
fi

IFS=$'\n'
for num in $(ls -1 bcdump_* | grep -Eo "^bcdump_[0-9]*" | sort | uniq | grep -o "[0-9]*$"); do
    echo "======================================="
    echo vmid $num
    echo "======================================="

    keep=
    # find a file to keep (the first one that "tar t" says is good)
    for file in $(ls -1t "bcdump_$num"*); do
        # if "tested" is found, we skip the test
        if echo "$file" | grep "tested" >/dev/null 2>&1; then
            echo "Keeping: $file"
            keep="$file"
            break
        elif echo "$file" | grep "failed" >/dev/null 2>&1; then
            echo "Skipping: $file"
            continue
        fi

        # if not found, test it, and mark it "tested" if it passes
        # test integrity
        echo "Testing $file"
        # using ./ because otherwise it treats the colons weird, trying to connect to a host with ssh
        if tar tzf ./"$file"; then
            testedFile=$(echo "$file" | sed -r "s/.tgz(.tmp)?\$/_tested.tgz/")
            echo "File passes test, $file renaming to $testedFile"
            mv "$file" "$testedFile"
            echo "Keeping: $testedFile"
            keep="$testedFile"
            break
        else
            failedFile=$(echo "$file" | sed -r "s/.tgz\$/_failed.tgz/")
            echo "WARNING: File fails test, $file renaming to $failedFile"
            mv "$file" "$failedFile"
        fi
        echo
    done

    if [ -z "$keep" ]; then
        echo "ERROR: nothing to keep; skipping clean"
        continue
    fi

    echo "Cleaning other files..."
    for file in $(ls -1t "bcdump_$num"* | grep -v "$keep"); do
        # remove unless it's the keep one
        if [ "$file" = "$keep" ]; then
            echo "Skiping latest good file: $file"
            continue
        elif [ $(stat -c %Z "$file") -gt $(date +%s -d -1day) ]; then
            # Keep files that are less than a day old
            # This makes it possible to clean while backup is running
            echo "Skiping file that is newer than a day: $file"
            echo "    last change: $(stat -c %Z "$file")"
            echo "    yesterday:   $(date +%s -d -1day)"
            continue
        fi
        echo "Removing $file"
        rm2 "$file"
    done

    echo
done

