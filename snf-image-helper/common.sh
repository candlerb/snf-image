# Copyright (C) 2011, 2012, 2013 GRNET S.A.
# Copyright (C) 2007, 2008, 2009 Google Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.

PROGNAME=$(basename $0)

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

# Programs
XMLSTARLET=xmlstarlet
TUNE2FS=tune2fs
RESIZE2FS=resize2fs
PARTED=parted
SFDISK=sfdisk
MKSWAP=mkswap
BLKID=blkid
BLOCKDEV=blockdev
REGLOOKUP=reglookup
CHNTPW=chntpw
SGDISK=sgdisk
GROWFS_UFS=growfs.ufs
DATE="date -u" # Time in UTC
EATMYDATA=eatmydata
MOUNT="mount -n"

CLEANUP=( )
ERRORS=( )
WARNINGS=( )

MSG_TYPE_TASK_START="TASK_START"
MSG_TYPE_TASK_END="TASK_END"

STDERR_LINE_SIZE=10

add_cleanup() {
    local cmd=""
    for arg; do cmd+=$(printf "%q " "$arg"); done
    CLEANUP+=("$cmd")
}

close_fd() {
    local fd=$1

    exec {fd}>&-
}

send_result_kvm() {
    echo "$@" > /dev/ttyS1
}

send_monitor_message_kvm() {
    echo "$@" > /dev/ttyS2
}

send_result_xen() {
    xenstore-write /local/domain/0/snf-image-helper/$DOMID "$*"
}

send_monitor_message_xen() {
    #Broadcast the message
    echo "$@" | socat "STDIO" "UDP-DATAGRAM:${BROADCAST}:${MONITOR_PORT},broadcast"
}

prepare_helper() {
	local cmdline item key val hypervisor domid

	read -a cmdline	 < /proc/cmdline
	for item in "${cmdline[@]}"; do
            key=$(cut -d= -f1 <<< "$item")
            val=$(cut -d= -f2 <<< "$item")
            if [ "$key" = "hypervisor" ]; then
                hypervisor="$val"
            fi
            if [ "$key" = "rules_dev" ]; then
                export RULES_DEV="$val"
            fi
            if [ "$key" = "helper_ip" ]; then
                export IP="$val"
                export NETWORK="$IP/24"
                export BROADCAST="${IP%.*}.255"
            fi
            if [ "$key" = "monitor_port" ]; then
                export MONITOR_PORT="$val"
            fi
	done

    case "$hypervisor" in
    kvm)
        HYPERVISOR=kvm
        ;;
    xen-hvm|xen-pvm)
        if [ -z "$IP" ]; then
            echo "ERROR: \`helper_ip' not defined or empty" >&2
            exit 1
        fi
        if [ -z "$MONITOR_PORT" ]; then
            echo "ERROR: \`monitor_port' not defined or empty" >&2
            exit 1
        fi
        $MOUNT -t xenfs xenfs /proc/xen
        ip addr add "$NETWORK" dev eth0
        ip link set eth0 up
        ip route add default dev eth0
        export DOMID=$(xenstore-read domid)
        HYPERVISOR=xen
        ;;
    *)
        echo "ERROR: Unknown hypervisor: \`$hypervisor'" >&2
        exit 1
        ;;
    esac

    export HYPERVISOR
}

report_error() {
    msg=""
    if [ ${#ERRORS[*]} -eq 0 ]; then
        # No error message. Print stderr
        local lines
        lines=$(tail --lines=${STDERR_LINE_SIZE} "$STDERR_FILE" | wc -l)
        msg="STDERR:${lines}:"
        msg+=$(tail --lines=$lines  "$STDERR_FILE")
    else
        for line in "${ERRORS[@]}"; do
            msg+="ERROR:$line"$'\n'
        done
    fi

    send_monitor_message_${HYPERVISOR} "$msg"
}

log_error() {
    ERRORS+=("$*")

    send_monitor_message_${HYPERVISOR} "ERROR: $@"
    send_result_${HYPERVISOR} "ERROR: $@"

    # Use return instead of exit. The set -x options will terminate the script
    # but will also trigger ERR traps if defined.
    return 1
}

warn() {
    echo "Warning: $@" >&2
    send_monitor_message_${HYPERVISOR} "WARNING: $@"
}

report_task_start() {
    send_monitor_message_${HYPERVISOR} "$MSG_TYPE_TASK_START:${PROGNAME:2}"
}

report_task_end() {
    send_monitor_message_${HYPERVISOR} "$MSG_TYPE_TASK_END:${PROGNAME:2}"
}

system_poweroff() {
    while [ 1 ]; do
        # Credits to psomas@grnet.gr for this ...
        echo o > /proc/sysrq-trigger
        sleep 1
    done
}

get_base_distro() {
    local root_dir=$1

    if [ -e "$root_dir/etc/debian_version" ]; then
        echo "debian"
    elif [ -e "$root_dir/etc/redhat-release" ]; then
        echo "redhat"
    elif [ -e "$root_dir/etc/slackware-version" ]; then
        echo "slackware"
    elif [ -e "$root_dir/etc/SuSE-release" ]; then
        echo "suse"
    elif [ -e "$root_dir/etc/gentoo-release" ]; then
        echo "gentoo"
    elif [ -e "$root_dir/etc/arch-release" ]; then
        echo "arch"
    elif [ -e "$root_dir/etc/freebsd-update.conf" ]; then
        echo "freebsd"
    else
        warn "Unknown base distro."
    fi
}

get_distro() {
    local root_dir distro
    root_dir=$1

    if [ -e "$root_dir/etc/debian_version" ]; then
        distro="debian"
        if [ -e ${root_dir}/etc/lsb-release ]; then
            ID=$(grep ^DISTRIB_ID= ${root_dir}/etc/lsb-release | cut -d= -f2)
            if [ "x$ID" = "xUbuntu" ]; then
                distro="ubuntu"
            fi
        fi
        echo "$distro"
    elif [ -e "$root_dir/etc/fedora-release" ]; then
        echo "fedora"
    elif [ -e "$root_dir/etc/centos-release" ]; then
        echo "centos"
    elif [ -e "$root_dir/etc/redhat-release" ]; then
        echo "redhat"
    elif [ -e "$root_dir/etc/slackware-version" ]; then
        echo "slackware"
    elif [ -e "$root_dir/etc/SuSE-release" ]; then
        echo "suse"
    elif [ -e "$root_dir/etc/gentoo-release" ]; then
        echo "gentoo"
    elif [ -e "$root_dir/etc/arch-release" ]; then
        echo "arch"
    elif [ -e "$root_dir/etc/freebsd-update.conf" ]; then
        echo "freebsd"
    else
        warn "Unknown distro."
    fi
}


get_partition_table() {
    local dev output
    dev="$1"
    # If the partition table is gpt then parted will raise an error if the
    # secondary gpt is not it the end of the disk, and a warning that has to
    # do with the "Last Usable LBA" entry in gpt.
    if ! output="$("$PARTED" -s -m "$dev" unit s print | grep -E -v "^(Warning|Error): ")"; then
        log_error "Unable to read partition table for device \`${dev}'. The image seems corrupted."
    fi

    echo "$output"
}

get_partition_table_type() {
    local ptable dev field
    ptable="$1"

    dev="$(sed -n 2p <<< "$ptable")"
    IFS=':' read -ra field <<< "$dev"

    echo "${field[5]}"
}

get_partition_count() {
    local ptable="$1"

    expr $(echo "$ptable" | wc -l) - 2
}

get_partition_by_num() {
    local ptable="$1"
    local id="$2"

    grep "^$id:" <<< "$ptable"
}

get_last_partition() {
    local ptable="$1"

    echo "$ptable" | tail -1
}

is_extended_partition() {
    local dev="$1"
    local part_num="$2"

    id=$($SFDISK --force --print-id "$dev" "$part_num")
    if [ "$id" = "5" -o "$id" = "f" ]; then
        echo "yes"
    else
        echo "no"
    fi
}

get_extended_partition() {
    local ptable dev
    ptable="$1"
    dev="$(echo "$ptable" | sed -n 2p | cut -d':' -f1)"

    tail -n +3 <<< "$ptable" | while read line; do
        part_num=$(cut -d':' -f1 <<< "$line")
        if [ $(is_extended_partition "$dev" "$part_num") == "yes" ]; then
            echo "$line"
            return 0
        fi
    done
    echo ""
}

get_logical_partitions() {
    local ptable part_num
    ptable="$1"

    tail -n +3 <<< "$ptable" | while read line; do
        part_num=$(cut -d':' -f1 <<< "$line")
        if [ $part_num -ge 5 ]; then
            echo "$line"
        fi
    done

    return 0
}

get_last_primary_partition() {
    local ptable dev output
    ptable="$1"
    dev=$(echo "ptable" | sed -n 2p | cut -d':' -f1)

    for i in 4 3 2 1; do
        if output=$(grep "^$i:" <<< "$ptable"); then
            echo "$output"
            return 0
        fi
    done
    echo ""
}

get_partition_to_resize() {
    local dev table table_type last_part last_part_num extended last_primary \
        ext_num prim_num
    dev="$1"

    table=$(get_partition_table "$dev")

    if [ $(get_partition_count "$table") -eq 0 ]; then
        return 0
    fi

    table_type=$(get_partition_table_type "$table")
    last_part=$(get_last_partition "$table")
    last_part_num=$(cut -d: -f1 <<< "$last_part")

    if [ "$table_type" == "msdos" -a $last_part_num -gt 4 ]; then
        extended=$(get_extended_partition "$table")
        last_primary=$(get_last_primary_partition "$table")
        ext_num=$(cut -d: -f1 <<< "$extended")
        last_prim_num=$(cut -d: -f1 <<< "$last_primary")

        if [ "$ext_num" != "$last_prim_num" ]; then
            echo "$last_prim_num"
        else
            echo "$last_part_num"
        fi
    else
        echo "$last_part_num"
    fi
}

create_partition() {
    local device="$1"
    local part="$2"
    local ptype="$3"

    local fields=()
    IFS=":;" read -ra fields <<< "$part"
    local id="${fields[0]}"
    local start="${fields[1]}"
    local end="${fields[2]}"
    local size="${fields[3]}"
    local fs="${fields[4]}"
    local name="${fields[5]}"
    local flags="${fields[6]//,/ }"

    if [ "$ptype" = "primary" -o "$ptype" = "logical" -o "$ptype" = "extended" ]; then
        $PARTED -s -m -- $device mkpart "$ptype" $fs "$start" "$end"
        for flag in $flags; do
            $PARTED -s -m $device set "$id" "$flag" on
        done
    else
        # For gpt
        start=${start:0:${#start}-1} # remove the s at the end
        end=${end:0:${#end}-1} # remove the s at the end
        $SGDISK -n "$id":"$start":"$end" -t "$id":"$ptype" "$device"
    fi
}

enlarge_partition() {
    local device part ptype new_end fields new_part table logical id
    device="$1"
    part="$2"
    ptype="$3"
    new_end="$4"

    if [ -z "$new_end" ]; then
        new_end=$(cut -d: -f 3 <<< "$(get_last_free_sector "$device")")
    fi

    fields=()
    IFS=":;" read -ra fields <<< "$part"
    fields[2]="$new_end"

    new_part=""
    for ((i = 0; i < ${#fields[*]}; i = i + 1)); do
        new_part="$new_part":"${fields[$i]}"
    done
    new_part=${new_part:1}

    # If this is an extended partition, removing it will also remove the
    # logical partitions it contains. We need to save them for later.
    if [ "$ptype" = "extended" ]; then
        table="$(get_partition_table "$device")"
        logical="$(get_logical_partitions "$table")"
    fi

    id=${fields[0]}
    $PARTED -s -m "$device" rm "$id"
    create_partition "$device" "$new_part" "$ptype"

    if [ "$ptype" = "extended" ]; then
        # Recreate logical partitions
        echo "$logical" | while read logical_part; do
            create_partition "$device" "$logical_part" "logical"
        done
    fi
}

get_last_free_sector() {
    local dev unit last_line ptype
    dev="$1"
    unit="$2"

    if [ -n "$unit" ]; then
        unit="unit $unit"
    fi

    last_line="$($PARTED -s -m "$dev" "$unit" print free | tail -1)"
    ptype="$(cut -d: -f 5 <<< "$last_line")"

    if [ "$ptype" = "free;" ]; then
        echo "$last_line"
    fi
}

get_unattend() {
    local target exists
    target="$1"

    # Workaround to search for $target/Unattend.xml in an case insensitive way.
    exists=$(find "$target"/ -maxdepth 1 -iname unattend.xml)
    if [ $(wc -l <<< "$exists") -gt 1 ]; then
        log_error "Found multiple Unattend.xml files in the image:" $exists
    fi

    echo "$exists"
}

umount_all() {
    local target mpoints
    target="$1"

    # Unmount file systems mounted under directory `target'
    mpoints="$({ awk "{ if (match(\$2, \"^$target\")) { print \$2 } }" < /proc/mounts; } | sort -rbd | uniq)"

    for mpoint in $mpoints; do
        umount $mpoint
    done
}

cleanup() {
    # if something fails here, it shouldn't call cleanup again...
    trap - EXIT

    if [ ${#CLEANUP[*]} -gt 0 ]; then
        LAST_ELEMENT=$((${#CLEANUP[*]}-1))
        REVERSE_INDEXES=$(seq ${LAST_ELEMENT} -1 0)
        for i in $REVERSE_INDEXES; do
            # If something fails here, it's better to retry it for a few times
            # before we give up with an error. This is needed for kpartx when
            # dealing with ntfs partitions mounted through fuse. umount is not
            # synchronous and may return while the partition is still busy. A
            # premature attempt to delete partition mappings through kpartx on
            # a device that hosts previously mounted ntfs partition may fail
            # with a `device-mapper: remove ioctl failed: Device or resource
            # busy' error. A sensible workaround for this is to wait for a
            # while and then try again.
            local cmd=${CLEANUP[$i]}
            $cmd || for interval in 0.25 0.5 1 2 4; do
            echo "Command $cmd failed!"
            echo "I'll wait for $interval secs and will retry..."
            sleep $interval
            $cmd && break
        done
	if [ "$?" != "0" ]; then
            echo "Giving Up..."
            exit 1;
        fi
    done
  fi
}

task_cleanup() {
    local rc=$?

    if [ $rc -eq 0 ]; then
       report_task_end
    else
       report_error
    fi

    cleanup
}

check_if_excluded() {
    local name exclude
    name="$(tr [a-z] [A-Z] <<< ${PROGNAME:2})"
    exclude="SNF_IMAGE_PROPERTY_EXCLUDE_TASK_${name}"
    if [ -n "${!exclude}" ]; then
        warn "Task ${PROGNAME:2} was excluded and will not run."
        exit 0
    fi

    return 0
}


return_success() {
    send_result_${HYPERVISOR} "SUCCESS"
}

trap cleanup EXIT
set -o pipefail

STDERR_FILE=$(mktemp)
add_cleanup rm -f "$STDERR_FILE"
exec 2> >(tee -a "$STDERR_FILE" >&2)

# vim: set sta sts=4 shiftwidth=4 sw=4 et ai :
