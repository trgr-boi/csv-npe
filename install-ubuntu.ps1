$ErrorActionPreference = "Stop"

$VM_NAME="CSV_PaperCut_Exploit_Demo"
$SOURCE_VDI="files/CSV_PaperCut_Exploit_Demo.vdi" 
$VM_DIR="$env:USERPROFILE\VirtualBox VMs\$VM_NAME"
$DISK_PATH="$VM_DIR/$VM_NAME.vdi"
$SHARE_PATH = (Get-Location).Path
$VM_IP="192.168.100.50"
$GUEST_USER="osboxes"
$GUEST_PASS="osboxes.org"

function Init {
    if (!(Test-Path "files") -or !(Test-Path $SOURCE_VDI)) {
        Write-Host "Files directory not correctly installed. Exiting..."
        exit 1
    }
}

function Provision-VM {
    VBoxManage createvm --name $VM_NAME --ostype "Ubuntu_64" --register --basefolder "$env:USERPROFILE\VirtualBox VMs"

    Write-Host "Copying VDI to VM directory..."
    Copy-Item $SOURCE_VDI $DISK_PATH -Force

    # Configure Hardware
    VBoxManage modifyvm $VM_NAME --graphicscontroller vmsvga --vram 128
    VBoxManage modifyvm $VM_NAME --cpus 2 --memory 4096
    VBoxManage modifyvm $VM_NAME --nic1 nat
    VBoxManage modifyvm $VM_NAME --nic2 hostonly --hostonlyadapter2 $VBOXNET_INTERFACE
    VBoxManage modifyvm $VM_NAME --natpf1 "guestssh,tcp,,2222,,22"
    VBoxManage modifyvm $VM_NAME --natpf1 "papercut,tcp,,8191,,8191"

    # Set static IP for host-only adapter vboxnet5
    VBoxManage hostonlyif ipconfig $VBOXNET_INTERFACE --ip 192.168.100.10 --netmask 255.255.255.0

    # Storage Controllers
    VBoxManage storagectl $VM_NAME --name "SATA Controller" --add sata --controller IntelAhci

    # Attach the EXISTING VDI
    VBoxManage storageattach $VM_NAME --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium $DISK_PATH

    # Shared Folder
    VBoxManage sharedfolder add $VM_NAME --name "papercut_share" --hostpath $SHARE_PATH --automount


    # --- START VM ---
    Write-Host "---------------------------------------------------"
    Write-Host "Starting VM"
    VBoxManage startvm $VM_NAME --type headless

    # --- WAIT FOR SSH ---
    Write-Host "Waiting for SSH to become available"

    $maxRetries = 30
    $retry = 0
    $sshReady = $false

    while (-not $sshReady -and $retry -lt $maxRetries) {
        try {
            $test = Test-NetConnection -ComputerName 127.0.0.1 -Port 2222 -WarningAction SilentlyContinue
            if ($test.TcpTestSucceeded) {
                $sshReady = $true
            } else {
                Start-Sleep -Seconds 5
                $retry++
            }
        } catch {
            Start-Sleep -Seconds 5
            $retry++
        }
    }

    if (-not $sshReady) {
        Write-Host "SSH not available after waiting. Exiting"
        exit 1
    }

    Write-Host "SSH is available!"

    # --- RUN COMMANDS VIA SSH (PLINK REQUIRED) ---
    $PLINK = "plink.exe"
    Write-Host "Mounting shared folder inside VM"

    & $PLINK -ssh 127.0.0.1 -P 2222 `
        -l $GUEST_USER `
        -pw $GUEST_PASS `
        -batch `
        "echo $GUEST_PASS | sudo -S mkdir -p /mnt/papercut_share && echo $GUEST_PASS | sudo -S mount -t vboxsf papercut_share /mnt/papercut_share"

    & $PLINK -ssh 127.0.0.1 -P 2222 `
        -l $GUEST_USER `
        -pw $GUEST_PASS `
        -batch `
        "chmod +x /mnt/papercut_share/papercut.sh && /mnt/papercut_share/papercut.sh"


    Write-Host "Done! Shared folder should be mounted."
    Write-Host "---------------------------------------------------"
	Write-Host "VM '$VM_NAME' is ready with OsBoxes VDI."
    
}

function Get-HostOnlyAdapters {
    VBoxManage list hostonlyifs |
        ForEach-Object {
            if ($_ -match "Name:\s+(.*)") {
                $name = $matches[1]

                if ($name -notmatch "^HostInterfaceNetworking") {
                    $name
                }
            }
        }
}

function Select-HostOnlyAdapter {
    $adapters = Get-HostOnlyAdapters

    if (-not $adapters -or $adapters.Count -eq 0) {
        throw "No host-only adapters found."
    }

    Write-Host "Available Host-Only Adapters:`n"

    for ($i = 0; $i -lt $adapters.Count; $i++) {
        Write-Host "[$i] $($adapters[$i])"
    }

    $choice = Read-Host "`nSelect adapter number"
    $index = [int]$choice

    if ($index -lt 0 -or $index -ge $adapters.Count) {
        throw "Invalid selection."
    }

    return $adapters[$index]
}

# MAIN
Init
$VBOXNET_INTERFACE=Select-HostOnlyAdapter
$vmExists = VBoxManage list vms | Select-String -Pattern $VM_NAME
if (-not $vmExists) {
    Provision-VM
} else {
    Write-Host "VM '$VM_NAME' already exists; skipping provisioning."
}