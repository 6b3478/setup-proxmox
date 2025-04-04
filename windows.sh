#!/usr/bin/env bash

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
NEXTID=$(pvesh get /cluster/nextid)

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
HA=$(echo "\033[1;34m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
THIN="discard=on,ssd=1,"

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}

TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

function msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
  echo 
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
  echo
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

# ROOT CHECK
function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear
    msg_error "Please run this script as root."
    echo -e "\nExiting..."
    sleep 2
    exit
  fi
}

function pve_check() {
  if ! pveversion | grep -Eq "pve-manager/8.[1-3]"; then
    msg_error "This version of Proxmox Virtual Environment is not supported"
    echo -e "Requires Proxmox Virtual Environment Version 8.1 or later."
    echo -e "Exiting..."
    sleep 2
    exit
fi
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    msg_error "This script will not work with PiMox! \n"
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function exit-script() {
  clear
  echo -e "⚠  User exited script \n"
  exit
}

function default_settings() {
  VMID="$NEXTID"
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE=""
  NAME="windowsServer"
  CPU_TYPE=""
  CORES=4
  RAM=4096
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  DISK_SIZE="20"
  echo -e "${DGN}Using Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${DGN}Using Machine Type: ${BGN}i440fx${CL}"
  echo -e "${DGN}Using Disk Cache: ${BGN}None${CL}"
  echo -e "${DGN}Using Hostname: ${BGN}${HN}${CL}"
  echo -e "${DGN}Using CPU Model: ${BGN}KVM64${CL}"
  echo -e "${DGN}Allocated Cores: ${BGN}${CORES}${CL}"
  echo -e "${DGN}Allocated RAM: ${BGN}${RAM}${CL}"
  echo -e "${DGN}Using Bridge: ${BGN}${BRG}${CL}"
  echo -e "${DGN}Using MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${DGN}Using VLAN: ${BGN}Default${CL}"
  echo -e "${DGN}Using Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${BL}Creating a Windows Server 2022 VM using the above default settings${CL}"
}

function create_lvm_disk() {
  if ! lvdisplay "$STORAGE/vm-${VMID}-disk-0" &>/dev/null; then
    echo "Creating LVM disk for VM ${VMID}..."
    lvcreate -L $DISK_SIZE -n vm-${VMID}-disk-0 $STORAGE
  else
    echo "LVM disk for VM ${VMID} already exists."
  fi
}

default_settings
start_script

msg_info "Validating Storage"
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
VALID=$(pvesm status -content images | awk 'NR>1')

msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."

#------------------------------------------------------------------------------
ISO_STORAGE="local"
ISO_FILE="WindowsServer2022.iso"
VIRTIO_FILE="virtio-win.iso"

ISO_PATH="/var/lib/vz/template/iso/$ISO_FILE"
VIRTIO_PATH="/var/lib/vz/template/iso/$VIRTIO_FILE"

URL_ISO_WINDOWS="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
URL_VIRTIO="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
#------------------------------------------------------------------------------

msg_info "Checking if Windows Server 2022 ISO is already downloaded..."
if ! pvesm list $ISO_STORAGE | grep -q $ISO_FILE; then
  msg_info "Downloading Windows Server 2022 ISO..."
  
  if ! wget --quiet --show-progress --tries=3 --timeout=30 -O "$ISO_PATH" "$URL_ISO_WINDOWS"; then
    msg_error "Failed to download Windows Server 2022 ISO. Please check the URL or your connection."
    exit 1
  fi
  
  msg_ok "Windows Server 2022 ISO downloaded: $ISO_PATH"
else
  msg_ok "Windows Server 2022 ISO already exists: $ISO_PATH"
fi

msg_info "Checking if VirtIO ISO is already downloaded..."
if ! pvesm list $ISO_STORAGE | grep -q $VIRTIO_FILE; then
  msg_info "Downloading VirtIO ISO..."
  
  if ! wget --quiet --show-progress --tries=3 --timeout=30 -O "$VIRTIO_PATH" "$URL_VIRTIO"; then
    msg_error "Failed to download VirtIO ISO. Please check the URL or your connection."
    exit 1
  fi

  msg_ok "VirtIO ISO downloaded: $VIRTIO_PATH"
else
  msg_ok "VirtIO ISO already exists: $VIRTIO_PATH"
fi

echo -en "\e[1A\e[0K"
msg_ok "All ISOs are downloaded successfully."

msg_info "Creating LVM Disk..."
create_lvm_disk

if [[ -z "$VMID" || -z "$NAME" || -z "$BRG" || -z "$CORES" || -z "$RAM" || -z "$STORAGE" || -z "$DISK_SIZE" ]]; then
  msg_error "ERROR : Check your configuration."
  exit 1
fi

msg_info "Creating a Windows Server 2022 VM (${NAME})"
qm create $VMID \
  -agent 1 \
  ${MACHINE:+-machine $MACHINE} \
  -tablet 0 \
  -localtime 1 \
  -bios ovmf \
  ${CPU_TYPE:+-cpu $CPU_TYPE} \
  -cores $CORES \
  -memory $RAM \
  -name $NAME \
  -tags Windows-Server \
  -net0 virtio,bridge=$BRG,macaddr=$MAC${VLAN:+$VLAN}${MTU:+,mtu=$MTU}

msg_ok "VM ${NAME} (${VMID}) created successfully."

qm set $VMID --ide0 $ISO_STORAGE:iso/$ISO_FILE,media=cdrom
qm set $VMID --ide1 $ISO_STORAGE:iso/$VIRTIO_FILE,media=cdrom
qm set $VMID --serial0 socket
qm set $VMID --boot c --bootdisk scsi0
qm set $VMID --vga qxl
qm set $VMID --usb0 host=0627:0001,usb3=1


msg_info "Allocating Disk Size: ${DISK_SIZE} on Storage: ${STORAGE}"
qm set $VMID --sata0 "$STORAGE":$DISK_SIZE,format=raw

msg_ok "Installation completed successfully!"
