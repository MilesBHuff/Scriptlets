#!/usr/bin/env bash
## Copyright © by Miles Bradley Huff from 2016-2021 the LGPL3 (the Third Lesser GNU Public License)

## Get system info and declare variables
## #####################################################################

## Get the disks
## =====================================================================
echo ':: Checking disks...'
declare -a DISKS=("$@")
declare -i I=0
while [[ true ]]; do
	if [[ $I -ge 2 ]]; then
		read -p 'Add more disks? (y/N) ' ANSWER
		[[ "$ANSWER" != 'y' && "$ANSWER" != 'Y' ]] && break;
	fi

	while [[ true ]]; do
		if [[ -z "${DISKS[$I]}" ]]; then
			read -p "Path to disk #$I: " DISKS[$I]
		fi

		if [[ -e "${DISKS[$I]}" ]]; then
			let '++I'
			break
		else
			echo "Invalid disk: '${DISKS[$I]}'." >&2
			DISKS[$I]=
		fi
	done
done
declare -i DISK_COUNT=$I
unset I

## System information
## =====================================================================
set -e ## Fail the whole script if any command within it fails.
echo ':: Gathering information...'

## Integer divions with rounding
## ---------------------------------------------------------------------
function rounded_integer_division {
	echo "($1 + ($2 / 2)) / $2" | bc
}

## Basic stuff
## ---------------------------------------------------------------------
declare -i     NPROC=$(nproc)
declare -i  PAGESIZE=$(getconf PAGESIZE)
declare -i BLOCKSIZE=$(($PAGESIZE*256)) ## 1M with a 4k pagesize.  Idk if this should be dependent on pagesize.
declare -i   MEM_SIZE=$(free -b | grep 'Mem:' | sed -r 's/^Mem:\s*([0-9]+).*$/\1/')

## Figure out which drives are SSDs and which are HDDS, so we can use the right mount options.
## ---------------------------------------------------------------------
declare -a DISK_TYPES
declare -i I=0
while [[ $I -lt $DISK_COUNT ]]; do
	DISKINFO=$(echo "${DISKS[$I]}" | sed 's/\/dev\///')/queue/rotational
	if [[ -f "$DISKINFO" ]]; then
		DISK_TYPES[$I]=$(cat "/sys/block/$DISKINFO")
	else
		DISK_TYPES[$I]=0
	fi
	[[ "${DISK_TYPES[$I]}" != "${DISK_TYPES[$(($I-1))]}" ]] && echo 'I refuse to make a RAID of SSDs and HDDs mixed together.' && exit 1
	let '++I'
done
unset I
[[ ${DISK_TYPES[0]} -eq 0 ]] && SSD=1 || SSD=
unset DISK_TYPES

## Figure out which drives are NVME and which are SATA, so we can know whether to use namespaces
## ---------------------------------------------------------------------
if [[ $SSD ]]; then
	declare -a DISK_TYPES
	declare -i I=0
	while [[ $I -lt $DISK_COUNT ]]; do
		DISK_TYPES[$I]=$(if [[ "${DISKS[$I]}" = *'nvme'* ]]; then echo '1'; else echo '0'; fi)
		[[ "${DISK_TYPES[$I]}" != "${DISK_TYPES[$(($I-1))]}" ]] && echo 'I refuse to make a RAID of NVMe and SATA drives mixed together.' && exit 1
		let '++I'
	done
	unset I
	[[ ${DISK_TYPES[0]} -eq 1 ]] && NVME=1 || NVME=
	unset DISK_TYPES
	[[ $NVME ]] && PART_LABEL='p' || PART_LABEL=
fi

## Many NVMe drives, unfortunately, do not support namespace management.
## We need to check each drive, and if any do not support namespaces, we need to avoid their use.
## ---------------------------------------------------------------------
if [[ $NVME ]]; then
	USE_NAMESPACES=1
	for DISK in "${DISKS[@]}"; do
		if [[ $(nvme id-ctrl "$DISK" -H | grep 'NS Management') == *'Not Supported'* ]]; then
			USE_NAMESPACES=
			break
		fi
	done
	for DISK in "${DISKS[@]}"; do
		NAMESPACE=$(echo "$DISK" | sed -r 's/^.+nvme[0-9]+(n[0-9]+)?.*$/\1/')
		if [[ $USE_NAMESPACES  ]]; then
			if [[ "$NAMESPACE" ]]; then
				echo 'Please do not include the namespace when specifying an NVMe!' >&2
				exit 1
			fi
		else
			if [[ -z "$NAMESPACE" ]]; then
				echo 'Please include the namespace when specifying an NVMe!' >&2
				exit 1
			fi
		fi
	done
	unset NAMESPACE
fi

## RAID1s have to be based on the size of the smallest disk in the array.
## ---------------------------------------------------------------------
declare -i SMALLEST_DISK_SIZE=0
for DISK in ${DISKS[@]}; do
	if [[ $NVME && $USE_NAMESPACES ]]; then
		declare -i SIZE=$(nvme id-ctrl "${DISKS[$I]}" | grep nvmcap | sed -r 's/^[tu]nvmcap.*?: //gm' | xargs | sed 's/ /+/' | bc)
	else
		# declare -i SIZE=$(fdisk -l "${DISKS[$I]}" | sed -r 's/^Disk .*? (\d+) bytes, [\s\S]*$/\1/') ## Would work if `sed` didn't suck.
		declare -i SIZE=$(fdisk -l "${DISKS[$I]}" | grep Disk | grep sectors | sed -r 's/^.*? ([0-9]+) bytes.*$/\1/' | xargs)
	fi
	[[ $SSD && $USE_NAMESPACES ]] && SIZE=$(rounded_integer_division $(($SIZE * 9)) 10) ## SSDs should be over-provisioned.
	[[ $SMALLEST_DISK_SIZE -eq 0 || $SIZE -lt $SMALLEST_DISK_SIZE ]] && SMALLEST_DISK_SIZE=$SIZE
done

## Partition sizes
## ---------------------------------------------------------------------
declare -i START_SIZE=2048 ## The standard amount of space before partitions
declare -i   ESP_SIZE=$((500*1024*1024)) ## 500MB/477MiB is the recommended size for the EFI partition when used as /boot (https://www.freedesktop.org/wiki/Specifications/BootLoaderSpec)
#declare -i SWAP_SIZE=$(rounded_integer_division  "$MEM_SIZE"       "$DISK_COUNT") ## We need at least as much swap as memory if we want to hibernate.
declare -i  SWAP_SIZE=$(rounded_integer_division "($MEM_SIZE * .2)" "$DISK_COUNT") ## If we don't want to hibernate, we can just do 20% of RAM (Red Hat recommendation).
declare -i  ROOT_SIZE=$(($SMALLEST_DISK_SIZE-$SWAP_SIZE-$ESP_SIZE))

## Unset unneeded variables
## ---------------------------------------------------------------------
unset SMALLEST_DISK_SIZE MEM_SIZE

## Formatting settings
## ---------------------------------------------------------------------
MAKE_VFAT_OPTS=''
	MAKE_VFAT_OPTS="$MAKE_VFAT_OPTS -F 32" ## Fat size (32)
	MAKE_VFAT_OPTS="$MAKE_VFAT_OPTS -b  6"
	MAKE_VFAT_OPTS="$MAKE_VFAT_OPTS -f  1"
	MAKE_VFAT_OPTS="$MAKE_VFAT_OPTS -h  6"
#	MAKE_VFAT_OPTS="$MAKE_VFAT_OPTS -r 512"
	MAKE_VFAT_OPTS="$MAKE_VFAT_OPTS -R 12"
	MAKE_VFAT_OPTS="$MAKE_VFAT_OPTS -s  1"
	MAKE_VFAT_OPTS="$MAKE_VFAT_OPTS -S $PAGESIZE"
MAKE_ZPOOL_OPTS=''
	## Geometry
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -o ashift=12"        ## ashift=12 is 4096, appropriate for Advanced Format drives, which is basically everything these days.
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O recordsize=1M"    ## The maximum size of a record.  The higher it is, the more-effective compression is;  and the less metadata is needed.
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O compression=zstd" ## Compression improves IO performance and increases available storage, at the cost of a small amount of CPU.  ZSTD is currently the best all-round compression algorithm.
	## Caching
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O primarycache=metadata" ## Saves memory.
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O secondarycache=all"    ## In conjunction with the above, helps with performance.
	## ACLs
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O acltype=posixacl"       ## Required for `journald`
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O aclinherit=passthrough" ## Doesn't affect POSIX ACLs, but can be needed for non-POSIX ones to work as intended.
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O aclmode=passthrough"    ## Setting is supposedly ignored by ZoL.
	## xattrs
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O xattr=sa"       ## Helps performance, but makes xattrs Linux-specific.
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O dnodesize=auto" ## Helpful when using xattr=sa
	## Metadata
	[[ $DISK_COUNT -gt 1 ]] && MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O redundant_metadata=most" ## We can skimp out here a little bit if we're using a RAID array.
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O checksum=skein" ## Helps performance and security relative to the default, which is "fletcher4",
	## Performance
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O relatime=on"     ## A classic Linuxy alternative to `atime`
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O logbias=latency" ## Correct setting for PCs.
	## Encryption
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O encryption=on"
	MAKE_ZPOOL_OPTS="$MAKE_ZPOOL_OPTS -O keyformat=passphrase"

## Mount options
## ---------------------------------------------------------------------
MOUNTPOINT='/mnt'
MOUNT_ANY_OPTS='default'
	MOUNT_ANY_OPTS="$MOUNT_ANY_OPTS,auto"
	MOUNT_ANY_OPTS="$MOUNT_ANY_OPTS,rw"
	MOUNT_ANY_OPTS="$MOUNT_ANY_OPTS,async"
	MOUNT_ANY_OPTS="$MOUNT_ANY_OPTS,iversion"
	MOUNT_ANY_OPTS="$MOUNT_ANY_OPTS,nodiratime"
	MOUNT_ANY_OPTS="$MOUNT_ANY_OPTS,relatime,"
	MOUNT_ANY_OPTS="$MOUNT_ANY_OPTS,strictatime"
	MOUNT_ANY_OPTS="$MOUNT_ANY_OPTS,lazytime"
#	MOUNT_ANY_OPTS="$MOUNT_ANY_OPTS,mand"
MOUNT_VFAT_OPTS="$MOUNT_ANY_OPTS"
	MOUNT_VFAT_OPTS="$MOUNT_VFAT_OPTS,check=relaxed"
	MOUNT_VFAT_OPTS="$MOUNT_VFAT_OPTS,errors=remount-ro"
#	MOUNT_VFAT_OPTS="$MOUNT_VFAT_OPTS,iocharset=utf8"
	MOUNT_VFAT_OPTS="$MOUNT_VFAT_OPTS,tz=UTC"
	MOUNT_VFAT_OPTS="$MOUNT_VFAT_OPTS,rodir"
	MOUNT_VFAT_OPTS="$MOUNT_VFAT_OPTS,sys_immutable"
	MOUNT_VFAT_OPTS="$MOUNT_VFAT_OPTS,flush"
unset MOUNT_ANY_OPTS

## Names & labels
## ---------------------------------------------------------------------
PART_NAME_ROOT='LINUX'
PART_NAME_BOOT='ESP'
PART_NAME_SWAP='SWAP'
ZPOOL='linux'
ZROOT="$ZPOOL"

## Prepare system
## #####################################################################

## Destroy existing ZFS structures
## =====================================================================
function zap_zfs {
	set +e
	zpool destroy -f "$ZPOOL" 2>&1 >/dev/null
	set -e
}

## Unmount the disks
## =====================================================================
echo ':: Making sure the disks are not mounted...'
set +e ## It's okay if this section fails
for DISK in ${DISKS[@]}; do
	for EACH in "$DISK"*; do
		umount  "$EACH" 2>/dev/null
		swapoff "$EACH" 2>/dev/null
	done
done
set -e ## Back to failing the script like before

## Repartition the disks
## =====================================================================
read -p ':: Partition the disks? (y/N) ' INPUT
if [[ "$INPUT" = 'y' || "$INPUT" = 'Y' ]]; then
	zap_zfs
	for DISK in "${DISKS[@]}"; do
		echo "Partitioning '${DISK}'..."

		## Partition disks (with namespaces)
		## ---------------------------------------------------------------------
		if [[ $NVME && $USE_NAMESPACES ]]; then

			## Wipe out old namespaces
			declare -i I=1
			while true; do
				[[ ! -e "${DISK}n$I" ]] && break
				nvme detach-ns -n $I "$DISK"
				nvme delete-ns -n $I "$DISK"
				let '++I'
			done
			unset I

			## ZFS prefers whole disks;  NVMe drives have namespaces, which allow us to do exactly this, while compromising on nothing.
			nvme create-ns -b 4096 -s $(($START_SIZE + $ESP_SIZE + $SWAP_SIZE)) "$DISK"
			nvme attach-ns -n 1 "$DISK"
			DISK_N1="${DISK}n1"
			nvme create-ns -b 4096 -s $(($START_SIZE + $ROOT_SIZE)) "$DISK"
			nvme attach-ns -n 2 "$DISK"
			DISK_N2="${DISK}n2"

			(	echo 'o' ## Create a new GPT partition table
				echo 'Y' ## Confirm

				echo 'n'                          ## Create a new partition
				echo ''                           ## Use the default partition number (1)
				echo "$START_SIZE"                ## Choose the default start location (2048)
				echo "+$(rounded_integer_division $ESP_SIZE $((1024 * 1024)))M" ## Make it as large as $ESP_SIZE
				echo 'ef00'                       ## Declare it to be a UEFI partition
				echo 'c'                          ## Change a partition's name
				echo "$PART_NAME_BOOT"            ## The name of the partition

				echo 'n'               ## Create a new partition
				echo '2'               ## Choose the partition number
				echo ''                ## Choose the default start location (where the last partition ended)
				echo ''                ## Choose the default end location   (the end of the disk)
				echo '8200'            ## Declare it to be a Linux x86-64 swap partition
				echo 'c'               ## Change a partition's name
				echo '2'               ## The partition whose name to change
				echo "$PART_NAME_SWAP" ## The name of the partition

				echo 'w' ## Write the changes to disk
				echo 'Y' ## Confirm
			) | gdisk "$DISK_N1" 1>/dev/null

			(	echo 'n'               ## Create a new partition
				echo '1'               ## Choose the partition number
				echo "$START_SIZE"     ## Choose the default end location   (the end of the disk)
				echo ''                ## Make it as large as $ROOT_SIZE
				echo 'bf00'            ## Declare it to be a Solaris root partition
				echo 'c'               ## Change a partition's name
				echo '1'               ## The partition whose name to change
				echo "$PART_NAME_ROOT" ## The name of the partition

				echo 'w' ## Write the changes to disk
				echo 'Y' ## Confirm
			) | gdisk "$DISK_N2" 1>/dev/null

			unset DISK_N1 DISK_N2

		## Partition disks (without namespaces)
		## ---------------------------------------------------------------------
		else
			sgdisk --zap-all "$DISK" 2>&1 >/dev/null
			nvme format -fb 4096 "$DISK" 2>&1 >/dev/null

			(	echo 'o' ## Create a new GPT partition table
				echo 'Y' ## Confirm

				echo 'n'               ## Create a new partition
				echo ''                ## Use the default partition number (1)
				echo "$START_SIZE"     ## Choose the default start location (2048)
				echo "+$(rounded_integer_division $ESP_SIZE $((1024 * 1024)))M" ## Make it as large as $ESP_SIZE
				echo 'ef00'            ## Declare it to be a UEFI partition
				echo 'c'               ## Change a partition's name
				echo "$PART_NAME_BOOT" ## The name of the partition

				echo 'n'               ## Create a new partition
				echo '2'               ## Choose the partition number
				echo ''                ## Choose the default start location (where the last partition ended)
				echo "+$(rounded_integer_division $ROOT_SIZE $((1024 * 1024 * 1024)))G" ## Make it as large as $ROOT_SIZE
				echo 'bf00'            ## Declare it to be a Solaris root partition
				echo 'c'               ## Change a partition's name
				echo '2'               ## The partition whose name to change
				echo "$PART_NAME_ROOT" ## The name of the partition

				echo 'n'               ## Create a new partition
				echo '3'               ## Choose the partition number
				echo ''                ## Choose the default start location (where the last partition ended)
				echo ''                ## Choose the default end location   (the end of the disk)
				echo '8200'            ## Declare it to be a Linux x86-64 swap partition
				echo 'c'               ## Change a partition's name
				echo '3'               ## The partition whose name to change
				echo "$PART_NAME_SWAP" ## The name of the partition

				echo 'w' ## Write the changes to disk
				echo 'Y' ## Confirm
			) | gdisk "$DISK" 1>/dev/null
		fi
	done
	sleep 1

	## Refresh disks
	## ---------------------------------------------------------------------
	echo 'Refreshing devices...'
	set +e ## It's okay if this section fails
	partprobe
	sleep 1
	set -e ## Back to failing the script like before

fi

## Reformat the disks
## =====================================================================
read -p ':: Format the disks? (y/N) ' INPUT
if [[ "$INPUT" = 'y' || "$INPUT" = 'Y' ]]; then
	[[ $USE_NAMESPACES ]] && echo 'NVMe namespaces not implemented!' >&2 && exit 1
	zap_zfs

	## Format partitions
	## ---------------------------------------------------------------------
	for DISK in "${DISKS[@]}"; do
		echo "Formatting disk '${DISK}'..."
		mkfs.vfat  $MAKE_VFAT_OPTS -n  "$ESP_NAME" "${DISK}${PART_LABEL}1" 2>&1 >/dev/null
		mkswap -p "$PAGESIZE"      -L "$SWAP_NAME" "${DISK}${PART_LABEL}3" 2>&1 >/dev/null
	done
	unset MAKE_VFAT_OPTS

	## Create zpool
	## ---------------------------------------------------------------------
	echo "Creating RAID volume..."
	declare -a POOL_PARTS
	declare -i I=0
	while [[ $I -lt $DISK_COUNT ]]; do
		POOL_PARTS[$I]=${DISKS[$I]}${PART_LABEL}2
		let '++I'
	done
	unset I
	zpool create "$ZPOOL" -f $MAKE_ZPOOL_OPTS -O 'canmount=noauto' -R "$MOUNTPOINT" -m '/' mirror "${POOL_PARTS[@]}"

	## Create datasets
	## ---------------------------------------------------------------------
	echo 'Creating datasets...'
	zfs create -o 'mountpoint=/home'                    "$ZROOT/home"
	zfs create -o 'mountpoint=/usr' -o 'encryption=off' "$ZROOT/usr"
fi

## Prepare for Linux
## =====================================================================----

## Prepare ZFS
## -----------------------------------------------------------------
read -p ':: Configure ZFS? (y/N) ' INPUT
if [[ "$INPUT" = 'y' || "$INPUT" = 'Y' ]]; then
	echo 'Configuring ZFS...'
	zfs umount -a
	zpool set bootfs="$ZROOT" "$ZPOOL"
	zpool export "$ZPOOL"
	zpool import -R "$MOUNTPOINT" "$ZPOOL"
	zfs load-key "$ZPOOL"
	zfs mount "$ZROOT"
	zfs mount -a
fi

## Do first mounts
## -----------------------------------------------------------------
read -p ':: Test mounts? (y/N) ' INPUT
if [[ "$INPUT" = 'y' || "$INPUT" = 'Y' ]]; then
	echo 'Trialling mounts...'

	[[ $USE_NAMESPACES ]] && NAMESPACE='n1'
	mkdir -p "$MOUNTPOINT/boot"

	set +e #FIXME: This section shouldn't be failing.
	## Mount each boot partition at least once, and Keep the 0-index one mounted
	declare -i I=$DISK_COUNT
	while [[ $I -gt 0 ]]; do
		mount -t vfat -o "$MOUNT_VFAT_OPTS" "${DISK}${NAMESPACE}${PART_LABEL}1" "$MOUNTPOINT/boot"
		[[ ! $I -eq 0 ]] && umount "$MOUNTPOINT/boot"
		let '--I'
	done
	unset I
	set -e

	## Activate all the swap partitions
	for DISK in "${DISKS[@]}"; do
		swapon "${DISK}${NAMESPACE}${PART_LABEL}3"
	done

fi

## Wrap things up
## ---------------------------------------------------------------------
echo ':: Done.'
exit 0
