Jetson Kubernetes Cluster Automation Scripts
This repository contains a suite of scripts to automate the provisioning and configuration of a Kubernetes cluster on NVIDIA Jetson Orin Developer Kits. The goal is to create a repeatable, reliable process for setting up a multi-node cluster suitable for local AI/ML development and homelab experimentation.

The workflow is divided into two main phases:

Phase 1: Foundational Node Setup (Complete): Taking a freshly imaged Jetson device and turning it into a hardened, headless server ready for Kubernetes.

Phase 2: Kubernetes Installation (Next Steps): Installing the container runtime and Kubernetes components onto the prepared nodes.

Hardware Requirements
NVIDIA Jetson Orin Developer Kit(s)

High-endurance microSD card (for initial boot)

NVMe SSD (for the main operating system)

Reliable power supply for each Jetson

Ethernet cables and a network switch

Scripts Overview
This project uses a modular set of scripts to handle different stages of the setup process.

Phase 1: Foundational Setup
init.sh

Purpose: The main, all-in-one initializer script. This is the first and only script run on a fresh Jetson board.

Actions: Configures a static IP, sets a hostname, removes the desktop GUI, disables swap, updates all system packages, and migrates the prepared OS to the NVMe SSD. It is idempotent and safe to re-run on a fresh board.

clean.sh

Purpose: A security-hardening script run after the initial setup and reboot.

Actions: Securely wipes the old OS from the microSD card, leaving only the essential /boot directory. This prevents an attacker with physical access from booting into the old, un-updated OS.

check.sh

Purpose: A non-destructive auditing and verification tool.

Actions: Runs a full suite of health checks to confirm that a node has been configured correctly by init.sh and clean.sh. It verifies the boot device, network settings, headless mode, swap status, and microSD cleanup.

Phase 2: Kubernetes Installation (Future Scripts)
node.sh (To be created)

Purpose: To be run on all nodes (control plane and workers) after the foundational setup is complete.

Actions: Will install the common dependencies required on every Kubernetes node, including a container runtime (e.g., Containerd) and the core Kubernetes packages (kubeadm, kubelet, kubectl).

control.sh (To be created)

Purpose: To be run only on the control plane node.

Actions: Will use kubeadm init to bootstrap the cluster, configure kubectl for the user, and install the CNI (Container Network Interface) plugin for pod networking.

worker.sh (To be created)

Purpose: To be run only on the worker nodes.

Actions: Will execute the kubeadm join command to securely connect the worker node to the control plane.

Workflow: Provisioning a New Node
Follow these steps to take a new Jetson board from a fresh flash to a fully configured, headless Kubernetes node.

Step 1: Flash the MicroSD Card
Download the latest NVIDIA JetPack image for your Jetson Orin model.

Use a tool like Balena Etcher to flash the image onto your microSD card.

Step 2: Initial Boot and Ubuntu Setup
Insert the microSD card and NVMe SSD into the Jetson and power it on.

Connect a monitor and keyboard for this one-time setup.

Follow the on-screen Ubuntu setup prompts: select your language, keyboard layout, time zone, and create your user account (username, password, computer name).

Once you land on the Ubuntu desktop, connect the Jetson to your network with an Ethernet cable.

Step 3: Clone This Repository
Open a terminal on the Jetson's desktop.

Clone this repository to your user's home directory:

git clone <your-repo-url>

Step 4: Run the Initializer Script
Navigate into the cloned repository's directory:

cd <your-repo-name>

Execute the init.sh script with sudo. This is the main setup process and will take several minutes.

sudo ./init.sh

Follow the interactive prompts to set the static IP, hostname, and confirm the destructive actions like GUI removal and SSD formatting.

Step 5: Reboot
After init.sh completes, it will instruct you to reboot. Run the command:

sudo reboot

The Jetson will now reboot. It will not return to the graphical desktop. This is expected. You can now disconnect the monitor and keyboard permanently.

Step 6: Connect via SSH
From your main computer (e.g., your laptop), connect to the Jetson using the static IP you assigned in Step 4.

ssh your_username@your_static_ip

(Optional but Recommended): Set up passwordless SSH access for convenience using ssh-copy-id.

Step 7: Run the Cleanup Script
From your SSH session, navigate back into the repository directory.

Run the clean.sh script to securely wipe the old OS from the microSD card.

cd <your-repo-name>
sudo ./clean.sh

Step 8: Final Verification
Run the check.sh script to confirm that all provisioning steps were successful.

sudo ./check.sh

If all checks show [PASS], the node is fully provisioned and ready for Phase 2.

Next Steps
With the foundational node setup complete, the next phase is to use the future scripts (node.sh, control.sh, worker.sh) to install and configure the Kubernetes cluster components.
