#!/bin/bash

# ====================================================================================
#
#                     Secure MicroSD Cleanup Script (clean_microsd.sh)
#
# ====================================================================================
#
#  Purpose:
#  --------
#  This script is a security-hardening measure to be run *after* the main OS has
#  been successfully migrated to an NVMe SSD. It removes the old, now-redundant
#  operating system from the microSD card, leaving only the essential bootloader
#  files.
#
#  Tutorial Goal:
#  --------------
#  Security is built in layers. After migrating our primary OS to a fast and
#  reliable SSD, we need to clean up the original boot media. Leaving a full,
#  un-updated copy of the OS on the microSD card is a security risk. If an attacker
#  gained physical access, they could potentially force the device to boot from
#  that old OS, which might have unpatched vulnerabilities. This script neutralizes
#  that threat.
#
#  Workflow:
#  ---------
#  1. Run the `init_headless.sh` script and migrate the OS to the SSD.
#  2. Reboot the Jetson. It will now be running from the SSD.
#  3. SSH into the Jetson and run this script: `sudo ./clean_microsd.sh`
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
# --- Tutorial: The Importance of This Check ---
# This is the most important check in this script. We are about to delete the
# operating system from the microSD card. If we accidentally run this script
# while the system is *still running from the microSD card*, it would be a
# "self-destruct" command. The script would be deleting the very files it is
# currently using, leading to a catastrophic failure and an unbootable system.
# By verifying the root filesystem ('/') is on an 'nvme' device, we ensure it is
# safe to wipe the 'mmcblk0p1' (microSD) device.
# ---
print_info "Verifying that the system is running from the NVMe SSD..."
CURRENT_ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$CURRENT_ROOT_DEV" != *"nvme"* ]]; then
  print_error "CRITICAL: System is NOT booted from the NVMe SSD."
  print_error "Running this script now would permanently destroy your current OS."
  print_error "Please run 'init_headless.sh' and reboot from the SSD before running this script."
  exit 1
fi
print_success "System is correctly booted from the SSD. It is safe to proceed."


# --- Part 1: Wipe the microSD card ---

print_border "Step 1: Clean Up microSD Card"

# In Linux on Jetson devices, `/dev/mmcblk0` represents the microSD card device,
# and `p1` refers to the first partition on that device.
MICROSD_PARTITION="/dev/mmcblk0p1"
# `-b` checks if the file exists AND is a block special file (i.e., a storage device).
if [ ! -b "$MICROSD_PARTITION" ]; then
    print_error "Could not find the microSD card partition at $MICROSD_PARTITION."
    exit 1
fi

# We will temporarily mount the microSD partition here to access its files.
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
# `mountpoint -q` is a quiet check to see if a directory is already a mount point.
# This prevents an error if the script was run before and failed to unmount.
if ! mountpoint -q "$MOUNT_POINT"; then
    mount "$MICROSD_PARTITION" "$MOUNT_POINT"
fi

echo "Deleting all files and directories from microSD except '/boot'..."
# --- Tutorial: Deconstructing the 'find' Command ---
# This command is the core of the cleanup process. Let's break it down:
# `find "$MOUNT_POINT"`: Start searching within the mounted microSD directory.
# `-mindepth 1 -maxdepth 1`: This is crucial. It tells `find` to only operate on
#   the items *directly inside* the mount point (like /bin, /etc, /home) and not
#   the mount point itself or files deeper inside those directories. This makes
#   the operation much faster.
# `-not -name "boot"`: This tells `find` to EXCLUDE any item named "boot".
#   This is what preserves our critical boot files, which the device still needs
#   to start up before it hands off control to the SSD.
# `-exec rm -rf {} +`: For everything found that wasn't excluded, execute the
#   `rm -rf` (remove, recursively, forcefully) command. The `{}` is a placeholder
#   that gets filled with the found file/directory names. The `+` at the end is an
#   optimization that groups many filenames into a single `rm` command, making it
#   much more efficient than running `rm` once for every single file.
# ---
find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -not -name "boot" -exec rm -rf {} +
print_success "Old OS files have been deleted."

# --- Final Steps ---
print_border "Cleanup Complete"
echo "Unmounting the microSD card partition..."
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
print_success "The microSD card is now a minimal boot device."
print_success "Your Jetson setup is fully and securely configured."


