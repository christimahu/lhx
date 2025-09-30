#!/bin/bash

# ====================================================================================
#
#                    Jetson Kubernetes Node Initializer (init.sh)
#
# ====================================================================================
#
#  Purpose:
#  --------
#  This script performs the complete "Day 0" configuration for a new NVIDIA
#  Jetson device that will be used as a Kubernetes node. It is designed to be
#  the first and only script you run on a freshly imaged microSD card.
#
#  Workflow:
#  ---------
#  1. Flash microSD with the latest Jetson JetPack OS.
#  2. Boot the Jetson, connect it to the network via Ethernet, and log in.
#  3. Clone the repository containing this script onto the Jetson.
#  4. Run this script: `sudo ./init.sh`
#  5. After it completes, reboot the device.
#
#  What it does:
#  -------------
#  ✅ Configures a static IP address for reliable network access.
#  ✅ (Optional) Migrates the entire operating system to a faster, more
#     durable NVMe SSD. This step is automatically skipped if already done.
#  ✅ Removes the entire Ubuntu Desktop environment for a minimal, secure server.
#  ✅ Disables swap memory, a requirement for Kubernetes.
#  ✅ Updates the remaining system packages to the latest versions.
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
    echo -e "${C_GREEN}✅ $1${C_RESET}"
}

# Prints a message in red (for errors).
print_error() {
    echo -e "${C_RED}❌ ERROR: $1${C_RESET}"
}

# Prints a message in yellow (for warnings/info).
print_info() {
    echo -e "${C_YELLOW}ℹ️  $1${C_RESET}"
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
# Most operations in this script require administrative privileges.
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run with root privileges. Please use 'sudo'."
    exit 1
fi
print_success "Running as root."

# 2. Check for an active internet connection.
# We need this to download system updates.
if ! ping -c 1 -W 3 google.com &> /dev/null; then
    print_error "No internet connection detected. Please check your network cable and connection."
    exit 1
fi
print_success "Internet connection is active."

# --- Part 1: Network Configuration ---

print_border "Step 1: Network Configuration (Static IP)"
print_info "A server needs a permanent, predictable IP address. We'll now configure one."

# Automatically detect the primary network interface (e.g., enP8p1s0).
INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
if [[ -z "$INTERFACE" ]]; then
    print_error "Could not detect the primary network interface. Is Ethernet plugged in?"
    exit 1
fi

# Find the associated NetworkManager connection name (e.g., "Wired connection 1").
CONNECTION_NAME=$(nmcli -t -f NAME,DEVICE con show --active | grep -E ":$INTERFACE$" | cut -d: -f1)
if [[ -z "$CONNECTION_NAME" ]]; then
    print_error "Could not find a NetworkManager connection for interface '$INTERFACE'."
    exit 1
fi

GATEWAY_IP=$(ip route | awk '/default/ {print $3; exit}')
SUBNET=$(ip -o -f inet addr show "$INTERFACE" | awk '/scope global/ {print $4}' | cut -d'/' -f1 | cut -d'.' -f1-3)

echo "Detected Network Details:"
echo "  - Connection Name: '$CONNECTION_NAME' on Interface '$INTERFACE'"
echo "  - Network Subnet:  $SUBNET.0/24"
echo "  - Network Gateway: $GATEWAY_IP"
echo ""
print_info "Kubernetes nodes are typically assigned IPs in a reserved range."
echo "Suggested IP scheme:"
echo "  - Control Planes: $SUBNET.240 - $SUBNET.249"
echo "  - Worker Nodes:   $SUBNET.200 - $SUBNET.239"
echo ""

read -p "➡️ Enter the last number (octet) for this node's static IP (200-249): " ip_octet
if ! [[ "$ip_octet" =~ ^[0-9]+$ ]] || [[ "$ip_octet" -lt 200 || "$ip_octet" -gt 249 ]]; then
    print_error "Invalid input. You must enter a number between 200 and 249."
    exit 1
fi

STATIC_IP="$SUBNET.$ip_octet"
echo "🔧 Setting static IP to $STATIC_IP..."

# Use 'nmcli', the command-line tool for NetworkManager, to configure the connection.
nmcli con mod "$CONNECTION_NAME" ipv4.method manual ipv4.addresses "${STATIC_IP}/24" ipv4.gateway "$GATEWAY_IP" ipv4.dns "8.8.8.8,8.8.4.4"

# Restart the connection to apply the new settings. A brief network flicker is normal.
nmcli con down "$CONNECTION_NAME" > /dev/null 2>&1 && nmcli con up "$CONNECTION_NAME" > /dev/null 2>&1
sleep 2 # Give the network a moment to stabilize.

print_success "Static IP configured. SSH will be available at: $STATIC_IP"

# --- Part 2: OS Migration to NVMe SSD ---

print_border "Step 2: Migrate OS from microSD to NVMe SSD"

# --- SAFETY CHECK: Determine if we are already running on the SSD ---
CURRENT_ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$CURRENT_ROOT_DEV" == *"nvme"* ]]; then
    print_success "System is already running from the NVMe SSD. Skipping migration."
else
    print_info "Running the OS from an SSD is much faster and more reliable than a microSD card."
    read -p "➡️ Do you want to migrate the OS to an NVMe SSD now? (Y/N): " confirm_migrate

    if [[ "$confirm_migrate" != "Y" && "$confirm_migrate" != "y" ]]; then
        print_info "Skipping OS migration. The system will continue to run from the microSD card."
    else
        # Detect the NVMe SSD device.
        SSD_DEVICE=$(lsblk -d -o NAME,ROTA | grep '0' | awk '/nvme/ {print "/dev/"$1}')
        if [ -z "$SSD_DEVICE" ]; then
            print_error "No NVMe SSD detected. Please ensure it is installed correctly. Skipping migration."
        else
            print_success "Detected NVMe SSD at: $SSD_DEVICE"
            echo ""
            echo -e "${C_RED}!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
            echo -e "${C_YELLOW}This next step will completely and IRREVERSIBLY ERASE all data on the SSD.${C_RESET}"
            echo -e "${C_RED}!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
            read -p "To confirm, please type 'yes': " confirm_erase

            if [[ "$confirm_erase" != "yes" ]]; then
                print_info "Migration aborted by user. The SSD was not touched."
            else
                echo "🔧 Preparing the SSD..."
                # Create a new GPT partition table and a single partition covering the whole disk.
                parted -s "$SSD_DEVICE" mklabel gpt
                parted -s "$SSD_DEVICE" mkpart primary ext4 0% 100%
                sleep 3 # Wait for the kernel to recognize the new partition.
                SSD_PARTITION="${SSD_DEVICE}p1"
                mkfs.ext4 "$SSD_PARTITION"
                print_success "SSD has been partitioned and formatted."
                
                echo "🔧 Cloning filesystem. This will take several minutes..."
                MOUNT_POINT="/mnt/ssd_root"
                mkdir -p "$MOUNT_POINT"
                mount "$SSD_PARTITION" "$MOUNT_POINT"
                
                # Use rsync with specific flags to ensure a perfect clone of the OS.
                # -a: archive mode (preserves permissions, ownership, etc.)
                # -x: don't cross filesystem boundaries
                # -H: preserve hard links
                # -A: preserve ACLs
                # -X: preserve extended attributes
                rsync -axHAWX --numeric-ids --info=progress2 --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} / "$MOUNT_POINT"
                print_success "Filesystem cloned successfully."
                
                echo "🔧 Updating boot configuration to use the SSD..."
                SSD_UUID=$(blkid -s UUID -o value "$SSD_PARTITION")
                if [ -z "$SSD_UUID" ]; then
                    print_error "Could not determine the SSD's UUID. Cannot update boot config."
                    umount "$MOUNT_POINT" # Clean up
                else
                    # The Jetson's bootloader reads this file to find the OS.
                    # We will replace the original root device with the UUID of our new SSD partition.
                    sed -i "s|root=[^ ]*|root=UUID=$SSD_UUID|" "/boot/extlinux/extlinux.conf"
                    umount "$MOUNT_POINT"
                    rmdir "$MOUNT_POINT"
                    print_success "Boot configuration updated. The system will boot from the SSD."
                fi
            fi
        fi
    fi
fi

# --- Part 3: System Minimization & Kubernetes Preparation ---

print_border "Step 3: System Minimization & Hardening"

# Remove the full Ubuntu Desktop environment.
print_info "To create a lean, secure server, we will remove the desktop GUI and related applications."
read -p "➡️ Remove the full desktop environment? (Highly Recommended) (Y/N): " confirm_remove
if [[ "$confirm_remove" == "Y" || "$confirm_remove" == "y" ]]; then
    echo "🔧 Setting boot target to command-line..."
    systemctl set-default multi-user.target
    echo "🗑️ Removing desktop packages... This may take a few minutes."
    apt-get remove --purge ubuntu-desktop -y && apt-get autoremove --purge -y
    print_success "Desktop environment removed. System will now boot to terminal."
else
    print_info "Skipping desktop removal. The GUI will remain installed."
fi
echo ""

# Disable Swap memory.
print_info "Kubernetes requires swap memory to be disabled for performance and stability."
read -p "➡️ Disable swap? (This is required for Kubernetes) (Y/N): " confirm_swap
if [[ "$confirm_swap" == "Y" || "$confirm_swap" == "y" ]]; then
    # Disable swap for the current session
    swapoff -a
    # Make the change permanent by commenting out the swap line in /etc/fstab.
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    print_success "Swap has been disabled."
else
    print_info "Swap not disabled. Note: 'kubeadm init' will fail until this is done."
fi
echo ""

# --- Part 4: System Updates ---

print_border "Step 4: System Updates"
print_info "Applying latest security patches and software updates to the minimal system."
read -p "➡️ Run 'apt update' and 'apt upgrade' now? (Recommended) (Y/N): " confirm_update
if [[ "$confirm_update" == "Y" || "$confirm_update" == "y" ]]; then
    apt-get update && apt-get upgrade -y
    print_success "System is now up to date."
else
    print_info "Skipping system updates."
fi

# --- Final Instructions ---

print_border "🎉 Initial Setup Complete! 🎉"
echo "The system is now configured. A reboot is required to apply all changes."
echo "After rebooting:"
# We need to re-check if migration was performed to give the right instructions.
if [[ "$confirm_migrate" == "Y" || "$confirm_migrate" == "y" ]]; then
    echo "  - The system will be running from the NVMe SSD."
    echo "  - You can securely wipe the old OS from the microSD by running 'clean.sh'."
fi
echo "  - You can connect to this node via SSH at: ssh <your_user>@$STATIC_IP"
echo ""
echo "Run 'sudo reboot' now to finalize the setup."


