#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

nmcli con mod "Wired connection 1" ipv4.method manual \
    ipv4.addresses "192.168.50.249/24" \
    ipv4.gateway "192.168.50.1" \
    ipv4.dns "8.8.8.8"

nmcli con down "Wired connection 1" > /dev/null 2>&1 && nmcli con up "Wired connection 1" > /dev/null 2>&1


