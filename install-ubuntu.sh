#!/bin/bash

set -euo pipefail

#----------------------------------------------------
# Configuration
#----------------------------------------------------
SHARE_PATH=$(pwd)

VM_NAME="CSV_PaperCut_Exploit_Demo"
VM_IP="192.168.100.50"
VM_SOURCE_VDI="files/CSV_PaperCut_Exploit_Demo.vdi"
VM_DIR="$HOME/VirtualBox VMs/$VM_NAME"
VM_DISK_PATH="$VM_DIR/$VM_NAME.vdi"

VBOXNET_INTERFACE="vboxnet5"
VBOXNET_IP="192.168.100.10"

GUEST_USER="osboxes"
GUEST_PASS="osboxes.org"

print_warn() {
	echo -e "\e[33m[WARN] $1\e[0m"
}

init() {
	if [ ! -d "files" ] || [ ! -f "$VM_SOURCE_VDI" ] || [ ! -f "files/pcng-setup-19.2.7.62200-linux-x64.sh" ]; then
		echo "Files directory not correctly installed. Exiting..."
		exit 1
	fi
}

provision_vm() {
	VBoxManage createvm --name "$VM_NAME" --ostype "Ubuntu_64" --register --basefolder "$HOME/VirtualBox VMs"

	echo "Copying VDI to VM directory..."
	cp "$VM_SOURCE_VDI" "$VM_DISK_PATH"

	# Configure Hardware
	VBoxManage modifyvm "$VM_NAME" --graphicscontroller vmsvga --vram 128
	VBoxManage modifyvm "$VM_NAME" --cpus 2 --memory 4096
	VBoxManage modifyvm "$VM_NAME" --nic1 nat
	VBoxManage modifyvm "$VM_NAME" --nic2 hostonly --hostonlyadapter2 $VBOXNET_INTERFACE
	VBoxManage modifyvm "$VM_NAME" --natpf1 "guestssh,tcp,,2222,,22"
	VBoxManage modifyvm "$VM_NAME" --natpf1 "papercut,tcp,,8191,,8191"

	# Set static IP for host-only adapter
	VBoxManage hostonlyif ipconfig $VBOXNET_INTERFACE --ip $VBOXNET_IP --netmask 255.255.255.0

	# Storage Controllers
	VBoxManage storagectl "$VM_NAME" --name "SATA Controller" --add sata --controller IntelAhci

	# Attach the EXISTING VDI
	VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$VM_DISK_PATH"

	# Shared Folder
	VBoxManage sharedfolder add "$VM_NAME" --name "vm_share" --hostpath "$SHARE_PATH" --automount

	echo "---------------------------------------------------"
	echo "VM '$VM_NAME' is ready with OsBoxes VDI."
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

	ssh_apt_exec_root() {
		local desc="$1"
		local command="$2"
		ssh_exec_root "[APT] Stop unattended-upgrades service" "systemctl stop unattended-upgrades >/dev/null 2>&1 || true; systemctl stop apt-daily.service >/dev/null 2>&1 || true; systemctl stop apt-daily-upgrade.service >/dev/null 2>&1 || true"
		ssh_exec_root "[APT] Clear dpkg lock" "rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || true"
		ssh_exec_root "[APT] Wait for dpkg to finish" "while pgrep -x 'dpkg|apt-get' >/dev/null; do sleep 1; done"
		local command_with_lock_timeout="${command/apt-get /apt-get -o DPkg::Lock::Timeout=60 }"
		ssh_exec_root "$desc" "$command_with_lock_timeout"
	}

	#----------------------------------------------------
	# Vars
	#----------------------------------------------------
	SHARED_FOLDER="/home/osboxes/host_files"
	PAPERCUT_INSTALLER_SOURCE="${SHARED_FOLDER}/files/pcng-setup-19.2.7.62200-linux-x64.sh"
	PAPERCUT_INSTALLER_TARGET="/home/papercut/pcng-setup-19.2.7.62200-linux-x64.sh"

	PC_HOME="/home/papercut/server"
	BIN_DIR="$PC_HOME/bin/linux-x64"
	CONF_FILE="$PC_HOME/server.properties"

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

	if ssh_exec_root "Check Guest Additions package state" \
		"dpkg-query -W build-essential dkms linux-headers-\$(uname -r) virtualbox-guest-utils virtualbox-guest-x11 >/dev/null 2>&1"; then
		echo "Guest Additions packages already installed; skipping install/reboot."
	else
		ssh_apt_exec_root "Install Guest Additions package lists" "apt-get update"
		ssh_apt_exec_root "Install Guest Additions packages" \
			"apt-get install -y build-essential dkms linux-headers-\$(uname -r) virtualbox-guest-utils virtualbox-guest-x11"

		ssh_exec_root "Reboot after Guest Additions install" "nohup sh -c 'sleep 1; reboot' >/dev/null 2>&1 &"

		echo "Waiting for SSH to come back after reboot..."
		wait_for_ssh
	fi

	ssh_exec_root "Adding papercut user" \
		"id -u papercut >/dev/null 2>&1 || useradd --system --home-dir /home/papercut --create-home --shell /usr/sbin/nologin papercut"

	ssh_exec_root "Create shared folder mount point" "mkdir -p ${SHARED_FOLDER}"
	ssh_exec_root "Mounting shared folder" "mount -t vboxsf vm_share ${SHARED_FOLDER}"

	ssh_exec_root "Copy PaperCut installer to papercut home (if missing)" "if [ ! -f \"${PAPERCUT_INSTALLER_TARGET}\" ]; then cp \"${PAPERCUT_INSTALLER_SOURCE}\" \"${PAPERCUT_INSTALLER_TARGET}\"; else echo '[INFO] Installer already present, skipping copy'; fi"
	ssh_exec_root "Set installer ownership" "chown papercut:papercut ${PAPERCUT_INSTALLER_TARGET}"
	ssh_exec_root "Make PaperCut installer executable" "chmod 755 ${PAPERCUT_INSTALLER_TARGET}"
	ssh_exec_root "Installing PaperCut as papercut user (if not installed)" "if [ ! -x /home/papercut/server/bin/linux-x64/server-command ]; then sudo -u papercut \"${PAPERCUT_INSTALLER_TARGET}\" --non-interactive; else echo '[INFO] PaperCut already installed, skipping installer'; fi"
	ssh_exec_root "Running paperCut as root" "bash /home/papercut/MUST-RUN-AS-ROOT"

	ssh_exec_root "[SSL] Generating certificates" "sudo -u papercut ${BIN_DIR}/create-ssl-keystore -f -keystoreentry standard"
	ssh_exec_root "[SSL] Update the server config to point to the new keystore" \
		"sed -i 's/^server.https.port=.*/server.https.port=9192/' ${CONF_FILE}"
	ssh_exec_root "[SSL] Update the server config to point to the new keystore" \
		"sed -i 's/^server.https.enabled=.*/server.https.enabled=on/' ${CONF_FILE}"

	ssh_apt_exec_root "Update package lists for printer drivers" "apt-get update"
	ssh_apt_exec_root "Installing Printer Drivers" "apt-get install -y cups printer-driver-cups-pdf ghostscript"
    ssh_exec_root "Enabling FileDevice" "echo 'FileDevice Yes' >> /etc/cups/cups-files.conf && systemctl restart cups"
    ssh_exec_root "Adding dummy printer" 'lpadmin -p "Exploit_Printer" -v "file:/tmp/print_output" -m "raw" -E'

	ssh_exec_root "[CUPS] Linking PaperCut backend" \
        "ln -sf /home/papercut/providers/print/linux-x64/cups-print-provider /usr/lib/cups/backend/papercut"
    
    ssh_exec_root "[CUPS] Restarting CUPS to register backend" "systemctl restart cups"

    ssh_exec_root "[PaperCut] Configuring CUPS monitoring" \
        "/home/papercut/providers/print/linux-x64/configure-cups --add-all"
    
	ssh_exec_root "Starting PaperCut with new config" "systemctl start pc-app-server"

	echo "Waiting for PaperCut API to wake up..."
	ssh_exec_root "Port Wait" "while ! nc -z localhost 9191; do echo -n '.'; sleep 3; done"

    ssh_exec_root "Setting PaperCut permissions" "/home/papercut/server/bin/linux-x64/setperms"
    ssh_exec_root "Restarting PaperCut" "systemctl restart pc-app-server.service || true"
	ssh_exec_root "[PaperCut] Final CUPS sync" "/home/papercut/providers/print/linux-x64/configure-cups --add-all"

	echo "Waiting for PaperCut Web Interface to wake up (Port 9191)..."
    while ! nc -z "${VM_IP}" 9191; do   
      echo -n "."
      sleep 3
    done

    echo -e "\n\n---------------------------------------------------"
    echo "SUCCESS: PaperCut is now responding!"
    echo "Access via: http://${VM_IP}:9191/app"
    echo "Exploit Path: http://${VM_IP}:9191/app?service=page/SetupCompleted"
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
