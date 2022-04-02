#!/bin/bash

while [[ $1 =~ ^- ]]; do
    case $1 in
    -d)
        DEVICE="$2"
        shift
        shift
        ;;

    -v)
        VERBOSE="$1"
        shift
        ;;

    -h)
        HELP=$1
        set --
    esac
done

if [[ -n "$HELP" ]] || [[ -z "$DEVICE" ]] || [[ $# -ne 1 ]]; then
   echo "Usage: $0 -d <target-device>  <frozen-pi-directory>" >&2
   exit 1
fi

FROZEN=$1
# test for required files
cat "$FROZEN/lsblk.txt" >/dev/null || exit $?
cat "$FROZEN/sfdisk.txt" >/dev/null || exit $?

# make sure target has no mounts
while [[ -n "$(lsblk -no mountpoint $DEVICE)" ]]; do
    umount $(lsblk -no mountpoint $DEVICE) 2>/dev/null
done

# partition target as required
OLD_DISK_ID=$(sed -n 's/^label-id: 0x//p' $FROZEN/sfdisk.txt)
DISK_ID=$(printf "%04x%04x" $RANDOM $RANDOM)
sed "s/^label-id: 0x$OLD_DISK_ID/label-id: 0x$DISK_ID/; $ s/size= *[0-9]*,//" $FROZEN/sfdisk.txt |
sfdisk -b $DEVICE || exit $?

# make each filesystem
n=0
while read pairs; do
    eval "$pairs"
    if [[ "$TYPE" == "part" ]]; then
        let n++
        if [[ $FSTYPE == "vfat" ]]; then
            MKFS_OPTIONS="${LABEL:+-n $LABEL}"
        else
            MKFS_OPTIONS="${LABEL:+-L $LABEL}"
        fi

        mkfs -t $FSTYPE ${MKFS_OPTIONS} ${DEVICE}$n || exit $?
    fi
done < "$FROZEN/lsblk.txt" 

# recover each filesystem
MNT=/tmp/mnt-$$
n=0
while read pairs; do
    eval "$pairs"
    if [[ "$TYPE" == "part" ]]; then
        let n++
        TAG=${LABEL:-$NAME}
        MOUNTPOINT=$MNT/$TAG
        mkdir -p $MOUNTPOINT
        mount ${DEVICE}$n $MOUNTPOINT || exit $?
        rsync -arvz $FROZEN/$TAG/. $MOUNTPOINT/
    fi

    # Patch up the boot filesystem and the fstab on the rootfs
    if [[ "$LABEL" == boot ]]; then
        sed -i~ "s/\\(PARTUUID\\)=$OLD_DISK_ID-\\([0-9]*\\)/\\1=$DISK_ID-\\2/" $MOUNTPOINT/cmdline.txt
    fi

    if [[ -f $MOUNTPOINT/etc/fstab ]]; then
        sed -i~ "s/^\\(PARTUUID\\)=$OLD_DISK_ID-\\([0-9]*\\)/\\1=$DISK_ID-\\2/" $MOUNTPOINT/etc/fstab
    fi

    umount $MOUNTPOINT
done < "$FROZEN/lsblk.txt" 

rm -rf $MNT

