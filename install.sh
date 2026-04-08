#!/bin/bash

set -euo pipefail

VM_NAME="CSV_PaperCut_Exploit_Demo"
SOURCE_VDI="files/CSV_PaperCut_Exploit_Demo.vdi" 
VM_DIR="$HOME/VirtualBox VMs/$VM_NAME"
DISK_PATH="$VM_DIR/$VM_NAME.vdi"
SHARE_PATH=$(pwd)

VBOXNET_INTERFACE="vboxnet5"

VM_IP="192.168.100.50"
GUEST_USER="osboxes"
GUEST_PASS="osboxes.org"

init() {
	if [ ! -d "files" ] || [ ! -f "$SOURCE_VDI" ] || [ ! -f "files/pcng-setup-19.2.7.62200-linux-x64.sh" ]; then
		echo "Files directory not correctly installed. Exiting..."
		exit 1
	fi
}

provision_vm() {

	#----------------------------------------------------
	# Helper Functions
	#----------------------------------------------------
	remove_known_host() {
 		ssh-keygen -f "$HOME/.ssh/known_hosts" -R 192.168.100.50 >/dev/null 2>&1 || true
	}

	#----------------------------------------------------
	# Main Script
	#----------------------------------------------------
	ubuntu_VM() {
		VBoxManage createvm --name "$VM_NAME" --ostype "Ubuntu_64" --register --basefolder "$HOME/VirtualBox VMs"

		echo "Copying VDI to VM directory..."
		cp "$SOURCE_VDI" "$DISK_PATH"

		# Configure Hardware
		VBoxManage modifyvm "$VM_NAME" --graphicscontroller vmsvga --vram 128
		VBoxManage modifyvm "$VM_NAME" --cpus 2 --memory 4096
		VBoxManage modifyvm "$VM_NAME" --nic1 nat
		VBoxManage modifyvm "$VM_NAME" --nic2 hostonly --hostonlyadapter2 $VBOXNET_INTERFACE
		VBoxManage modifyvm "$VM_NAME" --natpf1 "guestssh,tcp,,2222,,22"
		VBoxManage modifyvm "$VM_NAME" --natpf1 "papercut,tcp,,8191,,8191"

		# Set static IP for host-only adapter vboxnet5
		VBoxManage hostonlyif ipconfig $VBOXNET_INTERFACE --ip 192.168.100.10 --netmask 255.255.255.0

		# Storage Controllers
		VBoxManage storagectl "$VM_NAME" --name "SATA Controller" --add sata --controller IntelAhci

		# Attach the EXISTING VDI
		VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$DISK_PATH"

		# Shared Folder
		VBoxManage sharedfolder add "$VM_NAME" --name "papercut_share" --hostpath "$SHARE_PATH" --automount

		echo "---------------------------------------------------"
		echo "VM '$VM_NAME' is ready with OsBoxes VDI."
	}

	# kali_vm() {
		# TODO: add kali vm with ip `192.168.100.60/24`
		#
		# **/etc/network/intefaces**
		# auto eth0
		# iface eth0 inet dhcp
		#
		# auto eth1
		# iface eth1 inet static
    	# 	address 192.168.100.60
    	#	netmask 255.255.255.0

	# }

	ubuntu_VM
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
		# Helper for SSH commands that need sudo
		local desc="$1"
		local command="$2"
		local escaped_command="${command//\'/\'\\\'\'}"
		echo "[SSH] $desc"
		sshpass -p "$GUEST_PASS" ssh -o StrictHostKeyChecking=no \
			"$GUEST_USER@${VM_IP}" "echo '$GUEST_PASS' | sudo -S -p '' bash -lc '$escaped_command'"
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
		echo "VM '${VM_NAME}' is already running; skipping startvm."
	fi

	echo "Waiting for host-only network to respond..."
    wait_for_ssh

	if ssh_exec_root "Check Guest Additions package state" \
		"dpkg-query -W build-essential dkms linux-headers-\$(uname -r) virtualbox-guest-utils virtualbox-guest-x11 >/dev/null 2>&1"; then
		echo "Guest Additions packages already installed; skipping install/reboot."
	else
		ssh_exec_root "Install Guest Additions package lists" "apt-get update"
		ssh_exec_root "Install Guest Additions packages" \
			"apt-get install -y build-essential dkms linux-headers-\$(uname -r) virtualbox-guest-utils virtualbox-guest-x11"

		ssh_exec_root "Reboot after Guest Additions install" "nohup sh -c 'sleep 1; reboot' >/dev/null 2>&1 &"

		echo "Waiting for SSH to come back after reboot..."
		wait_for_ssh
	fi

	ssh_exec_root "Adding papercut user" \
		"id -u papercut >/dev/null 2>&1 || useradd --system --home-dir /home/papercut --create-home --shell /usr/sbin/nologin papercut"

	ssh_exec_root "Create shared folder mount point" "mkdir -p ${SHARED_FOLDER}"
	ssh_exec_root "Mounting shared folder" "mount -t vboxsf papercut_share ${SHARED_FOLDER}"

	ssh_exec_root "Copy PaperCut installer to papercut home" "cp ${PAPERCUT_INSTALLER_SOURCE} ${PAPERCUT_INSTALLER_TARGET}"
	ssh_exec_root "Set installer ownership" "chown papercut:papercut ${PAPERCUT_INSTALLER_TARGET}"
	ssh_exec_root "Make PaperCut installer executable" "chmod 755 ${PAPERCUT_INSTALLER_TARGET}"
	ssh_exec_root "Installing PaperCut as papercut user" "sudo -u papercut ${PAPERCUT_INSTALLER_TARGET} --non-interactive"
	ssh_exec_root "Running paperCut as root" "bash /home/papercut/MUST-RUN-AS-ROOT"

	ssh_exec_root "[SSL] Generating certificates" "sudo -u papercut ${BIN_DIR}/create-ssl-keystore -f -keystoreentry standard"
	ssh_exec_root "[SSL] Update the server config to point to the new keystore" \
		"sed -i 's/^server.https.port=.*/server.https.port=9192/' ${CONF_FILE}"
	ssh_exec_root "[SSL] Update the server config to point to the new keystore" \
		"sed -i 's/^server.https.enabled=.*/server.https.enabled=on/' ${CONF_FILE}"

    ssh_exec_root "Installing Printer Drivers" "apt-get update && apt-get install -y cups printer-driver-cups-pdf ghostscript"
    ssh_exec_root "Enabling FileDevice" "echo 'FileDevice Yes' >> /etc/cups/cups-files.conf && systemctl restart cups"
    ssh_exec_root "Adding dummy printer" 'lpadmin -p "Exploit_Printer" -v "file:/tmp/print_output" -m "raw" -E'

	ssh_exec_root "[CUPS] Linking PaperCut backend" \
        "ln -sf /home/papercut/providers/print/linux-x64/cups-print-provider /usr/lib/cups/backend/papercut"
    
    ssh_exec_root "[CUPS] Restarting CUPS to register backend" "systemctl restart cups"

    ssh_exec_root "[PaperCut] Configuring CUPS monitoring" \
        "/home/papercut/providers/print/linux-x64/configure-cups --add-all"
    
    # --- UNLOCKING EXPLOIT CAPABILITIES ---
    ssh_exec_root "Stopping PaperCut to unlock DB" "systemctl stop pc-app-server"

    ssh_exec_root "[Config] Enabling Global Scripting" \
        "echo 'y' | sudo -u papercut /home/papercut/server/bin/linux-x64/db-tools set-config print-and-device.script.enabled Y"
    
    ssh_exec_root "[Config] Disabling Script Sandbox" \
        "echo 'y' | sudo -u papercut /home/papercut/server/bin/linux-x64/db-tools set-config print.script.sandboxed N"

    ssh_exec_root "Starting PaperCut with new config" "systemctl start pc-app-server"

	echo "Waiting for PaperCut API to wake up..."
    ssh_exec_root "Port Wait" "while ! nc -z localhost 9191; do echo -n '.'; sleep 3; done"

	# Create an internal user (Username: admin, Pass: Admin123)
	ssh_exec_root "Checking/Creating Admin User" \
        "/home/papercut/server/bin/linux-x64/server-command user-exists 'admin' || \
        /home/papercut/server/bin/linux-x64/server-command add-new-internal-user 'admin' 'Admin123' 'System Admin' 'admin@local.test' '' ''"

    # Grant that user full Admin Access
    ssh_exec_root "Granting Admin Rights" \
        "/home/papercut/server/bin/linux-x64/server-command add-admin-access-user 'admin'"

    ssh_exec_root "Setting PaperCut permissions" "/home/papercut/server/bin/linux-x64/setperms"
    ssh_exec_root "Restarting PaperCut" "systemctl restart pc-app-server.service || true"

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
	echo "VM '${VM_NAME}' already exists; skipping provisioning."
fi

configure_vm
