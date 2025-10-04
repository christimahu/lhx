#!/bin/bash

# ====================================================================================
#
#                      MicroSD Re-Image Script (restore_microsd.sh)
#
# ====================================================================================
#
#  Purpose:
#  --------
#  This script performs a low-level re-imaging of the microSD card from a disk
#  image file (.img) stored on the NVMe SSD. It is the software equivalent of
#  using a tool like Balena Etcher to flash a fresh OS onto the card.
#
#  Tutorial Goal:
#  --------------
#  Imagine your Jetson is in a hard-to-reach case and you want to start over
#  completely fresh, as if you just took the microSD card out and flashed it on
#  your main computer. This script allows you to do exactly that, remotely.
#  Instead of just copying files, we will perform a block-level write from a
#  pristine OS image file, completely overwriting the microSD card to its factory
#  state. This is the ultimate recovery tool for starting over without physical access.
#
#  Workflow:
#  ---------
#  1. Ensure you have a copy of your desired Jetson disk image (e.g., 'jetson.img')
#     stored somewhere on the NVMe SSD.
#  2. Ensure you are booted from the NVMe SSD.
#  3. SSH into the Jetson.
#  4. Run this script: `sudo ./restore_microsd.sh`
#  5. After it completes, reboot. The system will now boot from the freshly
#     imaged microSD card.
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

# 1. This script modifies storage devices and system files, requiring root.
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run with root privileges. Please use 'sudo'."
    exit 1
fi
print_success "Running as root."

# 2. CRITICAL SAFETY CHECK: Verify we are booted from the SSD.
# This ensures our source of truth (the running OS) is not the device we are
# about to overwrite.
print_info "Verifying that the system is running from the NVMe SSD..."
CURRENT_ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$CURRENT_ROOT_DEV" != *"nvme"* ]]; then
  print_error "CRITICAL: System is NOT booted from the NVMe SSD."
  print_error "This script must be run from the SSD to re-image the microSD card."
  print_error "Aborting to prevent data loss."
  exit 1
fi
print_success "System is correctly booted from the SSD. It is safe to proceed."


# --- Part 1: Locate Image and Prepare MicroSD Card ---

print_border "Step 1: Prepare for Re-Imaging"

# Prompt for the location of the disk image.
read -p "> Please enter the full path to the disk image file on the SSD (e.g., /home/user/jetson.img): " IMAGE_PATH
if [ ! -f "$IMAGE_PATH" ]; then
    print_error "Image file not found at '$IMAGE_PATH'. Please check the path and try again."
    exit 1
fi
print_success "Found image file: $IMAGE_PATH"
echo ""

# Define the target device. On a Jetson, the microSD card is always /dev/mmcblk0.
MICROSD_DEVICE="/dev/mmcblk0"
if [ ! -b "$MICROSD_DEVICE" ]; then
    print_error "Could not find the microSD card device at $MICROSD_DEVICE."
    exit 1
fi
print_success "Found microSD card device: $MICROSD_DEVICE"
echo ""

# --- Tutorial: Unmounting Before Imaging ---
# Before we can perform a low-level write with `dd`, the target device must not be
# in use by the operating system. We check if the primary partition (`p1`) of the
# microSD card is mounted, and if so, we unmount it. This gives our script
# exclusive access to the hardware, preventing data corruption.
# ---
print_info "Checking if microSD card is currently mounted..."
MICROSD_PARTITION="${MICROSD_DEVICE}p1"
if mountpoint -q "/mnt/microsd_restore" || mount | grep -q "$MICROSD_PARTITION"; then
    print_info "MicroSD partition is mounted. Unmounting now..."
    umount "$MICROSD_PARTITION"
    # Also attempt to unmount from our old restore script's mountpoint just in case
    umount "/mnt/microsd_restore" &>/dev/null
    print_success "MicroSD card unmounted."
else
    print_success "MicroSD card is not mounted. Ready to proceed."
fi


# --- Part 2: Perform the Re-Imaging ---

print_border "Step 2: Re-Image microSD Card"

echo -e "${C_RED}!!!!!!!!!!!!!!!!!!!!!!!!!! DANGER !!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
echo -e "${C_RED}You are about to perform a DESTRUCTIVE, low-level write.${C_RESET}"
echo -e "${C_RED}This will completely ERASE the partition table and ALL data on:${C_RESET}"
echo -e "${C_YELLOW}    $MICROSD_DEVICE (the microSD card)${C_RESET}"
echo -e "${C_YELLOW}and replace it with the contents of the image file:${C_RESET}"
echo -e "${C_YELLOW}    $IMAGE_PATH${C_RESET}"
echo -e "${C_RED}This is IRREVERSIBLE. A mistake here could wipe your SSD.${C_RESET}"
echo -e "${C_RED}!!!!!!!!!!!!!!!!!!!!!!!!!! DANGER !!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"

# Final confirmation to prevent accidental destruction.
read -p "> To confirm you want to ERASE '$MICROSD_DEVICE', please type its name exactly: " confirm_device
if [[ "$confirm_device" != "$MICROSD_DEVICE" ]]; then
    print_info "Confirmation failed. The device name did not match. Aborting."
    exit 1
fi

echo "Confirmation accepted. Starting re-imaging process. This will take a long time..."

# --- Tutorial: The 'dd' Command Explained ---
# `dd` is a powerful, low-level utility for copying and converting raw data. It's
# often called "disk destroyer" because a small typo can wipe the wrong drive.
#
# `if=$IMAGE_PATH`:  'if' stands for 'input file'. This is our source.
# `of=$MICROSD_DEVICE`: 'of' stands for 'output file'. This is our destination.
#                       Note we are writing to the whole device, not a partition.
# `bs=4M`: 'bs' stands for 'block size'. This sets the size of the chunks to be
#          read and written at a time. 4 Megabytes is generally a good balance
#          for performance.
# `status=progress`: This provides a real-time progress bar so we can see how
#                    the operation is going.
# ---
dd if="$IMAGE_PATH" of="$MICROSD_DEVICE" bs=4M status=progress

# The `sync` command ensures all data in memory buffers is written to the disk
# before we declare the process complete. It's a safety measure.
sync
print_success "Re-imaging complete. All data has been written to the microSD card."


# --- Final Steps ---
print_border "Restore Complete"
print_success "The microSD card has been successfully re-imaged."
echo "The system will boot from this fresh image on the next startup."
echo "You will need to go through the initial Ubuntu user setup again, just like"
echo "with a brand new device."
echo ""
echo "Run 'sudo reboot' now to boot from the freshly imaged microSD card."

