#!/bin/bash

# ====================================================================================
#
#               Kubernetes Common Node Setup (k8s_node.sh)
#
# ====================================================================================
#
#  Purpose:
#  --------
#  This script installs all the common dependencies required for a machine to
#  act as a Kubernetes node, regardless of whether it will be a control plane or
#  a worker. It handles the container runtime and the core K8s packages.
#
#  Tutorial Goal:
#  --------------
#  With our machine's OS hardened and configured, it's time to install the
#  Kubernetes-specific software. This involves two main components:
#  1. The Container Runtime (we'll use 'containerd'): This is the engine that
#     actually runs the containers.
#  2. Kubernetes Packages (`kubeadm`, `kubelet`, `kubectl`): These are the tools
#     that connect the node to the cluster and allow it to be managed.
#
#  Workflow:
#  ---------
#  - This script should be run on EVERY node you intend to add to the cluster.
#  - It must be run AFTER `init_headless.sh` is complete.
#
# ====================================================================================


# --- Helper Functions for Better Output ---

readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'

print_success() {
    echo -e "${C_GREEN}[OK] $1${C_RESET}"
}
print_error() {
    echo -e "${C_RED}[ERROR] $1${C_RESET}"
}
print_info() {
    echo -e "${C_YELLOW}[INFO] $1${C_RESET}"
}
print_border() {
    echo ""
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo " $1"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
}


# --- Initial Sanity Checks ---

print_border "Step 0: Pre-flight Checks"

if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run with root privileges. Please use 'sudo'."
    exit 1
fi
print_success "Running as root."

if [ -z "$(swapon --show)" ]; then
    print_success "Swap is disabled, as required by Kubernetes."
else
    print_error "Swap is still active. Please run 'init_headless.sh' to disable it before proceeding."
    exit 1
fi


# --- Part 1: Install Container Runtime (containerd) ---

print_border "Step 1: Installing Container Runtime (containerd)"

# --- Tutorial: Kernel Modules and Network Settings for Containers ---
# Kubernetes networking is complex. For it to work, the Linux kernel on each node
# needs to be able to correctly handle container network traffic.
# `overlay`: This is a filesystem driver that allows containers to efficiently
#            layer filesystems, which is fundamental to how container images work.
# `br_netfilter`: This module allows the Linux bridge (which connects containers
#                 to the network) to pass traffic through the host's firewall
#                 (`iptables`), making container traffic visible and manageable.
# `net.bridge.bridge-nf-call-iptables = 1`: This sysctl setting explicitly enables
# the functionality provided by the `br_netfilter` module.
#
# See: https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd
# ---
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system
print_success "Kernel modules loaded and network settings applied."

print_info "Installing containerd..."
apt-get update && apt-get install -y containerd
print_success "containerd installed."

# --- Tutorial: Configuring containerd's Cgroup Driver ---
# A 'cgroup' (control group) is a Linux kernel feature that limits and isolates
# the resource usage (CPU, memory, etc.) of a process or group of processes.
# Both the container runtime (containerd) and the kubelet need to agree on which
# 'cgroup driver' to use to manage these limits. The modern standard is `systemd`.
# Here, we generate containerd's default config file and then modify it to ensure
# it uses the `systemd` driver, matching what the kubelet expects.
#
# See: https://kubernetes.io/docs/setup/production-environment/container-runtimes/#cgroup-drivers
# ---
print_info "Configuring containerd to use the systemd cgroup driver..."
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd
print_success "containerd configured and restarted."


# --- Part 2: Install Kubernetes Packages ---

print_border "Step 2: Installing Kubernetes Packages (kubeadm, kubelet, kubectl)"

# --- Tutorial: Installing Kubernetes Components ---
# `kubelet`: The primary agent that runs on each node. It receives instructions
#            from the control plane and is responsible for starting/stopping
#            containers.
# `kubeadm`: A tool that provides the `init` and `join` commands to easily
#            bootstrap a Kubernetes cluster.
# `kubectl`: The command-line tool used by administrators to interact with the
#            cluster (e.g., `kubectl get pods`).
#
# We install these from Google's official package repositories to ensure we are
# getting authentic, up-to-date versions. We also 'hold' the packages to prevent
# your OS's package manager from automatically upgrading them, which could lead
# to cluster version mismatches and instability.
#
# See: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
# ---
print_info "Adding Kubernetes APT repository..."
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg

# The directory /etc/apt/keyrings is the new standard location for GPG keys.
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

print_info "Installing kubelet, kubeadm, and kubectl..."
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
print_success "Kubernetes packages installed and held."


# --- Final Instructions ---

print_border "Common Node Setup Complete"
print_success "This node is now ready to join a Kubernetes cluster."
echo "Next steps:"
echo "  - If this is your FIRST control plane node, run 'k8s_control_plane.sh' on it now."
echo "  - If this is a worker node (or a subsequent control plane), run 'k8s_worker.sh' on it."

