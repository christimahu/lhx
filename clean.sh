#!/bin/bash

# ====================================================================================
#
#                     Secure MicroSD Cleanup Script (clean.sh)
#
# ====================================================================================
#
#  Purpose:
#  --------
#  This script securely removes the old operating system files from the microSD
#  card after a successful migration to an NVMe SSD. This is a security-hardening
#  step to ensure there isn't a dormant, un-updated OS on the boot media.
#
#  Workflow:
#  ---------
#  1. Run the `init.sh` script and migrate the OS to the SSD.
#  2. Reboot the Jetson.
#  3. SSH back into the Jetson using its new static IP address.
#  4. Run this script: `sudo ./clean.sh`
#
#  What it does:
#  -------------
#  - Verifies that the system is currently running from the NVMe SSD.
#  - Mounts the microSD card's primary partition.
#  - Deletes all files and directories from the microSD card EXCEPT for the
#    critical `/boot` directory, which is required for the system to start.
#
# ====================================================================================


# --- Helper Functions for Better Output ---

# Defines color codes for script output.
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'

# Prints a message in green (for success).
print_success() {
    echo -e "${C_GREEN}[OK] $1${C_RESET}"
}

# Prints a message in red (for errors).
print_error() {
    echo -e "${C_RED}[ERROR] $1${C_RESET}"
}

# Prints a message in yellow (for warnings/info).
print_info() {
    echo -e "${C_YELLOW}[INFO] $1${C_RESET}"
}

# Prints a decorative border with a title.
print_border() {
    echo ""
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo " $1"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
}


# --- Initial Sanity Checks ---

print_border "Step 0: Pre-flight Checks"

# 1. Check if the script is run as root.
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run with root privileges. Please use 'sudo'."
    exit 1
fi
print_success "Running as root."

# 2. CRITICAL SAFETY CHECK: Verify we are booted from the SSD.
# We find the device that is mounted as the root ('/') filesystem.
# If it's not an NVMe device, we MUST abort to prevent self-destruction.
print_info "Verifying that the system is running from the NVMe SSD..."
CURRENT_ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$CURRENT_ROOT_DEV" != *"nvme"* ]]; then
  print_error "CRITICAL: System is NOT booted from the NVMe SSD."
  print_error "Running this script now would permanently destroy your current OS."
  print_error "Please run 'init.sh' and reboot from the SSD before running this script."
  exit 1
fi
print_success "System is correctly booted from the SSD. It is safe to proceed."


# --- Part 1: Wipe the microSD card ---

print_border "Step 1: Clean Up microSD Card"

# The microSD card is always at this device path on a Jetson.
MICROSD_PARTITION="/dev/mmcblk0p1"
if [ ! -b "$MICROSD_PARTITION" ]; then
    print_error "Could not find the microSD card partition at $MICROSD_PARTITION."
    exit 1
fi

MOUNT_POINT="/mnt/microsd_rootfs"

echo -e "${C_RED}!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
echo -e "${C_YELLOW}This script will permanently delete the old OS from the microSD card.${C_RESET}"
echo -e "${C_YELLOW}The essential /boot directory WILL BE PRESERVED.${C_RESET}"
echo -e "${C_RED}This action cannot be undone.${C_RESET}"
read -p "> To confirm, please type 'yes': " confirm_wipe

if [[ "$confirm_wipe" != "yes" ]]; then
    print_info "Cleanup aborted by user. No files were deleted."
    exit 1
fi

echo "Mounting $MICROSD_PARTITION to $MOUNT_POINT..."
mkdir -p "$MOUNT_POINT"
# We add a check to see if it's already mounted to prevent errors.
if ! mountpoint -q "$MOUNT_POINT"; then
    mount "$MICROSD_PARTITION" "$MOUNT_POINT"
fi

echo "Deleting all files and directories from microSD except '/boot'..."
# This command finds all items in the top-level of the mounted directory.
# For every item that is NOT named 'boot', it executes 'rm -rf' on it.
find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -not -name "boot" -exec rm -rf {} +
print_success "Old OS files have been deleted."

# --- Final Steps ---
print_border "Cleanup Complete"
echo "Unmounting the microSD card partition..."
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
print_success "The microSD card is now a minimal boot device."
print_success "Your Jetson setup is fully and securely configured."


