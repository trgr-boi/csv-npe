$ErrorActionPreference = "Stop"

$VM_NAME = "CSV_Kali_Demo"
$SOURCE_VDI = "files/CSV_Kali_Demo.vdi"
$VM_DIR = "$env:USERPROFILE\VirtualBox VMs\$VM_NAME"
$DISK_PATH = "$VM_DIR\$VM_NAME.vdi"
$SHARE_PATH = (Get-Location).Path
$VM_IP = "192.168.100.60"
$GUEST_USER = "kali"
$GUEST_PASS = "kali"

function Init {
    if (!(Test-Path "files") -or !(Test-Path $SOURCE_VDI)) {
        Write-Host "Kali VDI not found in 'files'. Exiting..."
        exit 1
    }

    if (!(Get-Command VBoxManage -ErrorAction SilentlyContinue)) {
        throw "VBoxManage was not found in PATH. Install VirtualBox first."
    }
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
    $adapters = @(Get-HostOnlyAdapters)

    if (-not $adapters -or $adapters.Count -eq 0) {
        throw "No host-only adapters found. Create one in VirtualBox first."
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

function Invoke-GuestCommand {
    param(
        [string]$Description,
        [string]$Command,
        [switch]$AsRoot
    )

    Write-Host "[GUEST] $Description"

    $fullCommand = $Command
    if ($AsRoot) {
        $fullCommand = "echo '$GUEST_PASS' | sudo -S -p '' bash -lc '$Command'"
    }

    $guestArgs = @(
        'guestcontrol',
        $VM_NAME,
        'run',
        '--username',
        $GUEST_USER,
        '--password',
        $GUEST_PASS,
        '--exe',
        '/bin/bash',
        '--',
        '-lc',
        $fullCommand
    )

    & VBoxManage @guestArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Guest command failed: $Description"
    }
}

function Wait-ForVm {
    $maxRetries = 30
    $retry = 0

    Write-Host "Waiting for the guest to become ready"

    while ($retry -lt $maxRetries) {
        try {
            & VBoxManage guestcontrol $VM_NAME run `
                --username $GUEST_USER `
                --password $GUEST_PASS `
                --exe /bin/sh `
                -- -lc "id"

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Guest is ready!"
                return
            }
        } catch {
        }

        Start-Sleep -Seconds 5
        $retry++
    }

    throw "Guest was not available after waiting."
}

function Provision-VM {
    $settingsFile = Join-Path $VM_DIR "$VM_NAME.vbox"

    if (Test-Path $settingsFile) {
        Write-Host "Existing VM settings found; registering '$VM_NAME'."
        VBoxManage registervm $settingsFile
    } else {
        VBoxManage createvm --name $VM_NAME --ostype "Debian_64" --register --basefolder "$env:USERPROFILE\VirtualBox VMs"
    }

    Write-Host "Copying Kali VDI to VM directory"
    Copy-Item $SOURCE_VDI $DISK_PATH -Force

    VBoxManage modifyvm $VM_NAME --graphicscontroller vmsvga --vram 128
    VBoxManage modifyvm $VM_NAME --cpus 2 --memory 4096
    VBoxManage modifyvm $VM_NAME --nic1 nat
    VBoxManage modifyvm $VM_NAME --nic2 hostonly --hostonlyadapter2 $script:VBOXNET_INTERFACE

    VBoxManage storagectl $VM_NAME --name "SATA Controller" --add sata --controller IntelAhci
    VBoxManage storageattach $VM_NAME --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium $DISK_PATH

    $sharedFolderPath = Join-Path $SHARE_PATH "kali-shared-folder"
    try {
        VBoxManage sharedfolder add $VM_NAME --name "vm_share" --hostpath $sharedFolderPath --automount
    } catch {
        Write-Host "Shared folder already exists; skipping add."
    }

    Write-Host "---------------------------------------------------"
    Write-Host "VM '$VM_NAME' is ready with Kali VDI."
}

function Configure-VM {
    $runningVm = VBoxManage list runningvms | Where-Object { $_ -like "*$VM_NAME*" }
    if (-not $runningVm) {
        VBoxManage startvm $VM_NAME --type headless
    } else {
        Write-Host "VM '$VM_NAME' is already running; skipping startvm."
    }

    Wait-ForVm

    $sharedFolder = "/home/kali/host_files"
    Invoke-GuestCommand -Description "Create shared folder mount" -AsRoot -Command "mkdir -p $sharedFolder"
    Invoke-GuestCommand -Description "Mount shared folder" -AsRoot -Command "if ! mountpoint -q $sharedFolder; then mount -t vboxsf vm_share $sharedFolder; fi"
    Invoke-GuestCommand -Description "Copy shared files into home directory" -AsRoot -Command "sudo -u $GUEST_USER cp -a $sharedFolder/. /home/$GUEST_USER/"

    Write-Host "SUCCESS"
    Write-Host "Shared folder mounted at: $sharedFolder"

}

Init
$script:VBOXNET_INTERFACE = Select-HostOnlyAdapter

$vmExists = VBoxManage list vms | Select-String -Pattern $VM_NAME
if (-not $vmExists) {
    Provision-VM
} else {
    Write-Host "VM '$VM_NAME' already exists; skipping provisioning."
}

Configure-VM