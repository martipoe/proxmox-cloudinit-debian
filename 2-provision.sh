#!/bin/bash

### Provision VM from VM template ###

set -euxo pipefail

ENV_DIR=$1
ENV="./provision/${ENV_DIR}/.env"

if [[ -f "${ENV}" ]]; then
    source "${ENV}"
else
    echo "ERROR: ${ENV} not found"
    exit 1
fi

CLOUDINIT="./provision/${PROVISION_VM_NAME}/user-data"
if [[ ! -f "${CLOUDINIT}" ]]; then
    echo "ERROR: ${CLOUDINIT} not found"
    exit 1
fi

NETPLAN="./provision/${PROVISION_VM_NAME}/network-config"
if [[ ! -f "${NETPLAN}" ]]; then
    echo "ERROR: ${NETPLAN} not found"
    exit 1
fi

if qm list | grep -q "${PROVISION_VM_ID}"; then
    read -p "WARNING: VM ${PROVISION_VM_ID} already exists. Destroy it including all associated disks and backup job configurations? (Y/N): " confirm
    if [[ "${confirm}" == [yY] || "${confirm}" == [yY][eE][sS] ]]; then
        qm stop "${PROVISION_VM_ID}"
        qm destroy --purge true "${PROVISION_VM_ID}"
    else
        exit 1
    fi
fi

# Copy cloudinit user and network configuration to snippets directory in Proxmox storage
mkdir -p "${PROVISION_CLOUDINIT_STORAGE_PATH}/snippets/${PROVISION_VM_ID}/" && \
    cp "${CLOUDINIT}" "${PROVISION_CLOUDINIT_STORAGE_PATH}/snippets/${PROVISION_VM_ID}-user-data" && \
    cp "${NETPLAN}" "${PROVISION_CLOUDINIT_STORAGE_PATH}/snippets/${PROVISION_VM_ID}-network-config"


# Create full clone from template VM: https://www.reddit.com/r/Proxmox/comments/18dp3h6/should_i_use_linked_clones/
# Then resize root disk, configure resources and mount cloudinit snippet.
qm clone "${TEMPLATE_VM_ID}" "${PROVISION_VM_ID}" --name "${PROVISION_VM_NAME}" --storage "${PROVISION_VM_STORAGE_NAME}" --full true && \
    qm resize "${PROVISION_VM_ID}" virtio0 "${PROVISION_VM_ROOT_DISK_SIZE}" && \
    qm set "${PROVISION_VM_ID}" --memory "${PROVISION_VM_MEM_SIZE}" --cores "${PROVISION_VM_CORES}" ${PROVISION_VM_NETWORKING} && \
    qm set "${PROVISION_VM_ID}" --cicustom "user=${PROVISION_CLOUDINIT_STORAGE_NAME}:snippets/${PROVISION_VM_ID}-user-data,network=${PROVISION_CLOUDINIT_STORAGE_NAME}:snippets/${PROVISION_VM_ID}-network-config" && \
    qm set "${PROVISION_VM_ID}" --agent 1


# Data disk handling
PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID=${PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID:=}
# If PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID is defined, ask for permission to migrate the data disk. Ignores PROVISION_VM_DATA_DISK_SIZE.
if [[ -n "${PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID}" ]]; then
    read -p "WARNING: Migrate data disk from VM ${PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID} to this VM? This will stop the source VM. (Y/N): " confirm
    if [[ "${confirm}" == [yY] || "${confirm}" == [yY][eE][sS] ]]; then
        qm stop "${PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID}"
        qm move-disk "${PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID}" virtio1 --target-vmid "${PROVISION_VM_ID}" --target-disk virtio1
    fi
else
    # If PROVISION_VM_DATA_DISK_SIZE is defined, create new data disk
    if [[ -n "${PROVISION_VM_DATA_DISK_SIZE}" ]]; then
        lvcreate --name "vm-${PROVISION_VM_ID}-data-0" --virtualsize "${PROVISION_VM_DATA_DISK_SIZE}" --thinpool "${PROVISION_VM_STORAGE_NAME}" "${PROVISION_VM_STORAGE_NAME}"
        qm set "${PROVISION_VM_ID}" --virtio1 "${PROVISION_VM_STORAGE_NAME}:vm-${PROVISION_VM_ID}-data-0,size=${PROVISION_VM_DATA_DISK_SIZE},media=disk,discard=on"
    fi
fi

qm start "${PROVISION_VM_ID}" && echo "VM ${PROVISION_VM_NAME} successfully created!"

# Remove cloudinit disk (will apply at next reboot)
# qm set "${PROVISION_VM_ID}" -delete ide2
