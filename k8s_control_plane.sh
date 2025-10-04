#!/bin/bash

# ====================================================================================
#
#            Kubernetes Control Plane Setup (k8s_control_plane.sh)
#
# ====================================================================================
#
#  Purpose:
#  --------
#  This script bootstraps the Kubernetes control plane on the **first** control
#  plane node. It initializes the cluster, sets up `kubectl` access, and installs
#  the crucial network plugin (CNI).
#
#  Tutorial Goal:
#  --------------
#  This is the moment of creation! We will use `kubeadm init` to bring our
#  cluster to life. This process generates the necessary certificates and configs,
#  starts the core control plane components (API server, scheduler, etc.) as
#  static pods, and prepares the cluster for networking and worker nodes.
#
#  Workflow:
#  ---------
#  - Run this script ONLY on the first machine designated as a control plane.
#  - It must be run AFTER `k8s_node.sh` is complete.
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

# --- Part 1: Initialize the Kubernetes Cluster ---

print_border "Step 1: Initialize the Kubernetes Control Plane"

# --- Tutorial: `kubeadm init` Parameters ---
# `kubeadm init` is the command that bootstraps the cluster.
# `--pod-network-cidr`: This is a crucial parameter. It defines the private IP
#   address range from which pods will be assigned their own IPs. This range must
#   not conflict with your physical network's IP range. The CNI plugin we install
#   later (Calico) must be configured to use this same CIDR block. `10.244.0.0/16`
#   is a common choice.
#
# See: https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/
# ---
IP_ADDR=$(hostname -I | awk '{print $1}')
print_info "Initializing cluster on this node ($IP_ADDR)... This will take a few minutes."
kubeadm init --pod-network-cidr=10.244.0.0/16

if [ $? -ne 0 ]; then
    print_error "kubeadm init failed. Please check the output above for errors."
    exit 1
fi
print_success "Control plane initialized successfully."


# --- Part 2: Configure kubectl Access ---
print_border "Step 2: Configure kubectl for Cluster Administration"

# --- Tutorial: The `kubeconfig` File ---
# The `kubeadm init` process generates a file called `admin.conf`. This file
# contains the cluster's details and the administrative credentials needed to
# connect to it. `kubectl` looks for this information in a file named `config`
# inside a `.kube` directory in your home directory. These next commands copy
# the file to the correct location and set its ownership so you can run `kubectl`
# as a regular user without needing `sudo`.
# ---
print_info "Setting up kubeconfig for the current user..."
mkdir -p "$HOME/.kube"
cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"
print_success "kubectl is now configured. Try 'kubectl get nodes'."


# --- Part 3: Install the Pod Network (CNI) ---

print_border "Step 3: Install a Pod Network Add-on (Calico CNI)"

# --- Tutorial: Why We Need a CNI Plugin ---
# A fresh Kubernetes cluster has a functioning control plane, but the nodes
# cannot communicate with each other yet. A Container Network Interface (CNI)
# plugin is required to create a "pod network" that allows containers on
# different nodes to communicate as if they were on the same virtual network.
# Without a CNI, your pods will be stuck in a "ContainerCreating" state and your
# nodes will remain in a "NotReady" status. We are using Calico, a popular CNI
# that is efficient and supports advanced features like network policies.
#
# See: https://docs.projectcalico.org/getting-started/kubernetes/quickstart
# ---
print_info "Installing Calico Operator for pod networking..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

# The default Calico installation expects the CIDR we specified in kubeadm init.
# We apply the custom resource definition that tells the operator to create the Calico deployment.
print_info "Applying Calico custom resource definition..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml

print_info "Waiting for Calico pods to start... This may take a minute."
sleep 10 # Give the operator a moment to start creating pods.
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n calico-system --timeout=300s
print_success "Calico CNI installed and running."


# --- Final Instructions ---
print_border "Control Plane Setup Complete!"
print_success "Your Kubernetes cluster is up and running."
echo ""
print_info "IMPORTANT: To add more nodes to the cluster, run the following commands:"
echo ""

# The `kubeadm token create` command with `--print-join-command` is the most reliable
# way to generate a fresh, long-lasting join command.
JOIN_COMMAND=$(kubeadm token create --print-join-command)
echo "  - To add a NEW WORKER node, run this command on the worker:"
echo "    ----------------------------------------------------------"
echo "    sudo $JOIN_COMMAND"
echo "    ----------------------------------------------------------"
echo ""

# To get the command for joining another control plane, we need the certificate key.
CERT_KEY=$(kubeadm init phase upload-certs --upload-certs | tail -n1)
echo "  - To add a NEW CONTROL PLANE node, run this command on it:"
echo "    ----------------------------------------------------------"
echo "    sudo $JOIN_COMMAND --control-plane --certificate-key $CERT_KEY"
echo "    ----------------------------------------------------------"
echo ""
echo "Save these commands. You will need them for the 'k8s_worker.sh' script."

