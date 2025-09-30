#!/bin/bash

# =============================================
# Jetson Kubernetes Setup Script - Part 1 (Corrected)
# =============================================
# This script automates the initial setup of a
# Nvidia Jetson for Kubernetes clustering.
# It enables SSH, sets a static IP using nmcli,
# and disables the GUI for headless operation.
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
systemctl enable --now ssh > /dev/null 2>&1
systemctl is-active --quiet ssh && echo "✅ SSH is running." || echo "❌ Failed to start SSH."
echo ""

# --- Step 1b: Configure Static IP using nmcli ---
print_border "---- Configuring Network ----"

# --- Detect active network interface and connection name ---
INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
if [[ -z "$INTERFACE" ]]; then
    echo "❌ ERROR: No active network interface found. Is the Ethernet cable plugged in?"
    exit 1
fi

CONNECTION_NAME=$(nmcli -t -f NAME,DEVICE con show --active | grep -E ":$INTERFACE$" | cut -d: -f1)
if [[ -z "$CONNECTION_NAME" ]]; then
    echo "❌ ERROR: Could not find a NetworkManager connection for interface '$INTERFACE'."
    exit 1
fi

# --- Get network details for configuration ---
GATEWAY_IP=$(ip route | awk '/default/ {print $3; exit}')
SUBNET=$(ip -o -f inet addr show "$INTERFACE" | awk '/scope global/ {print $4}' | cut -d'/' -f1 | cut -d'.' -f1-3)

echo "Detected Network Details:"
echo "  - Connection: '$CONNECTION_NAME' on interface '$INTERFACE'"
echo "  - Gateway:    $GATEWAY_IP"
echo "  - Subnet:     $SUBNET.0/24"
echo ""
echo "Suggested IP range for static assignment: $SUBNET.200-$SUBNET.249"
echo "(Control planes: .240-.249, Workers: .200-.239)"
echo ""

# --- Prompt for IP ---
read -p "➡️ Enter the last octet of the static IP (200-249): " ip_octet
if ! [[ "$ip_octet" =~ ^[0-9]+$ ]] || [[ "$ip_octet" -lt 200 || "$ip_octet" -gt 249 ]]; then
    echo "❌ Invalid IP octet. Must be a number between 200 and 249."
    exit 1
fi

STATIC_IP="$SUBNET.$ip_octet"
echo "🔧 Configuring static IP: $STATIC_IP"

# --- Use nmcli to set the static IP ---
nmcli con mod "$CONNECTION_NAME" ipv4.method manual \
    ipv4.addresses "${STATIC_IP}/24" \
    ipv4.gateway "$GATEWAY_IP" \
    ipv4.dns "8.8.8.8,8.8.4.4"

# --- Apply the changes by restarting the connection ---
echo "Applying network settings..."
nmcli con down "$CONNECTION_NAME" > /dev/null 2>&1 && nmcli con up "$CONNECTION_NAME" > /dev/null 2>&1
echo "✅ Static IP configured."
echo ""

# --- Step 2: Disable GUI ---
print_border "---- Disabling GUI ----"
read -p "Disable the GUI for headless operation? (Y/N): " confirm_gui
if [[ "$confirm_gui" == "Y" || "$confirm_gui" == "y" ]]; then
    echo "Disabling graphical interface..."
    systemctl set-default multi-user.target
    echo "✅ GUI disabled. System will boot to terminal on next reboot."
else
    echo "Skipping GUI disable."
fi
echo ""

# --- Step 3: Update and Upgrade ---
print_border "---- Updating System ----"
echo "This will run 'apt update' and 'apt upgrade'."
read -p "OK to proceed? (Y/N): " confirm_update
if [[ "$confirm_update" == "Y" || "$confirm_update" == "y" ]]; then
    apt-get update && apt-get upgrade -y
    echo "✅ System updated and upgraded."
else
    echo "Skipping update."
fi
echo ""

# --- Final Instructions ---
print_border "---- Setup Complete ----"
echo "1. SSH is enabled and persistent."
echo "2. Static IP is set to $STATIC_IP"
echo "3. GUI status is set. A reboot is required for it to take effect."
echo "4. System is updated (if confirmed)."
echo ""
echo "Reboot the Jetson to apply all changes."

