#!/bin/bash
# loop.sh
# Depends on: step_dialogs.sh common.sh
# Usage: source loop.sh and deps, in any order.
[[ -n "${LOOP_SH_INCLUDED:-}" ]] && return
LOOP_SH_INCLUDED=1

# ----------------------------------------------------------------------
# Usage: init_resources
# Purpose: Locate the shared resources directory and load all global
#          configuration variables (system‑wide, and per‑user).
# Parameters: none – the function works with the global constants that
#             are defined earlier in the script.
# Returns: 0 (implicit) after the environment has been prepared.
#          Exits the script with a non‑zero status if the shared directory
#          cannot be found or if no configuration file is available.
# Side‑Effects:
#   * May modify the global variable SHARED_DIR.
#   * Sources configuration files, thereby defining any variables they contain.
#   * Logs a message to stderr and calls `abort` on fatal errors, which terminates the script.
# ----------------------------------------------------------------------
init_resources() {
# Determine resources path (if running portable)
if [[ $(basename "$(dirname "$BASE_DIR")") == "${APPNAME,,}" ]]; then
   SHARED_DIR=$(dirname "$BASE_DIR")
elif [[ -d $SHARED_DIR ]]; then
   :
else
   log e "Couldn't find shared directory."
   abort
fi

# Import configuration
if [[ -f "${BASE_DIR}/config.sh" ]]; then
   source "${BASE_DIR}/config.sh"
elif [[ -f $GLOBAL_CONFIG_FILE ]]; then
   source "$GLOBAL_CONFIG_FILE"
else
   log e "Couldn't find configuration file."
   abort
fi

# Import user configuration if found
if [[ -f $USER_CONFIG_FILE ]]; then
   source "$USER_CONFIG_FILE"
fi
}

# ----------------------------------------------------------------------
# Usage: require_root "$@"
# Purpose: Ensure the script runs with root privileges. If not already
#          root, re‑executes itself via `sudo` (preferred) or `pkexec`.
# Parameters: all arguments passed to the original script.
# Variables used: none
# Returns: does not return – either continues as root or aborts.
# ----------------------------------------------------------------------
require_root() {
   # If we are already uid 0 (root) there is nothing to do
   [[ $(id -u) -eq 0 ]] && return 0

   # Prefer sudo
   if command -v sudo >/dev/null 2>&1; then
      log i "Requesting root privileges via sudo."
      exec sudo -E "$0" "$@"
   # Fallback to pkexec
   elif command -v pkexec >/dev/null 2>&1; then
      log i "Requesting root privileges via pkexec."
      exec pkexec "$0" "$@"
   else
      log e "Neither sudo nor pkexec is available. Cannot obtain root."
      abort
   fi
}

# ----------------------------------------------------------------------
# Usage: run_loop
# Purpose: Declare runtime variables that represent the current state of the program.
#          Then assemble the main loop for an interactive wizard that prepares
#          a removable USB device and installs a bootloader.
# Parameters: none
# Variables declared: (look dev_utils.sh / set_config_vars)
#   backtitle           – application name and version shown by dialogs.
#   step                – step of the wizard (start with 1)
#   message             – message for the user to display on dialog box
#   device              – selected block device (e.g. /dev/sdb)
#   sector_size         – bytes per sector (from `blockdev --getss`)
#   offset              – first usable sector (after 1 MiB)
#   usable_size         – sectors available for partitions (excluding GPT backup)
#   part_sizes[]        – size of each partition (in sectors)
#   part_names[]        – human‑readable GPT labels
#   min_sizes[]         – minimal partition sizes (in sectors)
#   part_nodes[]        – device node names for each partition (e.g. /dev/sdb1)
#   partitions[]        – indexed array (size 4) of flags (0/1) indicating which
#                         partitions are selected
#   removable_devices[] – associative array mapping a device path to a
#                         human‑readable label
# Returns: int
#   It exits the loop with status 0 after completing last step or propagates
#   any non‑zero exit status from called functions that invoke `abort`.
# Side‑Effects
#   * Interacts with the user through a series of `dialog` windows.
#   * Writes to standard error for progress messages.
#   * Modifies numerous variables that represent the current state
#     of the wizard.
# ----------------------------------------------------------------------
run_loop() {
   local backtitle step message device sector_size offset usable_size 
   local -a partitions part_sizes part_names min_sizes part_nodes
   local -A removable_devices

   backtitle="${APPNAME} ${VERSION}"
   message=''
   step=1

   while true; do
      case $step in
         1) pick_device ;;
         2) ask_format_or_keep ;;
         3) pick_partitions ;;
         4) set_partitions_size ;;
         5) confirm_format ;;
         6) install_components ;;
         7) log i "Finished."
            break
            ;;
      esac
   done
}
