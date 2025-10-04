#!/bin/bash

# ====================================================================================
#
#                    Jetson Kubernetes Node Initializer (init_headless.sh)
#
# ====================================================================================
#
#  Purpose:
#  --------
#  This script is a comprehensive, "first-run" utility designed to transform a
#  freshly-imaged NVIDIA Jetson device into a hardened, headless server optimized
#  for use as a Kubernetes node. It automates all the essential "Day 0" setup
#  tasks, ensuring a consistent and reliable foundation for your cluster.
#
#  Tutorial Goal:
#  --------------
#  If you're new to Kubernetes or system administration, this script is your
#  first step. We will walk through preparing a physical machine for a cluster.
#  This involves configuring the network, minimizing the operating system for
#  security and performance, and optimizing storage—all prerequisites for a
#  stable Kubernetes environment.
#
#  Workflow:
#  ---------
#  1. Flash a microSD card with the latest Jetson JetPack OS.
#  2. Boot the Jetson, complete the initial Ubuntu user setup, and connect to Ethernet.
#  3. Clone the repository containing this script onto the Jetson.
#  4. Run this script: `sudo ./init_headless.sh`
#  5. After it completes, reboot the device. The Jetson is now a prepared node.
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
    echo -e "${C_GREEN}[OK] $1${C_RESET}"
}

# Prints a message in red, indicating an error.
print_error() {
    echo -e "${C_RED}[ERROR] $1${C_RESET}"
}

# Prints a message in yellow, for warnings or general information.
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

print_border "Step 0: Pre-flight Checks"

# This script performs actions that require system-wide permissions.
# We check if the user's ID is 0, which is the standard ID for the root user.
# The `id -u` command prints the numeric user ID of the current user.
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run with root privileges. Please use 'sudo'."
    exit 1
fi
print_success "Running as root."

# We need an internet connection to download system updates and packages.
# This command sends one (`-c 1`) ICMP packet to google.com with a timeout
# of 3 seconds (`-W 3`). If it fails, we assume no internet connection.
# The `&> /dev/null` part redirects all output (stdout and stderr) to a null
# device, so the ping command itself doesn't clutter the terminal.
if ! ping -c 1 -W 3 google.com &> /dev/null; then
    print_error "No internet connection detected. Please check your network cable and connection."
    exit 1
fi
print_success "Internet connection is active."

# CRITICAL SAFETY CHECK: This is the most important check to ensure the script
# is idempotent (safe to re-run). If the system is already booting from an NVMe
# device, we can assume the setup process is complete and we should exit immediately
# to prevent any accidental, destructive actions.
print_info "Checking current boot device..."
# `findmnt` is a utility to find mounted filesystems.
# `-n` removes the header, `-o SOURCE` specifies we only want the source device name,
# and `/` indicates we are querying the root filesystem.
CURRENT_ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$CURRENT_ROOT_DEV" == *"nvme"* ]]; then
    print_success "System is already running from the NVMe SSD."
    print_info "It appears the initial setup has already been completed. Exiting now to prevent accidental changes."
    exit 0 # Exit with status 0, indicating success.
fi
print_success "System is running from microSD card. Proceeding with setup."


# --- Part 1: Network Configuration ---

print_border "Step 1: Network Configuration (Static IP)"

# --- Tutorial: Why a Static IP is Critical for Kubernetes ---
# A Kubernetes cluster is a distributed system of multiple machines (nodes).
# The Control Plane (the cluster's brain) needs to reliably communicate with each
# Worker Node. If a node's IP address changes (which can happen with default DHCP
# settings), the Control Plane loses contact with it, marking it as "NotReady".
# This disrupts workloads running on that node and can cause cluster instability.
# By assigning a permanent, static IP, we ensure that each node has a stable,
# predictable address for the lifetime of the cluster. This is a fundamental
# requirement for any server, but especially for the members of a K8s cluster.
# ---

# We need to find the name of the primary network interface (e.g., enP8p1s0).
# The `ip route` command shows the kernel's routing table. We look for the 'default'
# route, which is the path for all traffic not destined for the local network.
# The `awk` command prints the 5th field ('$5') of that line, which is the interface name.
INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
if [[ -z "$INTERFACE" ]]; then
    print_error "Could not detect the primary network interface. Is Ethernet plugged in?"
    exit 1
fi

# Modern Linux systems use NetworkManager to handle connections. Each connection
# has a name (e.g., "Wired connection 1"). We need this name to modify it.
# `nmcli` is the command-line tool for NetworkManager.
CONNECTION_NAME=$(nmcli -t -f NAME,DEVICE con show --active | grep -E ":$INTERFACE$" | cut -d: -f1)
if [[ -z "$CONNECTION_NAME" ]]; then
    print_error "Could not find a NetworkManager connection for interface '$INTERFACE'."
    exit 1
fi

# As a secondary safety check, we see if the IP is already manually configured.
# `nmcli -g` gets the raw value of the 'ipv4.method' property.
METHOD=$(nmcli -g ipv4.method con show "$CONNECTION_NAME")
if [[ "$METHOD" == "manual" ]]; then
    CURRENT_IP=$(nmcli -g IP4.ADDRESS con show "$CONNECTION_NAME" | cut -d'/' -f1)
    print_success "Static IP is already configured: $CURRENT_IP"
    STATIC_IP=$CURRENT_IP
else
    # If the method is 'auto' (DHCP), we proceed with static IP configuration.
    print_info "A server needs a permanent, predictable IP address. We'll now configure one."
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

    read -p "> Enter the last number (octet) for this node's static IP (200-249): " ip_octet
    if ! [[ "$ip_octet" =~ ^[0-9]+$ ]] || [[ "$ip_octet" -lt 200 || "$ip_octet" -gt 249 ]]; then
        print_error "Invalid input. You must enter a number between 200 and 249."
        exit 1
    fi

    STATIC_IP="$SUBNET.$ip_octet"
    echo "Configuring static IP to $STATIC_IP..."
    # This `nmcli` command modifies the connection properties all at once.
    nmcli con mod "$CONNECTION_NAME" ipv4.method manual ipv4.addresses "${STATIC_IP}/24" ipv4.gateway "$GATEWAY_IP" ipv4.dns "8.8.8.8,8.8.4.4"

    # We must restart the connection for the new settings to apply.
    nmcli con down "$CONNECTION_NAME" > /dev/null 2>&1 && nmcli con up "$CONNECTION_NAME" > /dev/null 2>&1
    sleep 2 # Give the network a moment to stabilize.
    print_success "Static IP configured. SSH will be available at: $STATIC_IP"
fi


# --- Part 2: System Customization & Hardening ---

print_border "Step 2: System Customization & Hardening"

# A descriptive hostname makes it easier to identify nodes in your cluster.
CURRENT_HOSTNAME=$(hostname)
print_info "The current hostname is '$CURRENT_HOSTNAME'."
read -p "> Do you want to set a new hostname for this node? (Y/N): " confirm_hostname
if [[ "$confirm_hostname" == "Y" || "$confirm_hostname" == "y" ]]; then
    read -p "> Enter the new hostname (e.g., k8s-worker-1): " new_hostname
    if [ -z "$new_hostname" ]; then
        print_error "Hostname cannot be empty. Skipping."
    else
        echo "Setting hostname to '$new_hostname'..."
        # `hostnamectl` is the modern, systemd-native way to set the system hostname.
        hostnamectl set-hostname "$new_hostname"

        # The `/etc/hosts` file is a legacy file that maps IP addresses to hostnames.
        # The `127.0.1.1` entry is a common Ubuntu convention. If it's not updated
        # with the new hostname, some commands (especially `sudo`) can lag or fail.
        # We use `sed` to find and replace the old name with the new one.
        sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t$new_hostname/g" /etc/hosts
        print_success "Hostname has been set to '$new_hostname'."
    fi
else
    print_info "Skipping hostname change."
fi
echo ""

# --- Tutorial: Removing the Desktop GUI ---
# A server, especially a Kubernetes node, should be as lean as possible. A graphical
# user interface (GUI) consumes significant system resources (RAM, CPU) that are
# better allocated to running your containerized applications. Removing the desktop
# also reduces the system's "attack surface" by eliminating many packages that
# are not necessary for a server, making the system more secure. We will manage
# the node remotely via SSH from now on.
# ---
print_info "To create a lean, secure server, we will remove the desktop GUI and related applications."
read -p "> Remove the full desktop environment? (Highly Recommended) (Y/N): " confirm_remove
if [[ "$confirm_remove" == "Y" || "$confirm_remove" == "y" ]]; then
    echo "Setting boot target to command-line..."
    # systemd uses "targets" to define system states. `graphical.target` includes the
    # GUI, while `multi-user.target` is for a command-line-only (headless) system.
    systemctl set-default multi-user.target

    echo "Removing desktop packages... This may take a few minutes."
    # `ubuntu-desktop` is a "metapackage"; it doesn't contain files itself, but
    # lists all the packages that make up the desktop experience as dependencies.
    # Removing it tells `apt` to remove the entire group. `--purge` also removes
    # system-wide configuration files. `autoremove` cleans up any orphaned dependencies.
    apt-get remove --purge ubuntu-desktop -y && apt-get autoremove --purge -y
    print_success "Desktop environment removed. System will now boot to terminal."
else
    print_info "Skipping desktop removal. The GUI will remain installed."
fi
echo ""

# --- Tutorial: Disabling Swap Memory for Kubernetes ---
# This is a mandatory prerequisite for Kubernetes. The core K8s component on a node,
# the `kubelet`, needs to have absolute control over the node's resources. It is
# designed to know exactly how much memory is available. Swap memory, which uses
# the disk as slower, virtual RAM, makes this accounting difficult and unpredictable.
# If a container starts using swap, its performance becomes erratic, which defeats
# the purpose of Kubernetes' resource management. The kubelet is designed to
# enforce memory limits strictly; if a pod exceeds its memory, it should be terminated
# and restarted, not allowed to slow down the whole system by using disk swap.
#
# For official documentation, see:
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#before-you-begin
# ---
print_info "Kubernetes requires swap memory to be disabled for performance and stability."
read -p "> Disable swap? (This is required for Kubernetes) (Y/N): " confirm_swap
if [[ "$confirm_swap" == "Y" || "$confirm_swap" == "y" ]]; then
    # `swapoff -a` disables all active swap devices for the current session.
    swapoff -a
    
    # To disable traditional disk-based swap permanently, we must edit `/etc/fstab`.
    # This `sed` command finds any line containing "swap" and comments it out.
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    
    # The Jetson OS uses a custom service to manage ZRAM swap. We must stop and disable it.
    print_info "Disabling NVIDIA's ZRAM service..."
    if systemctl list-unit-files | grep -q 'nvzramconfig.service'; then
        systemctl stop nvzramconfig.service
        systemctl disable nvzramconfig.service
        print_success "NVIDIA ZRAM service disabled."
    else
        print_info "NVIDIA ZRAM service not found, assuming it's not in use."
    fi
else
    print_info "Swap not disabled. Note: 'kubeadm init' will fail until this is done."
fi
echo ""

print_info "Applying latest security patches and software updates to the system."
read -p "> Run 'apt update' and 'apt upgrade' now? (Recommended) (Y/N): " confirm_update
if [[ "$confirm_update" == "Y" || "$confirm_update" == "y" ]]; then
    # `apt-get update` refreshes the list of available packages.
    # `apt-get upgrade` installs the newest versions of all packages currently installed.
    # We do this BEFORE migrating to the SSD to ensure we copy an up-to-date system.
    apt-get update && apt-get upgrade -y
    print_success "System is now up to date."
else
    print_info "Skipping system updates."
fi


# --- Part 3: OS Migration to NVMe SSD ---

print_border "Step 3: Migrate OS from microSD to NVMe SSD"

# --- Tutorial: Why Use an SSD Instead of a MicroSD Card? ---
# Reliability and Performance.
# 1. Performance: An NVMe SSD has dramatically faster read/write speeds than a
#    microSD card. In a Kubernetes context, this means faster container image
#    pulls, quicker application startup times, and better performance for any
#    application that writes logs or data to disk.
# 2. Reliability: MicroSD cards are not designed for the constant, small read/write
#    operations of a server OS and are prone to wear and corruption over time.
#    An SSD is built for this workload and is far more reliable for a server that
#    will be running 24/7. We use the microSD card only to boot the system, and
#    then immediately hand off to the SSD for all operations.
# ---
print_info "Running the OS from an SSD is much faster and more reliable than a microSD card."
read -p "> Do you want to migrate the now-minimized and updated OS to an NVMe SSD? (Y/N): " confirm_migrate

if [[ "$confirm_migrate" != "Y" && "$confirm_migrate" != "y" ]]; then
    print_info "Skipping OS migration. The system will continue to run from the microSD card."
else
    # Find the NVMe device by listing block devices (`lsblk`) and filtering for
    # a non-rotational (`ROTA=0`) device with "nvme" in its name.
    SSD_DEVICE=$(lsblk -d -o NAME,ROTA | grep '0' | awk '/nvme/ {print "/dev/"$1}')
    if [ -z "$SSD_DEVICE" ]; then
        print_error "No NVMe SSD detected. Please ensure it is installed correctly. Skipping migration."
    else
        print_success "Detected NVMe SSD at: $SSD_DEVICE"
        echo ""
        echo -e "${C_RED}!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
        echo -e "${C_YELLOW}This next step will completely and IRREVERSIBLY ERASE all data on the SSD.${C_RESET}"
        echo -e "${C_RED}!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
        read -p "> To confirm, please type 'yes': " confirm_erase

        if [[ "$confirm_erase" != "yes" ]]; then
            print_info "Migration aborted by user. The SSD was not touched."
        else
            echo "Preparing the SSD..."
            # `parted` is a powerful disk partitioning tool.
            # `mklabel gpt` creates a new, modern GUID Partition Table.
            # `mkpart ...` creates a new primary partition using the `ext4` filesystem
            # type, starting at 0% and ending at 100% of the disk.
            parted -s "$SSD_DEVICE" mklabel gpt
            parted -s "$SSD_DEVICE" mkpart primary ext4 0% 100%
            sleep 3 # Wait for the kernel to recognize the new partition.
            SSD_PARTITION="${SSD_DEVICE}p1"

            # `mkfs.ext4` creates the actual ext4 filesystem on the new partition.
            mkfs.ext4 "$SSD_PARTITION"
            print_success "SSD has been partitioned and formatted."
            
            echo "Cloning filesystem. This will take several minutes..."
            MOUNT_POINT="/mnt/ssd_root"
            mkdir -p "$MOUNT_POINT"
            mount "$SSD_PARTITION" "$MOUNT_POINT"
            
            # `rsync` is used to synchronize files. Here, we use it to clone the OS.
            # The flags are critical for a perfect copy:
            # -a: archive mode (preserves permissions, ownership, timestamps, etc.)
            # -x: don't cross filesystem boundaries (prevents copying /proc, /sys).
            # -H: preserve hard links.
            # -A: preserve Access Control Lists (ACLs).
            # -X: preserve extended attributes.
            # --exclude: explicitly tells rsync to skip volatile system directories.
            rsync -axHAWX --numeric-ids --info=progress2 --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} / "$MOUNT_POINT"
            print_success "Filesystem cloned successfully."
            
            echo "Updating boot configuration to use the SSD..."
            # Every partition has a Universally Unique Identifier (UUID). Booting with
            # the UUID is more reliable than using device names like /dev/nvme0n1p1,
            # which can sometimes change.
            SSD_UUID=$(blkid -s UUID -o value "$SSD_PARTITION")
            if [ -z "$SSD_UUID" ]; then
                print_error "Could not determine the SSD's UUID. Cannot update boot config."
                umount "$MOUNT_POINT" # Clean up
            else
                # The Jetson's bootloader config is at /boot/extlinux/extlinux.conf.
                # The 'root=' parameter on the APPEND line tells the kernel where to find
                # the root filesystem. We use `sed` to replace the old value
                # (e.g., root=/dev/mmcblk0p1) with the new one (root=UUID=...).
                # See: https://docs.nvidia.com/jetson/archives/r35.5.0/DeveloperGuide/text/SD/Bootloader.html#extlinux-conf
                sed -i "s|root=[^ ]*|root=UUID=$SSD_UUID|" "/boot/extlinux/extlinux.conf"
                umount "$MOUNT_POINT"
                rmdir "$MOUNT_POINT"
                print_success "Boot configuration updated. The system will boot from the SSD."
            fi
        fi
    fi
fi


# --- Final Instructions ---

print_border "Initial Setup Complete"
echo "The system is now configured. A reboot is required to apply all changes."
echo "After rebooting:"
# We need to re-check if migration was performed to give the right instructions.
if [[ "$confirm_migrate" == "Y" || "$confirm_migrate" == "y" ]]; then
    echo "  - The system will be running from the NVMe SSD."
    echo "  - You can securely wipe the old OS from the microSD by running 'clean_microsd.sh'."
fi
# The STATIC_IP variable might not be set if the network was pre-configured,
# so we find it again for the final message.
if [ -z "$STATIC_IP" ]; then
    STATIC_IP=$(hostname -I | awk '{print $1}')
fi
echo "  - You can connect to this node via SSH at: ssh <your_user>@$STATIC_IP"
echo ""
echo "Run 'sudo reboot' now to finalize the setup."


