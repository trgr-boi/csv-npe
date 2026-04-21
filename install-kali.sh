#!/bin/bash

set -euo pipefail

#----------------------------------------------------
# Configuration
#----------------------------------------------------
SHARE_PATH=$(pwd)

VM_NAME="CSV_Kali_Demo"
VM_IP="192.168.100.60"
VM_SOURCE_VDI="files/CSV_Kali_Demo.vdi"
VM_DIR="$HOME/VirtualBox VMs/$VM_NAME"
VM_DISK_PATH="$VM_DIR/$VM_NAME.vdi"

VBOXNET_INTERFACE="vboxnet5"

GUEST_USER="kali"
GUEST_PASS="kali"

print_warn() {
	echo -e "\e[33m[WARN] $1\e[0m"
}

init() {
	if [ ! -f "$VM_SOURCE_VDI" ]; then
		echo "Kali VDI not found at '$VM_SOURCE_VDI'. Exiting..."
		exit 1
	fi

	if [ ! -d "kali-shared-folder" ]; then
		print_warn "kali-shared-folder directory not found; shared-folder mount may fail."
	fi
}

provision_vm() {
	VBoxManage createvm --name "$VM_NAME" --ostype "Debian_64" --register --basefolder "$HOME/VirtualBox VMs"

	echo "Copying Kali VDI to VM directory..."
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

	# Shared Folder (Kali tools/scripts only)
	VBoxManage sharedfolder add "$VM_NAME" --name "vm_share" --hostpath "$SHARE_PATH/kali-shared-folder" --automount

	echo "---------------------------------------------------"
	echo "VM '$VM_NAME' is ready with Kali VDI."
}

configure_vm() {
	#----------------------------------------------------
	# Helper Functions
	#----------------------------------------------------
	is_vm_running() {
		VBoxManage list runningvms | grep -Fq "\"${VM_NAME}\""
	}

	wait_for_ssh() {
        echo "Waiting for SSH to be ready on ${VM_IP}..."

		sleep 2
        while true; do
            if sshpass -p "$GUEST_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "$GUEST_USER@${VM_IP}" "echo ready" >/dev/null 2>&1; then
                echo " SSH is ready!"
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
	# Main Part
	#----------------------------------------------------
	if ! is_vm_running; then
		VBoxManage startvm "$VM_NAME" --type headless
	else
		print_warn "VM '${VM_NAME}' is already running; skipping startvm."
	fi

	echo "Waiting for host-only network to respond..."
    wait_for_ssh

	# Mount shared folder
	SHARED_FOLDER="/home/kali/host_files"
	ssh_exec_root "Create Kali shared folder mount point" "mkdir -p ${SHARED_FOLDER}"
	ssh_exec_root "Mount Kali shared folder" "mountpoint -q ${SHARED_FOLDER} || mount -t vboxsf vm_share ${SHARED_FOLDER}"
	ssh_exec_root "Copy Kali shared files into /home/kali" "sudo -u ${GUEST_USER} cp -a ${SHARED_FOLDER}/. /home/kali/"

	echo -e "\n\n---------------------------------------------------"
	echo "SUCCESS: Kali VM is ready!"
	echo "IP: ${VM_IP}"
	echo "User: ${GUEST_USER}"
	echo "Shared folder mounted at: ${SHARED_FOLDER}"
	echo "---------------------------------------------------"
}

# Main
init
if ! VBoxManage list vms | grep -Fq "\"${VM_NAME}\""; then
	provision_vm
else
	print_warn "VM '${VM_NAME}' already exists; skipping provisioning."
fi

configure_vm
