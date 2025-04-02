#!/bin/bash
set -euo pipefail

export SCRIPT_NAME="vm-windows.sh"
if [[ -f "$(dirname "$0")/build.func" ]]; then
    source "$(dirname "$0")/build.func"
else
    source <(wget -qO- https://raw.githubusercontent.com/6b3478/setup-proxmox/refs/heads/main/build.func)
fi
print_help "$(basename "$0")" "$@"
parse_input "$@"
configure_host_storage
configure_vm_settings
configure_os_settings
configure_network_settings
review_configurations
check_noop

download_vm_image() {
    echo "🔧 Checking if OS image exists..."
    cd "$MOUNT_STORAGE/template/iso/"
    VM_IMAGE="$OS_NAME-$OS_VERSION.iso"
    if ! test -f "$VM_IMAGE"; then
        echo "⬇️ Downloading from $OS_IMAGE_LINK..."
        wget "$OS_IMAGE_LINK" -O "$VM_IMAGE"
    fi

    echo "🔧 Checking if Support image exists..."
    local VM_SUPPORT_IMAGE_INFO
    VM_SUPPORT_IMAGE_INFO="$(curl --silent -m 10 --connect-timeout 5 "https://api.github.com/repos/qemus/virtiso/releases/latest" | grep virtio-win | grep "\.iso")"
    VM_SUPPORT_IMAGE=$(echo "$VM_SUPPORT_IMAGE_INFO" | grep "name" | cut -d'"' -f4)
    if ! test -f "$VM_SUPPORT_IMAGE"; then
        VM_SUPPORT_IMAGE_LINK=$(echo "$VM_SUPPORT_IMAGE_INFO" | grep "browser_download_url" | cut -d'"' -f4)
        echo "⬇️ Downloading from $VM_SUPPORT_IMAGE_LINK..."
        wget "$VM_SUPPORT_IMAGE_LINK"
    fi
}

create_vm() {
    echo "🔧 Creating VM..."
    if [[ "$OS_VERSION" =~ ^(XP|Vista)$ ]]; then
        OS_TYPE="w$OS_VERSION"
    else
        OS_TYPE="win$OS_VERSION"
    fi
    qm create $VM_ID --name "$VM_NAME" \
        --ostype "$OS_TYPE" --ide2 "$HOST_ISO_STORAGE:iso/$VM_IMAGE,media=cdrom" \
        --vga std --scsihw virtio-scsi-single --machine q35 --agent 1 \
        --bios ovmf --efidisk0 "$HOST_VM_STORAGE:0,pre-enrolled-keys=1" \
        --cpu host --cores "$VM_CORES" \
        --memory "$VM_MEM" \
        --net0 "$VM_NET" \
        --tablet 1
}

setup_disk_image() {
    echo "🔧 Setting up disk image..."
    pvesm alloc "$HOST_VM_STORAGE" $VM_ID "vm-$VM_ID-disk-1" "${VM_DISK}G"
    qm set $VM_ID --scsi0 "$HOST_VM_STORAGE:vm-$VM_ID-disk-1,cache=writeback,discard=on,ssd=1"
    qm set $VM_ID --ide0 "$HOST_ISO_STORAGE:iso/$VM_SUPPORT_IMAGE,media=cdrom"
    qm set $VM_ID --boot order='scsi0;ide2;ide0'
    pvesm alloc "$HOST_VM_STORAGE" $VM_ID "vm-$VM_ID-disk-2" 4M # TPM disk
    qm set $VM_ID --tpmstate0 "$HOST_VM_STORAGE:vm-$VM_ID-disk-2,size=4M,version=v2.0"
}

download_vm_image
create_vm
setup_disk_image
print_success_message
