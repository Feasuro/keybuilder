#!/bin/bash
# common.sh
# Depends on:
# Usage: source common.sh
[[ -n "${COMMON_SH_INCLUDED:-}" ]] && return
COMMON_SH_INCLUDED=1

# ----------------------------------------------------------------------
# Global variables
# ----------------------------------------------------------------------
# Logging levels:
#   0 = NONE
#   1 = ERROR
#   2 = WARNING
#   3 = INFO (default)
#   4 = DEBUG (most verbose)
# ----------------------------------------------------------------------
LOGLEVEL=$([[ -n $DEBUG && $DEBUG != 0 ]] && echo 4 || echo 3)
WHITE=$(printf '\033[97m')
GREEN=$(printf '\033[92m')
YELLOW=$(printf '\033[93m')
RED=$(printf '\033[91m')
PINK=$(printf '\033[95m')
RESET=$(printf '\033[0m')

# ----------------------------------------------------------------------
# Signal handling
# ----------------------------------------------------------------------
trap 'abort' INT
trap 'abort' TERM
trap 'errexit_handler' EXIT

# ----------------------------------------------------------------------
# Usage:   log [<level>] "<message>"
# Purpose: Simple leveled logger that writes to stderr.
# Parameters:
#   $1 – log level (d|4 - debug, i|3 - info, w|2 - warning, e|1 - error, p - progress)
#   $2 – message text to log (quote if it contains spaces)
# Globals used:
#   LOGLEVEL – current log level (0 to 4)
#   WHITE, GREEN, YELLOW, RED, PINK, RESET – ANSI terminal escape characters
# Returns: none
# Side‑Effects: writes to stderr if level ≤ LOGLEVEL
# ----------------------------------------------------------------------
log() {
   local level="$1"
   local msg="${2:-$1}"
   local header

   case $level in
      d|4) level=4; header="${WHITE}DEBUG${RESET}" ;;
      i|3) level=3; header="${GREEN}INFO${RESET}" ;;
      w|2) level=2; header="${YELLOW}WARNING${RESET}" ;;
      e|1) level=1; header="${RED}ERROR${RESET}" ;;
      p)   level=3; header="${PINK}PROGRESS${RESET}" ;;
      *)            header="LOG" ;;
   esac

   (( level > LOGLEVEL )) || echo "${header} ${FUNCNAME[1]}: ${msg}" >&2
}

# ----------------------------------------------------------------------
# Usage: abort
# Purpose: Clean up, print a message and exit with status 1.
# Parameters: none
# Returns: never returns – calls 'exit 1'.
# ----------------------------------------------------------------------
abort() {
   cleanup
   log w "Application aborted."
   exit 1
}

# ----------------------------------------------------------------------
# Usage: user_exit
# Purpose: User termination (user clicks “Exit” or presses ESC in a dialog).
# Parameters: none
# Variables used: none
# Returns: exits with status 0.
# ----------------------------------------------------------------------
user_exit() {
   cleanup
   log i "Exiting."
   exit 0
}

# ----------------------------------------------------------------------
# Usage: app_exit
# Purpose: Normal termination (user completes all steps successfully).
# Parameters: none
# Variables used: none
# Returns: exits with status 0.
# ----------------------------------------------------------------------
app_exit() {
   exit 0
}

# ----------------------------------------------------------------------
# Usage: error_handler (used in a trap for unexpected errors)
# Purpose: Error‑handling routine invoked automatically on script exit.
#          It distinguishes between normal termination paths and unexpected errors.
# Parameters: none (relies on Bash built‑ins)
# Returns:  never returns directly – either logs the error and cleans up,
#           or does nothing for expected termination functions.
# Side‑Effects:
#   * Writes a formatted error message to stderr via `log e`.
#   * Calls `cleanup` to unmount any mounted partitions and remove temporary files.
# ----------------------------------------------------------------------
errexit_handler() {
   case ${FUNCNAME[1]} in
      abort|user_exit|app_exit) ;;
      *) 
         cleanup
         log e "
   ocurred in function: ${FUNCNAME[1]}
   command:             ${BASH_COMMAND}
   returned status:     $?"
         ;;
   esac
}

# ----------------------------------------------------------------------
# Usage: handle_exit_code <code>
# Purpose: Centralised handling of dialog exit codes.
# Parameters:
#   $1 – numeric exit code returned by a dialog command.
# Variables used:
#   step – current wizard step (incremented/decremented here).
# Returns: may call 'abort' on unknown codes; otherwise updates $step.
# ----------------------------------------------------------------------
handle_exit_code() {
   local status=$1
   log d "\`${FUNCNAME[1]}\` exited with status ${status}"
   # Actions of dialog buttons
   case $status in
      0) (( step++ )) ;;
      1) user_exit ;;
      2) ;;
      3) (( step-- )) ;;
      255) user_exit ;;
      *) 
         log e "Unknown exit code - ${status}"
         abort
      ;;
   esac
}

# ----------------------------------------------------------------------
# Usage: cleanup
# Purpose: Unmount any mounted partitions and remove temporary files.
# Parameters: none
# Variables used:
#   tmpfile      – path to temporary file (if created)
#   target_dir[] – mountpoints of the system partition and ESP (if mounted)
# Returns: none
# Side‑Effects:
#   * Unmounts partitions mounted at $target_dir (if mounted).
#   * Removes temporary file $tmpfile (if it exists).
# ----------------------------------------------------------------------
cleanup() {
   local dir

   rm -f "${tmpfile:-}"
   for dir in "${target_dir[@]}"; do
      if mountpoint -q "$dir"; then
         umount "$dir" || log w "Failed to unmount ${dir}."
      fi
      rmdir "$dir"
   done
}

# ----------------------------------------------------------------------
# Usage: quiet <command> [args...]
# Purpose: Wrapper that runs a command quietly if DEBUG is unset or zero.
# Parameters:
#   $@ – command and its arguments
# Variables used:
#   DEBUG – if unset or zero, suppresses command output by redirecting to /dev/null
# Returns: int – exit status of the command run.
# Side‑Effects: may write to stdout if DEBUG is set and non‑zero
# ----------------------------------------------------------------------
quiet() {
   if [[ -z $DEBUG || $DEBUG == 0 ]]; then
      "$@" >/dev/null
      return $?
   fi
   "$@"
}