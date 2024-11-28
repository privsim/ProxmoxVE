#!/usr/bin/env bash

# Copyright (c) 2024 privsim
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

function header_info {
  clear
  cat <<"EOF"
    ____             __                 
   / __/__ ___  ____/ /__  _________ _ 
  / _// -_) _ \/ __/ / _ \/ __/ __  / 
 /_/ /\__/_//_/\__/_/\___/_/  \_,_/  
                                      
EOF
}

header_info
echo -e "\n Loading..."
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
NEXTID=$(pvesh get /cluster/nextid)

# Color variables
YW="\033[33m"
BL="\033[36m"
RD="\033[01;31m"
BGN="\033[4;92m"
GN="\033[1;92m"
DGN="\033[32m"
CL="\033[m"
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
THIN="discard=on,ssd=1,"

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# Error handling
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

# Message functions
function msg_info() { echo -ne " ${HOLD} ${YW}$1...${CL}"; }
function msg_ok() { echo -e "${BFR} ${CM} ${GN}$1${CL}"; }
function msg_error() { echo -e "${BFR} ${CROSS} ${RD}$1${CL}"; }

# Check functions
function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear
    msg_error "Please run this script as root"
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

# Setup
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

# Default settings
VMID="$NEXTID"
FORMAT=",efitype=4m"
MACHINE=""
DISK_CACHE=""
HN="fedora"
CPU_TYPE=""
CORE_COUNT="2"
RAM_SIZE="2048"
BRG="vmbr0"
MAC="$GEN_MAC"
VLAN=""
MTU=""
START_VM="yes"

# Validation
check_root
pve_check

# Download and verify
msg_info "Downloading Fedora Server image"
wget -q --show-progress https://download.fedoraproject.org/pub/fedora/linux/releases/41/Server/x86_64/images/Fedora-Server-KVM-41-1.4.x86_64.qcow2
wget -q https://fedoraproject.org/fedora.gpg
wget -q https://download.fedoraproject.org/pub/fedora/linux/releases/41/Server/x86_64/images/Fedora-Server-41-1.4-x86_64-CHECKSUM

msg_info "Verifying image integrity"
if ! gpgv --keyring ./fedora.gpg Fedora-Server-41-1.4-x86_64-CHECKSUM; then
  msg_error "GPG verification failed"
  exit 1
fi

if ! sha256sum -c <(grep qcow2 Fedora-Server-41-1.4-x86_64-CHECKSUM); then
  msg_error "Checksum verification failed"
  exit 1
fi
msg_ok "Image verified"

# Storage setup
msg_info "Validating storage"
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
if [ -z "$VALID" ]; then
  msg_error "Unable to detect a valid storage location"
  exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  STORAGE=$(pvesm status -content images | awk 'NR>1 {print $1; exit}')
fi

msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for storage location"

# Create VM
msg_info "Creating Fedora VM"
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags proxmox-helper-scripts -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci

DISK0=vm-${VMID}-disk-0.qcow2
DISK1=vm-${VMID}-disk-1.qcow2

pvesm alloc $STORAGE $VMID $DISK0 4M 1>&/dev/null
qm importdisk $VMID Fedora-Server-KVM-41-1.4.x86_64.qcow2 $STORAGE -format qcow2 1>&/dev/null

qm set $VMID \
  -efidisk0 ${STORAGE}:$VMID/$DISK0,efitype=4m \
  -scsi0 ${STORAGE}:$VMID/$DISK1,size=4G \
  -boot order=scsi0 \
  -serial0 socket \
  -description "Fedora Server 41 VM created via Helper Scripts" >/dev/null

msg_ok "Created Fedora Server VM ${CL}${BL}(${HN})"

if [ "$START_VM" == "yes" ]; then
  msg_info "Starting Fedora Server VM"
  qm start $VMID
  msg_ok "Started Fedora Server VM"
fi

msg_ok "Completed Successfully!\n"
