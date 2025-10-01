#!/bin/bash
# dev_utils.sh
# Depends on: common.sh
# Usage: source dev_utils.sh and deps, in any order.
[[ -n "${DEV_UTILS_SH_INCLUDED:-}" ]] && return
DEV_UTILS_SH_INCLUDED=1

# ----------------------------------------------------------------------
# Usage: find_devices
# Purpose: Detect removable USB block devices with write permission
#          and fill the associative array.
# Parameters: none (relies on state runtime variables)
# Variables used/set:
#   removable_devices[] – associative array populated by this function.
# Returns: nothing (populates the global array).
# ----------------------------------------------------------------------
find_devices() {
   local line label
   local NAME TYPE TRAN RM RO VENDOR MODEL
   removable_devices=()

   log i "Looking for connected devices."
   while read -r line; do
      eval "$line"

      # check if it'a an usb disk, removable and write permissive
      [[ $TYPE == 'disk' ]] || continue
      [[ $TRAN == 'usb' ]] || continue
      (( RM == 1 )) || continue
      (( RO == 0 )) || continue

      # Sanitize: collapse whitespace in vendor/model string
      label="$(printf '%s %s' "$VENDOR" "$MODEL" | tr -s '[:space:]' ' ')"
      removable_devices["/dev/${NAME}"]="$label"
   done < <(lsblk -Pn -o NAME,TYPE,TRAN,RM,RO,VENDOR,MODEL)

   # Check if we have found any devices
   if [[ ${#removable_devices[@]} -eq 0 ]]; then
      message="No removable USB devices found."
      log i "${message}"
   else
      message="Choose a removable USB device:"
      log i "Found devices -> ${!removable_devices[*]}"
   fi
}

# ----------------------------------------------------------------------
# Usage: set_config_vars
# Purpose: Derive geometry‑related variables (sector size, offset, minimal
#          sizes, partition names...) based on the configuration globals.
# Parameters: none
# Globals used:
#   MiB                – number of bytes in one mebibyte
#   STORAGE_PART_NAME  – dafault GPT partition name for storage partition
#   ESP_PART_NAME      – dafault GPT partition name for esp partition
#   SYSTEM_PART_NAME   – dafault GPT partition name for system partition
#   MIN_STORAGE_SIZE   – minimal size of storage partition
#   MIN_ESP_SIZE       – minimal size of esp partition
#   MIN_SYSTEM_SIZE    – minimal size of system partition
#   MIN_FREE_SIZE      – minimal size of free space
# Variables used/set:
#   part_names[]       – human‑readable GPT labels
#   min_sizes[]        – minimal partition sizes (in megabytes)
# Returns: none
# ----------------------------------------------------------------------
set_config_vars() {
   # gpt partition names
   part_names=("$STORAGE_PART_NAME" "$ESP_PART_NAME" "$SYSTEM_PART_NAME" "free space")

   # define minimal partition sizes in megabytes
   min_sizes=(
      $(( $(numfmt --from=iec-i "$MIN_STORAGE_SIZE") / MiB ))
      $(( $(numfmt --from=iec-i "$MIN_ESP_SIZE") / MiB ))
      $(( $(numfmt --from=iec-i "$MIN_SYSTEM_SIZE") / MiB ))
      $(( $(numfmt --from=iec-i "$MIN_FREE_SIZE") / MiB ))
   )
}

# ----------------------------------------------------------------------
# Usage: set_partition_vars
# Purpose: Derive partition nodes and compute their sizes based on
#          the selected device and the partition flags.      
# Parameters: none
# Variables used/set:
#   device             – selected block device (e.g. /dev/sdb)
#   part_nodes[]       – device node names for each partition (e.g. /dev/sdb1)
#   part_sizes[]       – modified with call to `calculate_sizes`
#   partitions[]       – flags set by dialog `pick_partitions`
# Returns: (same as `calculate_sizes` called at the end)
#   0 – success,
#   1 – error,
# ----------------------------------------------------------------------
set_partition_vars() {
   local index number

   set_config_vars

   part_nodes=('' '' '' '')
   number=1
   # walk through all indices but the last (free space)
   for (( index = 0; index < ${#part_nodes[@]}-1; ++index)); do
      (( partitions[index] )) || continue
      part_nodes[index]="${device}${number}"
      (( ++number ))
   done

   # populate part_sizes with default weights and 50MiB for part 2
   calculate_sizes 2 50 2 1
}

# ----------------------------------------------------------------------
# Usage: calculate_sizes  <w0> <fixed_sz> <w2> <w3>
# Purpose: Compute the size (in megabytes) of each enabled partition based
#          on specified weights and a fixed size for the second partition.
# Parameters:
#   $1 – weight for partition 0 (storage)
#   $2 – absolute size (in megabytes) for partition 1 (EFI) – fixed
#   $3 – weight for partition 2 (system)
#   $4 – weight for partition 3 (free space / persistence)
# Variables used/set:
#   min_sizes[]   – minimal sizes (in megabytes) for each partition
#   partitions[]  – flag array (0 = disabled, 1 = enabled)
#   part_sizes[]  – resulting sizes (in megabytes) for each partition
# Returns:
#   0 – success
#   1 – no flexible partitions enabled (ratio = 0)
#   2 – not enough space for flex partitions (required > available)
# ----------------------------------------------------------------------
calculate_sizes() {
   local available required ratio remainder index

   # calculate available space (in MiB) for flexible partitions,
   # reserve 1MiB at start and end of device
   available=$(( $(blockdev --getsize64 "${device}") / MiB - $2 - 2 ))
   ratio=$(( $1 * partitions[0] + $3 * partitions[2] + $4 * partitions[3] ))

   # sanity checks
   if (( ratio == 0 )); then
      log e "No partitions enabled (ratio = 0)."
      return 1
   fi

   required=0
   for index in 0 2 3; do
      (( partitions[index] )) || continue
      (( required += min_sizes[index] ))
   done
   if (( available < required )); then
      log w "Not enough space for partitions."
      return 2
   fi

   # distribute space according to weights
   part_sizes[0]=$(( $1 * available * partitions[0] / ratio ))
   part_sizes[1]=$(( $2 * partitions[1] ))
   part_sizes[2]=$(( $3 * available * partitions[2] / ratio ))
   part_sizes[3]=$(( $4 * available * partitions[3] / ratio ))

   # distribute any remainder left from integer division
   remainder=$(( available - part_sizes[0] - part_sizes[2] - part_sizes[3] ))
   index=${#partitions[@]}
   while (( remainder > 0 )); do
      if (( partitions[index] && index != 1 )); then
            (( ++part_sizes[index] ))
            (( remainder-- ))
      fi
      (( index = ++index % ${#partitions[@]} ))
   done

   log d "
   available  = ${available} MiB
   ratio      = ${ratio}
   remainder  = ${remainder} MiB
   part_sizes = (${part_sizes[0]}, ${part_sizes[1]}, ${part_sizes[2]}, ${part_sizes[3]})
   sum(flex)  = $((part_sizes[0]+part_sizes[2]+part_sizes[3])) MiB (should equal available)"
}

# ----------------------------------------------------------------------
# Usage: validate_sizes  <size1> <size2> <size3> <size4>
# Purpose: Validate user‑entered IEC size strings, enforce minimum sizes,
#          and adjust the free space if possible. Recalculate sizes if necessary.
# Parameters:
#   $1 $2 $3 $4 – IEC strings supplied by the user for each enabled partition.
#                 (e.g. "2Gi", "500Mi", …)
# Variables used/set:
#   DEBUG         – when set, prints diagnostic messages to stderr.
#   MiB           – 1 MiB in bytes.
#   device        – selected block device (e.g. /dev/sdb)
#   message       – diagnostic/message string displayed later.
#   partitions[]  – flag array.
#   part_sizes[]  – current sizes (MiB).
#   min_sizes[]   – minimal allowed sizes (MiB).
#   part_names[]  – human‑readable names (for messages).
# Returns:
#   0 – all sizes accepted as‑is,
#   2 – sizes were adjusted; caller should treat this as “changes made”.
# ----------------------------------------------------------------------
validate_sizes() {
   local sum index size accepted usable_size status
   local -a new_sizes
   accepted=1

   # assign new_sizes array with user input
   for index in "${!partitions[@]}"; do
      if (( ! partitions[index] )); then
         new_sizes+=(0)
         continue
      fi
      # check if iec strings match
      [[ $1 == $(numfmt --to=iec-i $((part_sizes[index] * MiB))) ]] || accepted=0

      new_sizes+=( $(( $(numfmt --from=iec-i "$1") / MiB )) )
      shift
   done

   log d "
   part_sizes = ${part_sizes[*]}
   new_sizes  = ${new_sizes[*]}
   accepted   = ${accepted}"

   # values were correct and accepted by user
   (( accepted )) && return 0

   # get usable size in MiB (total size - 2MiB for gpt overhead)
   usable_size=$(( $(blockdev --getsize64 "$device") / MiB - 2 ))

   # Check if any new size exceeds usable_size
   for index in "${!new_sizes[@]}"; do
      if (( new_sizes[index] > usable_size )); then
         message+="\Z1${part_names[index]} size exceeded disk space!\Zn\n"
         new_sizes[index]=$(( usable_size / 2 ))
      fi
   done

   # check if sizes are greater than minimum
   for index in "${!new_sizes[@]}"; do
      if (( partitions[index] && new_sizes[index] < min_sizes[index])); then
         message+="\Z1${part_names[index]} was to small!\Zn\n"
         new_sizes[index]=${min_sizes[index]}
      fi
   done

   # calculate sum of partitions' sizes
   sum=0
   for size in "${new_sizes[@]}"; do
      ((sum+=size))
   done

   # if free space was chosen we try to adjust it
   if (( partitions[3] )); then
      if (( sum > usable_size && sum - new_sizes[3] < usable_size - min_sizes[3] )); then
         [[ -z $DEBUG || $DEBUG == 0 ]] || echo "   free space reduced" >&2
         (( new_sizes[3] -= sum - usable_size ))
         sum=$usable_size
      elif (( sum < usable_size )); then
         [[ -z $DEBUG || $DEBUG == 0 ]] || echo "   free space expanded" >&2
         (( new_sizes[3] += usable_size - sum ))
         sum=$usable_size
      fi
   fi

   # new sizes are correct
   if (( sum == usable_size )); then
      message+="\Z2Press next to accept changes.\Zn\n"
      part_sizes=("${new_sizes[@]}")
      return 2
   fi

   # if partitions don't fit recalculate sizes proportionally
   status=0
   # shellcheck disable=SC2068
   calculate_sizes ${new_sizes[@]} || status=$?
   if (( status == 0 )); then
      message+="\Z1Partitions scaled to fit disk size!\Zn\n"
   elif (( status == 2 )); then
      message+="\Z1${part_names[1]} was too big!\Zn\n"
   else
      message+="\Z1Error calculating sizes!\Zn\n"
   fi
   return 2
}

# -------------------------------------------------
# Usage: unmount_device_partitions
# Purpose: Ensures every partition on a given block device is unmounted.
# Parameters: none (relies on globals)
# Variables used/set:
#   device          – the block device (e.g. /dev/sdb)
# Return codes:
#   0 – all partitions were already unmounted or were successfully unmounted
#   1 – one or more partitions could not be unmounted
# -------------------------------------------------
unmount_partitions() {
   local ret part
   ret=0

   # Iterate over each partition and unmount it
   while read -r part; do
      part="/dev/${part}"
      # check if already unmounted
      findmnt "$part" >/dev/null || {
         log d "${part} not mounted"
         continue
      }

      if umount "$part" 2>/dev/null; then
         log i "Unmounted ${part}."
      else
         log w "Failed to unmount ${part}"
         ret=1
      fi
   done < <(lsblk -ln -o NAME "$device")

   return $ret
}

# ----------------------------------------------------------------------
# Usage: assemble_sfdisk_input
# Purpose: Construct complete sfdisk input that describes the
#          partition table to be written to the target device.
# Parameters: none (relies on globals)
# Variables used/set:
#   MiB             – 1 MiB in bytes.
#   device          – the block device (e.g. /dev/sdb)
#   partitions[]    – flags indicating which partitions are enabled
#   part_sizes[]    – sizes of all partitions in megabytes
#   part_names[]    – human‑readable GPT partition labels
#   part_nodes[]    – device node names for each partition (e.g. /dev/sdb1)
# Returns: none (does not return a status code.)
# Side‑Effects: Prints the fully‑assembled sfdisk command to `stdout`.
# ----------------------------------------------------------------------
assemble_sfdisk_input() {
   local start index guid sector_size size

   if ! sector_size="$(blockdev --getss "${device}")"; then
      log e "${device} is inaccessible"
      abort
   fi

   # Start allocating partitions after offset (first MiB)
   start=$(( MiB / sector_size ))

   # tell sfdisk we want a fresh GPT table
   cat << EOF
label: gpt
device: ${device}
unit: sectors
sector-size: ${sector_size}
first-lba: ${start}
last-lba: $(( $(blockdev --getsz "$device") - 34 ))

EOF

   for index in "${!partitions[@]}"; do
      (( partitions[index] )) || continue # skip if flag = 0

      # Choose the proper GPT type GUID
      case $index in
         0) guid="ebd0a0a2-b9e5-4433-87c0-68b6b72699c7" ;; # Microsoft basic data
         1) guid="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ;; # EFI System Partition
         2) guid="0fc63daf-8483-4772-8e79-3d69d8477de4" ;; # Linux filesystem
         3) continue ;; # free space
      esac

      # Convert size from MiB to sectors
      size=$(( part_sizes[index] * MiB / sector_size ))
      # Print the partition definition line
      printf '%s:start=%s,size=%s,type=%s,name="%s"\n' "${part_nodes[$index]}" \
         "$start" "$size" "$guid" "${part_names[$index]}"

      (( start += size ))
   done
}

# ----------------------------------------------------------------------
# Usage: format_device <input> [<noact>]
# Purpose: Apply a partition layout to the target block device using `sfdisk`.  
#          Function builds a command line that feeds supplied input to `sfdisk`.
# Parameters:
#   $1 – A string containing the sfdisk input specification.
#   $2 – Optional mode flag. Value `noact` causes a dry‑run that
#        prints what would be done without modifying the disk.
# Variables used/set:
#   DEBUG   – when set, the command and sfdisk output is print to stderr.
#   device  – the block device to be partitioned (e.g. /dev/sdb).
# Returns: the exit status of the executed `sfdisk` command.
#   0        – Success.
#   non‑zero – Failure. In case of a non‑zero status the function calls
#              `abort`, which terminates the script with status 1.
# Side‑Effects:
#   * Executes the external `sfdisk` program, which writes a new partition
#     table to `$device` (unless `--no-act` is used).
#   * May write sfdisk output to stdout when `$DEBUG` is enabled.
# ----------------------------------------------------------------------
format_device() {
   local input="$1"
   local -a cmd

   cmd=( sfdisk --wipe always --wipe-partitions always "$device" )

   if [[ ${2:-} == 'noact' ]]; then
      cmd+=( --no-act )
      log d "Executing (noact) -> ${cmd[*]}"
      "${cmd[@]}" <"$input" 2>&1
   else
      log i "Executing -> ${cmd[*]}"
      quiet "${cmd[@]}" <"$input"
   fi

   return $?
}

# ----------------------------------------------------------------------
# Usage: make_filesystems
# Purpose: Format each partition that was created with the appropriate
#          filesystem type and label.
# Parameters: none (relies on globals)
# Variables used/set:
#   LABEL_USE_PROPERTY   – specifies what to use as storage filesystem label
#   LABEL_STORAGE        – default storage filesystem label (see config)
#   device               – the target block device (e.g. /dev/sdb)
#   part_nodes[]         – device node names for each partition (e.g. /dev/sdb1)
#   removable_devices[]  – associative array mapping a device path to a
#                          human‑readable label
# Returns: none; any non‑zero exit status from `mkfs.*` will cause the script
#          to terminate via the surrounding `abort` logic.
# Side‑Effects:
#   * Executes external formatting utilities: `mkfs.exfat`, `mkfs.fat` and `mkfs.ext4`
# ----------------------------------------------------------------------
make_filesystems() {
   local index label

   # Prepare storage label according to configuration
   case $LABEL_USE_PROPERTY in
      vendor) label=$(lsblk -lnd -o VENDOR "$device") ;;
      model) label=$(lsblk -lnd -o MODEL "$device") ;;
      *) label=$LABEL_STORAGE ;;
   esac
   label=${label:-$LABEL_STORAGE}

   for index in "${!part_nodes[@]}"; do
      [[ -n ${part_nodes[index]} ]] || continue
      case $index in
         0)
            log i "Creating exFAT filesystem on ${part_nodes[$index]}"
            quiet mkfs.exfat -L "${label::11}" "${part_nodes[$index]}"
            ;; # storage
         1)
            log i "Creating FAT filesystem on ${part_nodes[$index]}"
            quiet mkfs.fat -n 'EFI' "${part_nodes[$index]}"
            ;; # esp
         2)
            log i "Creating ext4 filesystem on ${part_nodes[$index]}"
            quiet mkfs.ext4 -F -L 'casper-rw' "${part_nodes[$index]}"
            ;; # system
         3)
            continue
            ;; # free space
      esac
   done
}

# ----------------------------------------------------------------------
# Usage: detect_target_partitions
# Purpose: Check if preformatted device has EFI partition and `system`
#          partition, populate appropriate variables.
# Parameters: none
# Variables used/set:
#   MiB                – 1 MiB in bytes.
#   device             – selected block device (e.g. /dev/sdb)
#   min_sizes[]        – minimal partition sizes (in megabytes)
#   part_names[]       – human‑readable GPT labels
#   part_nodes[]       – device node names for each partition (e.g. /dev/sdb1)
#   partitions[]       – partition flags set here
# Returns: exit status as a *bitmask* (stored in $ret)
#   0   – both required partitions are present and meet size/type checks
#   1   – EFI partition missing or doesn't meet requirements
#   2   – system partition not detected or too small
#   4   – EFI partition exists but its filesystem is NOT vfat
#   8   – EFI partition smaller than the required minimum
#  16   – system partition smaller than the required minimum
# ----------------------------------------------------------------------
detect_target_partitions() {
   local line ret
   local NAME TYPE PARTTYPE PARTLABEL FSTYPE SIZE
   ret=0

   set_config_vars
   partitions=(0 0 0 0)
   part_nodes=('' '' '' '')

   # check all partitions on the device
   while IFS='' read -r line; do
      eval "$line"
      [[ $TYPE == 'part' ]] || continue

      # esp detect
      if [[ $PARTTYPE == 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' ]]; then
         if [[ $FSTYPE != 'vfat' ]]; then
            (( ret += 4 ))
            log w "${NAME} (EFI partition) doesn't have FAT filesystem!"
            continue
         fi
         if (( SIZE / MiB < min_sizes[1] )); then
            (( ret += 8 ))
            log w "${NAME} (EFI partition) is too small!"
            continue
         fi
         partitions[1]=1
         part_nodes[1]="/dev/${NAME}"
      fi

      # system detect
      if [[ $PARTLABEL == "${part_names[2]}" ]]; then
         if (( SIZE / MiB < min_sizes[2] )); then
            (( ret += 16 ))
            log w "${NAME} is too small for main partition!"
            continue
         fi
         partitions[2]=1
         part_nodes[2]="/dev/${NAME}"
      fi

   done < <(lsblk -Pnb -o NAME,TYPE,PARTTYPE,PARTLABEL,FSTYPE,SIZE "$device")

   (( partitions[1] || (ret+=1) ))
   (( partitions[2] || (ret+=2) ))
   return $ret
}
