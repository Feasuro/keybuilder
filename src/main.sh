#!/bin/bash
set -euo pipefail

# ----------------------------------------------------------------------
# Global variables
# ----------------------------------------------------------------------
APPNAME="Keybuilder"  # program name.
VERSION="0.2"         # program version
DEBUG=${DEBUG:-0}     # if not-null-or-zero causes app to print verbose messages to stdout/stderr.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # installation directory.
SHARED_DIR="/usr/share/${APPNAME,,}"                     # location of directory with resources
GLOBAL_CONFIG_FILE="/etc/${APPNAME,,}.conf"              # location of configuration file.
USER_CONFIG_FILE="${XDG_CONFIG_HOME:-"${HOME}/.config"}/${APPNAME,,}.conf" # as above (per user)
MiB=1048576           # 1 MiB in bytes

# ----------------------------------------------------------------------
# Import modules
# ----------------------------------------------------------------------
for module in "${BASE_DIR}/modules/"*.sh; do
   source "$module"
done
unset module

# ----------------------------------------------------------------------
# Usage: main "$@"
# Purpose: Entry point for the program. Prepares environment and starts the main loop.
# Parameters: all arguments passed to the original script.
# Returns: int - Exits the script with status of the program loop.
# Side‑Effects
#   * May re‑execute the script with `sudo` or `pkexec` via `require_root`.
#   * Sets global variables found in configuration files via `init_resources`.
#   * Runs program loop.
# ----------------------------------------------------------------------
main() {
   parse_cmdline "$@"
   require_root "$@"
   init_resources
   run_loop
   app_exit
}

main "$@"
