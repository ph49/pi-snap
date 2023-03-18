#!/bin/bash

# Snapshot pi : 
# snapshots important system state and 
# makes (incremental) filesystem copies

# requires:
#  -t <target directory for this backup>
#  -h <host to get frozen state from (via ssh)
#  NOTE: host defaults to localhost (and no ssh)
#  target directory defaults to ./<host>

TARGET=
HOST=
CLEAN=
ERROR=
while [[ $1 =~ ^- ]]; do
    case $1 in
    -t)
        TARGET="$2"
        shift
        shift
        ;;

    -s)
        SRC="$2"
        shift
        shift
        ;;

    -h)
        HOST="$2"
        shift
        shift
        ;;

    -c)
        CLEAN="$1"
        shift
        ;;

    -k)
        KEEP="$2"
        shift; shift
        ;;


    -v)
        VERBOSE="$1"
        shift
        ;;

    *)
        ERROR=1
        set --
    esac
done

# Default to backing up local device
SRC=${SRC:-/dev/mmcblk0}
if [[ -n "$ERROR" ]] || [[ -z "$HOST" && -z "$TARGET" ]] ||
 [[ $# -gt 0 ]]; then
   echo "Usage: $0 [-h [user@]hostname] [-s srcdevice] [-t targetdir] [-c clean] [-v] [-k KEEP]" >&2
   echo " Note: at least one of <hostname> or <targetdir> are required" >&2
   echo " KEEP is an integer >=1" >&2
   exit 1
fi

REMOTE=
RSYNC_REMOTE=
RSYNC_HOST=
if [[ -n "$HOST" ]]; then
  TARGET=${TARGET:-$HOST/$HOST.snap}
  REMOTE_CMD="ssh -o ControlPath=/tmp/cp-$$"
  RSYNC_HOST="$HOST:"
  REMOTE="$REMOTE_CMD -n $HOST"
  # unset LC_ALL because our local locale is not necessarily available on the target
  unset LC_ALL
  # set up persistent controlpath
  ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o Compression=yes -o ControlPath=/tmp/cp-$$ -o ControlMaster=yes -o ControlPersist=0 $HOST /bin/true
  RC=$?
  ((RC)) && exit $RC
  trap "ssh -o ControlPath=/tmp/cp-$$ -O stop $HOST" EXIT
fi

remote() {
    if [[ -z $REMOTE ]]; then
        ( set -x
            "$@"
        )
    else
      ( set -x
        $REMOTE "$@"
      )
    fi
}


[[ -n "$CLEAN" ]] && rm -rf "$TARGET"
mkdir -p $TARGET

#Remove (rather than just truncate) the top-level .txt files
#This means you can use `(. $TARGET/metadata.txt; cp -al $TARGET $TARGET-$DATE)` to make a backup of the 
#pi snap, and then overwrite the current one without 
#affecting the backup

rm -f $TARGET/metadata.txt
echo DATE=$(date +%FT%T) > $TARGET/metadata.txt
echo HOST=$HOST >> $TARGET/metadata.txt

rm -f $TARGET/sfdisk.txt
remote sudo sfdisk -d $SRC > $TARGET/sfdisk.txt
rm -f $TARGET/lsblk.txt
remote sudo lsblk -Po name,type,fstype,label,mountpoint,partuuid $SRC > $TARGET/lsblk.txt

MNT_PREFIX=/tmp/mnt-$$
while read pairs; do
    eval "$pairs"

    if [[ "$TYPE" == "part" ]]; then
        TAG="${LABEL:-$NAME}"
        MNT=$MNT_PREFIX/$TAG/
        if [[ -z "$MOUNTPOINT" ]]; then
            # Looks like this is an unmounted partition, maybe an overlayfs is in use?
            MOUNTCMD=(mount -o ro /dev/$NAME $MNT)
        else
            MOUNTCMD=(mount -o ro,bind $MOUNTPOINT $MNT)
        fi
        remote sudo mkdir -p "$MNT"
        remote ls -ld $MNT
        remote sudo "${MOUNTCMD[@]}"
        rsync ${VERBOSE:+-v} --rsync-path="sudo rsync" -e "$REMOTE_CMD" --delete -arz "$RSYNC_HOST""$MNT"/ $TARGET/$TAG/ 
        remote sudo umount $MNT
    fi
done <$TARGET/lsblk.txt
remote sudo rm -rf /tmp/mnt-$$/

if [[ -n "$KEEP" ]]; then
    (   . $TARGET/metadata.txt;
        sh -x -c "cp -al '$TARGET' '$TARGET-$DATE'"
    )
    
    echo "# keep $KEEP would remove:" >&2
    echo "rm -rf $(ls -d $TARGET-* | head -n -$KEEP)" >&2
fi

