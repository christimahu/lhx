#!/bin/bash

# =============================================
# Jetson OS Migration Script: SD Card to SSD
# =============================================
# This script moves the root filesystem from the
# microSD card to an NVMe SSD and makes the
# system boot from the SSD.
#
# !! WARNING !! This script will ERASE all
# data on the target NVMe SSD.
#
# Run this script over SSH after the initial
# setup script is complete.
# =============================================

# --- Ensure script is run as root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use 'sudo'."
    exit 1
fi

# --- Find the NVMe SSD ---
SSD_DEVICE=$(lsblk -d -o NAME,ROTA | grep '0' | awk '/nvme/ {print "/dev/"$1}')
if [ -z "$SSD_DEVICE" ]; then
    echo "❌ ERROR: No NVMe SSD detected. Make sure the SSD is properly installed."
    exit 1
fi

echo "✅ Detected NVMe SSD at: $SSD_DEVICE"
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "This script will format and erase ALL DATA on $SSD_DEVICE."
echo "!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "Are you sure you want to continue? (yes/N): " confirm_erase
if [[ "$confirm_erase" != "yes" ]]; then
    echo "Aborting script. No changes were made."
    exit 1
fi

# --- Partition and Format the SSD ---
echo "--- Preparing the SSD ---"
echo " partitioning..."
parted -s "$SSD_DEVICE" mklabel gpt
parted -s "$SSD_DEVICE" mkpart primary ext4 0% 100%

# It can take a moment for the kernel to see the new partition
sleep 3
SSD_PARTITION="${SSD_DEVICE}p1"

echo " formatting partition $SSD_PARTITION as ext4..."
mkfs.ext4 "$SSD_PARTITION"
echo "✅ SSD prepared."
echo ""

# --- Clone the Filesystem ---
echo "--- Cloning Filesystem (this will take several minutes) ---"
MOUNT_POINT="/mnt/ssd_root"
mkdir -p "$MOUNT_POINT"
mount "$SSD_PARTITION" "$MOUNT_POINT"

echo " copying files from microSD to SSD..."
rsync -axHAWX --numeric-ids --info=progress2 --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} / "$MOUNT_POINT"
echo "✅ Filesystem cloned."
echo ""

# --- Update Boot Configuration ---
echo "--- Updating Boot Configuration ---"
# Get the UUID of the new SSD root partition
SSD_UUID=$(blkid -s UUID -o value "$SSD_PARTITION")
if [ -z "$SSD_UUID" ]; then
    echo "❌ ERROR: Could not get UUID of the SSD partition. Aborting."
    umount "$MOUNT_POINT"
    exit 1
fi

echo " new root partition UUID: $SSD_UUID"
# The boot config file to edit
BOOT_CONFIG_FILE="/boot/extlinux/extlinux.conf"

echo " modifying $BOOT_CONFIG_FILE to boot from SSD..."
# Use sed to replace the root device with the new UUID
sed -i "s|root=[^ ]*|root=UUID=$SSD_UUID|" "$BOOT_CONFIG_FILE"
echo "✅ Boot configuration updated."
echo ""

# --- Final Steps ---
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
echo "=========================================================="
echo " Migration Complete!"
echo " The system is now configured to boot from the SSD."
echo ""
echo " Run 'sudo reboot' to apply the changes."
echo " After rebooting, your Jetson will be running from the SSD."
echo "=========================================================="

