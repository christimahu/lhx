#!/bin/bash

# =============================================
# Jetson Kubernetes Setup Script - Part 1
# =============================================
# This script automates the initial setup of a
# Nvidia Jetson for Kubernetes clustering.
# It enables SSH, sets a static IP, and disables
# the GUI for headless operation.
# =============================================

# --- Ensure script is run as root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use 'sudo'."
    exit 1
fi

# --- ASCII Art for Visual Separation ---
print_border() {
    echo "=-=-=-=-=-=-=-=-=-="
    echo "$1"
    echo "=-=-=-=-=-=-=-=-=-="
}

# --- Step 1a: Enable SSH ---
print_border "---- Enabling SSH ----"
echo "Enabling SSH for headless operation..."
systemctl enable ssh
systemctl start ssh
systemctl is-active --quiet ssh && echo "SSH is running." || echo "Failed to start SSH."

# --- Check SSH Status ---
echo ""
echo "SSH Status:"
systemctl status ssh | grep "Active:"
echo ""

# --- Ask for User Confirmation ---
read -p "SSH is enabled. OK to proceed? (Y/N): " confirm_ssh
if [[ "$confirm_ssh" != "Y" && "$confirm_ssh" != "y" ]]; then
    echo "Exiting script."
    exit 1
fi

# --- Step 1b: Detect Primary Network Interface, Subnet, and Gateway ---
print_border "---- Detecting Network Interface ----"

# --- Detect primary interface (with default route) ---
INTERFACE=$(ip route | awk '/default/ {print $5}')
if [[ -z "$INTERFACE" ]]; then
    echo "No default network interface found. Check your connection."
    exit 1
fi

# --- Detect subnet and gateway ---
SUBNET=$(ip -o -f inet addr show "$INTERFACE" | awk '/scope global/ {print $4}' | cut -d'/' -f1 | cut -d'.' -f1-3)
GATEWAY=$(ip route | awk '/default/ {print $3}' | cut -d'.' -f1-3)

if [[ -z "$SUBNET" || -z "$GATEWAY" ]]; then
    echo "Could not detect subnet or gateway. Using 192.168.1 as fallback."
    SUBNET="192.168.1"
    GATEWAY="192.168.1"
fi

echo "Detected primary interface: $INTERFACE"
echo "Detected subnet: $SUBNET.0/24"
echo "Detected gateway: $GATEWAY.1"
echo ""
echo "Suggested IP range for static assignment: $SUBNET.200-$SUBNET.249"
echo "(Control planes: .240-.249, Workers: .200-.239)"

# --- Prompt for IP ---
read -p "Enter the last octet of the static IP (200-249): " ip_octet
if [[ "$ip_octet" -lt 200 || "$ip_octet" -gt 249 ]]; then
    echo "Invalid IP octet. Must be between 200 and 249."
    exit 1
fi

# --- Configure netplan for static IP ---
echo "Configuring static IP: $SUBNET.$ip_octet on $INTERFACE"
cat > /etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses: [$SUBNET.$ip_octet/24]
      gateway4: $GATEWAY.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
EOF

# --- Apply netplan ---
netplan apply
echo "Static IP set to $SUBNET.$ip_octet on $INTERFACE"
echo ""

# --- Step 4: Disable GUI ---
print_border "---- Disabling GUI ----"
echo "Disabling the graphical interface for headless operation..."
systemctl set-default multi-user.target
echo "GUI disabled. System will boot to terminal."
echo ""

# --- Step 5: Update and Upgrade ---
print_border "---- Updating System ----"
echo "This will run 'apt update' and 'apt upgrade'."
read -p "OK to proceed? (Y/N): " confirm_update
if [[ "$confirm_update" != "Y" && "$confirm_update" != "y" ]]; then
    echo "Skipping update."
else
    apt-get update && apt-get upgrade -y
    echo "System updated and upgraded."
fi

# --- Final Instructions ---
print_border "---- Setup Complete ----"
echo "1. SSH is enabled and persistent."
echo "2. Static IP is set to $SUBNET.$ip_octet on $INTERFACE"
echo "3. GUI is disabled. System will boot to terminal."
echo "4. System is updated (if confirmed)."
echo ""
echo "Reboot the Jetson to apply changes."

