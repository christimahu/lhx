#!/bin/bash

# ====================================================================================
#
#                    Jetson Node Health Check Script (check.sh)
#
# ====================================================================================
#
#  Purpose:
#  --------
#  This script runs a series of checks to verify that a Jetson node has been
#  correctly configured by the `init.sh` and `clean.sh` scripts. It provides a
#  quick, comprehensive report on the state of the system, confirming that it
#  is ready for Kubernetes deployment.
#
#  Workflow:
#  ---------
#  1. After running `init.sh`, rebooting, and running `clean.sh`, SSH into the node.
#  2. Run this script: `sudo ./check.sh`
#  3. Review the output to confirm all checks pass.
#
#  What it checks:
#  ---------------
#  ✅ Boot Device: Confirms the OS is running from the NVMe SSD.
#  ✅ Network: Verifies that a static IP is configured.
#  ✅ Hostname: Displays the current system hostname.
#  ✅ Headless Mode: Ensures the system is set to boot into command-line mode.
#  ✅ Swap Status: Confirms that all forms of swap memory are disabled.
#  ✅ MicroSD Cleanup: Verifies the old OS has been wiped from the microSD card.
#
# ====================================================================================


# --- Helper Functions for Better Output ---
# These functions are used to print colored and formatted text to the terminal,
# making the script's output easier to read and understand.

# readonly ensures these variables cannot be changed later in the script.
# These are ANSI escape codes for terminal colors.
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'

# Prints a message in green, typically indicating success.
print_success() {
    # The -e flag allows echo to interpret the backslash escape sequences for colors.
    echo -e "${C_GREEN}[PASS] $1${C_RESET}"
}

# Prints a message in red, indicating a failure or problem.
print_fail() {
    echo -e "${C_RED}[FAIL] $1${C_RESET}"
}

# Prints a message in yellow, for general information.
print_info() {
    echo -e "${C_YELLOW}[INFO] $1${C_RESET}"
}

# Prints a decorative border with a title to visually separate script sections.
print_border() {
    echo ""
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo " $1"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
}

# --- Initial Sanity Checks ---

print_border "Jetson Node Configuration Health Check"

# Some checks (like mounting the microSD) require root privileges.
if [ "$(id -u)" -ne 0 ]; then
    print_fail "This script must be run with root privileges. Please use 'sudo'."
    exit 1
fi
echo "Running pre-flight checks..."
print_success "Running as root."
echo ""

# --- Verification Checks ---

# --- Check 1: Boot Device ---
print_info "1. Verifying system is running from the NVMe SSD..."
CURRENT_ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$CURRENT_ROOT_DEV" == *"nvme"* ]]; then
    print_success "System is correctly booted from the SSD ($CURRENT_ROOT_DEV)."
else
    print_fail "System is NOT booted from the SSD. Current root is: $CURRENT_ROOT_DEV."
fi
echo ""

# --- Check 2: Network Configuration ---
print_info "2. Verifying network configuration..."
INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
CONNECTION_NAME=$(nmcli -t -f NAME,DEVICE con show --active | grep -E ":$INTERFACE$" | cut -d: -f1)
METHOD=$(nmcli -g ipv4.method con show "$CONNECTION_NAME")
if [[ "$METHOD" == "manual" ]]; then
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    print_success "Network is correctly set to 'manual' (static IP)."
    print_info "   Current IP Address: $CURRENT_IP"
else
    print_fail "Network is NOT set to 'manual'. Current method is: $METHOD."
fi
echo ""

# --- Check 3: Hostname ---
print_info "3. Checking system hostname..."
CURRENT_HOSTNAME=$(hostname)
if [ -n "$CURRENT_HOSTNAME" ]; then
    print_success "Hostname is set."
    print_info "   Current Hostname: $CURRENT_HOSTNAME"
else
    print_fail "Hostname is not set."
fi
echo ""

# --- Check 4: Headless Mode ---
print_info "4. Verifying headless (command-line) boot target..."
DEFAULT_TARGET=$(systemctl get-default)
if [[ "$DEFAULT_TARGET" == "multi-user.target" ]]; then
    print_success "System is correctly configured for headless boot."
else
    print_fail "System is NOT configured for headless boot. Current target is: $DEFAULT_TARGET."
fi
echo ""

# --- Check 5: Swap Status ---
print_info "5. Verifying that swap is disabled..."
# The `swapon --show` command will produce output if any swap device is active.
# We check if the output of the command is empty (`-z`).
if [ -z "$(swapon --show)" ]; then
    print_success "All swap devices are disabled."
else
    print_fail "Swap is still active. Please review the output of 'swapon --show'."
    swapon --show
fi
echo ""

# --- Check 6: MicroSD Cleanup ---
print_info "6. Verifying microSD card has been cleaned..."
MICROSD_PARTITION="/dev/mmcblk0p1"
MOUNT_POINT="/mnt/verify_microsd"

if [ ! -b "$MICROSD_PARTITION" ]; then
    print_fail "Could not find the microSD card partition at $MICROSD_PARTITION."
else
    # Mount the microSD card to a temporary location to inspect it.
    mkdir -p "$MOUNT_POINT"
    # We add a check to see if it's already mounted to prevent errors.
    if ! mountpoint -q "$MOUNT_POINT"; then
        mount "$MICROSD_PARTITION" "$MOUNT_POINT"
    fi

    # Count the number of items (files/directories) in the root of the microSD.
    # `ls -A1` lists all items (including hidden) one per line. `wc -l` counts the lines.
    ITEM_COUNT=$(ls -A1 "$MOUNT_POINT" | wc -l)
    
    # Check if a 'boot' directory exists.
    BOOT_DIR_EXISTS=$(find "$MOUNT_POINT" -maxdepth 1 -type d -name "boot")

    # A clean card should have 1 or 2 items ('boot' and maybe 'lost+found').
    if [[ "$ITEM_COUNT" -le 2 && -n "$BOOT_DIR_EXISTS" ]]; then
        print_success "MicroSD card has been cleaned. Only '/boot' directory remains."
    else
        print_fail "MicroSD card has NOT been cleaned. It still contains the old OS files."
        print_info "Contents of microSD:"
        ls -l "$MOUNT_POINT"
    fi
    
    # Always clean up by unmounting the drive.
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
fi

print_border "Check Complete"

