#!/bin/bash
#
# Template for adding a new VM to the CSV-PVE setup
# 
# Instructions:
# 1. Copy this file to install-<vmname>.sh
# 2. Update the Configuration section with your VM details
# 3. Implement the configure_vm() section with your custom setup
# 4. Run: chmod +x install-<vmname>.sh && ./install-<vmname>.sh

set -euo pipefail

#----------------------------------------------------
# Configuration - CUSTOMIZE THIS SECTION
#----------------------------------------------------
SHARE_PATH=$(pwd)

VM_NAME="MY_VM_NAME"                              # e.g., "CSV_MyApp_Demo" (same as dvi name)
VM_IP="192.168.100.XX"                            # e.g., "192.168.100.70"
VM_SOURCE_VDI="files/MY_VM_NAME.vdi"             # Path to VDI file
VM_DIR="$HOME/VirtualBox VMs/$VM_NAME"
VM_DISK_PATH="$VM_DIR/$VM_NAME.vdi"

VBOXNET_INTERFACE="vboxnet5"                      # Shared host-only network
VBOXNET_IP="192.168.100.10"                       # Host adapter IP (if needed)

GUEST_USER="defaultuser"                          # VM default user
GUEST_PASS="defaultpass"                          # VM default password

#----------------------------------------------------
# Utility Functions - DO NOT MODIFY
#----------------------------------------------------
print_warn() {
	echo -e "\e[33m[WARN] $1\e[0m"
}

print_info() {
	echo -e "\e[32m[INFO] $1\e[0m"
}

init() {
	if [ ! -f "$VM_SOURCE_VDI" ]; then
		echo "VDI file not found at '$VM_SOURCE_VDI'. Exiting..."
		exit 1
	fi
}

provision_vm() {
	print_info "Creating VM: $VM_NAME"
	VBoxManage createvm --name "$VM_NAME" --ostype "Ubuntu_64" --register --basefolder "$HOME/VirtualBox VMs"

	echo "Copying VDI to VM directory..."
	mkdir -p "$VM_DIR"
	cp "$VM_SOURCE_VDI" "$VM_DISK_PATH"

	# Configure Hardware
	VBoxManage modifyvm "$VM_NAME" --graphicscontroller vmsvga --vram 128
	VBoxManage modifyvm "$VM_NAME" --cpus 2 --memory 4096
	VBoxManage modifyvm "$VM_NAME" --nic1 nat
	VBoxManage modifyvm "$VM_NAME" --nic2 hostonly --hostonlyadapter2 $VBOXNET_INTERFACE

	# Storage Controllers
	VBoxManage storagectl "$VM_NAME" --name "SATA Controller" --add sata --controller IntelAhci

	# Attach the EXISTING VDI
	VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$VM_DISK_PATH"

	# Shared Folder
	VBoxManage sharedfolder add "$VM_NAME" --name "vm_share" --hostpath "$SHARE_PATH" --automount

	echo "---------------------------------------------------"
	echo "VM '$VM_NAME' provisioned successfully."
	echo "---------------------------------------------------"
}

wait_for_ssh() {
	echo "Waiting for SSH to be ready on ${VM_IP}..."
	sleep 2
	while true; do
		if sshpass -p "$GUEST_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "$GUEST_USER@${VM_IP}" "echo ready" >/dev/null 2>&1; then
			echo "SSH is ready!"
			break
		else
			echo -n "."
			sleep 2
		fi
	done
}

ssh_exec_root() {
	local desc="$1"
	local command="$2"
	local escaped_command="${command//\'/\'\\\'\'}"
	echo -e "\e[32m[SSH] $desc\e[0m"
	sshpass -p "$GUEST_PASS" ssh -o StrictHostKeyChecking=no \
		"$GUEST_USER@${VM_IP}" "echo '$GUEST_PASS' | sudo -S -p '' bash -lc '$escaped_command'"
}

#----------------------------------------------------
# Configuration Function - CUSTOMIZE THIS SECTION
#----------------------------------------------------
configure_vm() {
	is_vm_running() {
		VBoxManage list runningvms | grep -Fq "\"${VM_NAME}\""
	}

	# Start the VM
	if ! is_vm_running; then
		VBoxManage startvm "$VM_NAME" --type headless
	else
		print_warn "VM '${VM_NAME}' is already running; skipping startvm."
	fi

	echo "Waiting for host-only network to respond..."
	wait_for_ssh

	#----------------------------------------------------
	# ADD YOUR CUSTOM CONFIGURATION HERE
	#----------------------------------------------------
	# Example:
	# ssh_exec_root "Install package" "apt-get update && apt-get install -y mypackage"
	# ssh_exec_root "Configure something" "echo 'config' > /etc/myconfig.conf"

	echo -e "\n\n---------------------------------------------------"
	echo "SUCCESS: VM configuration complete!"
	echo "VM Name: ${VM_NAME}"
	echo "IP Address: ${VM_IP}"
	echo "User: ${GUEST_USER}"
	echo "---------------------------------------------------"
}

#----------------------------------------------------
# Main Execution
#----------------------------------------------------
init
if ! VBoxManage list vms | grep -Fq "\"${VM_NAME}\""; then
	provision_vm
else
	print_warn "VM '${VM_NAME}' already exists; skipping provisioning."
fi

configure_vm
