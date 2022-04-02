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
    esac
done

SRC=${SRC:-/dev/mmcblk0}
if [[ -z "$HOST" && -z "$TARGET" ]] ||
 [[ $# -gt 0 ]]; then
   echo "Usage: $0 [-h hostname] [-t targetdir] [-c clean]" >&2
   echo " Note: at least one of <hostname> or <targetdir> are required"
   exit 1
fi

REMOTE=
RSYNC_REMOTE=
RSYNC_HOST=
if [[ -n "$HOST" ]]; then
  TARGET=${TARGET:-$HOST.snap}
  REMOTE_CMD="ssh -o ControlPath=/tmp/cp-$$"
  RSYNC_HOST="$HOST:"
  REMOTE="$REMOTE_CMD -n $HOST"
  ssh -o Compression=yes -o ControlPath=/tmp/cp-$$ -o ControlMaster=yes -o ControlPersist=0 $HOST /bin/true
  trap "ssh -o ControlPath=/tmp/cp-$$ -O stop $HOST" EXIT
  RC=$?
  ((RC)) && exit $RC
fi

if [[ -n "$KEEP" && -d $TARGET ]]; then
    (   . $TARGET/metadata.txt;
        cp -al $TARGET $TARGET-$DATE
    )
    
    echo rm -rf $(ls -d $TARGET-* | head -n -$KEEP) >&2
    exit
fi


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
$REMOTE sudo sfdisk -d $SRC > $TARGET/sfdisk.txt
rm -f $TARGET/lsblk.txt
$REMOTE sudo lsblk -Po name,type,fstype,label,mountpoint,partuuid $SRC > $TARGET/lsblk.txt

MNT_PREFIX=/tmp/mnt-$$
while read pairs; do
    eval "$pairs"
    if [[ "$TYPE" == "part" ]]; then
        TAG="${LABEL:-$NAME}"
        MNT=$MNT_PREFIX/$TAG/
        $REMOTE sudo mkdir -p "$MNT"
        $REMOTE sudo mount -o ro,bind "$MOUNTPOINT" "$MNT"
        rsync ${VERBOSE:+-v} --rsync-path="sudo rsync" -e "$REMOTE_CMD" --delete -arz "$RSYNC_HOST""$MNT"/ $TARGET/$TAG/ 
        $REMOTE sudo umount $MNT
    fi
done <$TARGET/lsblk.txt
$REMOTE sudo rm -rf /tmp/mnt-$$/



