#!/bin/bash
# boot_utils.sh
# Depends on: common.sh
# Usage: source boot_utils.sh and deps, in any order.
[[ -n "${BOOT_UTILS_SH_INCLUDED:-}" ]] && return
BOOT_UTILS_SH_INCLUDED=1

# ----------------------------------------------------------------------
# Usage: setup_target_dir
# Purpose: Sets up mountpoints for the EFI System Partition
#          and the system partition. If they are not already
#          mounted, mounts them to temporary directories.
# Parameters: none – function relies on runtime variables
# Variables used/set:
#   target_dir    – mountpoint of the system partition (set here).
#   part_nodes[]  – array with partition nodes (input).
# Returns: none
# Side‑Effects:
#   * May create and mount to temporary directories.
#   * Sets runtime variable target_dir[].
# ----------------------------------------------------------------------
setup_target_dir() {
   # default mountpoints
   target_dir=( '/tmp/system' '/tmp/esp' )
   # real mountpoints
   for i in 0 1; do
      target_dir[i]=$(findmnt -ln -o TARGET "${part_nodes[$i]}" 2>/dev/null || {
         mkdir -p "${target_dir[$i]}" &&
         mount "${part_nodes[$i]}" "${target_dir[$i]}" &&
         echo "${target_dir[$i]}"
      })
   done
}

# ----------------------------------------------------------------------
# Usage: install_bootloader
# Purpose: Installs GRUB on the target device for both legacy BIOS
#          and UEFI platforms.
# Parameters: none – function relies on runtime variables
# Variables used/set:
#   SHARED_DIR    – absolute path to the shared directory.
#   BOOT_ISOS_DIR – name of the directory to hold ISO files (relative to root of system partition).
#   device        – full block‑device path (e.g. /dev/sdb)
#   target_dir[]  – mountpoints of the system partition and ESP.
#   part_nodes[]  – array with partition nodes
# Return codes:
#   0        – GRUB was installed successfully on both targets.
#   non-zero – Any step failed.
# ----------------------------------------------------------------------
install_bootloader() {
   local grub_dir grub_env

   grub_dir="${SHARED_DIR}/grub"
   grub_env="${target_dir}/grub/grubenv"

   log i "Commencing GRUB installation."
   grub-install --target=i386-pc --force --locale-directory="${grub_dir}/locale" \
      --boot-directory="$target_dir" "$device"
   grub-install --target=x86_64-efi --removable --locale-directory="${grub_dir}/locale" \
      --boot-directory="$target_dir" --efi-directory="${target_dir[1]}" --no-nvram
   grub-install --target=i386-efi --removable --locale-directory="${grub_dir}/locale" \
      --boot-directory="$target_dir" --efi-directory="${target_dir[1]}" --no-nvram
   install -d "${target_dir}/${BOOT_ISOS_DIR}"
   install -Dm0644 -t "${target_dir}/grub/" "${grub_dir}/"*.cfg
   install -Dm0644 -t "${target_dir}/grub/themes/" "${grub_dir}/themes/background.png"
   install -Dm0644 -t "${target_dir}/grub/fonts/" "${grub_dir}/fonts/"*.pf2

   # Setup GRUB environment variables
   log d "Setting up GRUB environment."
   grub-editenv "${grub_env}" set pager=1
   grub-editenv "${grub_env}" set sys_uuid="$(lsblk -ln -o UUID "${part_nodes[2]}")"
   grub-editenv "${grub_env}" set iso_dir="/${BOOT_ISOS_DIR}"
   grub-editenv "${grub_env}" set locale_dir=/grub/locale
   grub-editenv "${grub_env}" set lang="${LANG::2}"
   grub-editenv "${grub_env}" set gfxmode=auto
   grub-editenv "${grub_env}" set gfxterm_font=unicode
   grub-editenv "${grub_env}" set color_normal=green/black
   grub-editenv "${grub_env}" set color_highlight=black/light-green
   grub-editenv "${grub_env}" set timeout_style=menu
   grub-editenv "${grub_env}" set timeout=10
   grub-editenv "${grub_env}" set default=0
}
