#!/bin/bash

### Provision VM from VM template ###

set -euxo pipefail

ENV="./provision/$1/.env"
if [[ -f "${ENV}" ]]; then
    set -a
    source "${ENV}"
    set +a
else
    echo "ERROR: ${ENV} not found"
    exit 1
fi

CLOUDINIT_USER_DATA="./provision/${PROVISION_VM_NAME}/user-data"
if [[ ! -f "${CLOUDINIT_USER_DATA}" ]]; then
    echo "ERROR: ${CLOUDINIT_USER_DATA} not found"
    exit 1
fi

CLOUDINIT_NETWORK_CONFIG="./provision/${PROVISION_VM_NAME}/network-config"
if [[ ! -f "${CLOUDINIT_NETWORK_CONFIG}" ]]; then
    echo "ERROR: ${CLOUDINIT_NETWORK_CONFIG} not found"
    exit 1
fi

# Check if VM with same ID already exists and prompt for destruction if it does (with special handling to preserve data disk if persistence is enabled)
if qm list | grep -q "${PROVISION_VM_ID}"; then
    echo "WARNING: VM ${PROVISION_VM_ID} already exists:"
    qm config "${PROVISION_VM_ID}"
    read -p "Destroy it including all associated disks and backup job configurations? (Y/N): " confirm_purge
    if [[ "${confirm_purge}" == [yY] || "${confirm_purge}" == [yY][eE][sS] ]]; then
        if [[ "${PROVISION_VM_DATA_DISK_PERSISTENCE}" == "true" ]]; then
            echo "Persistence for data disk ${PROVISION_VM_DATA_DISK_NAME} is enabled. Attempting to unattach and unreference existing data disk to preserve it before destroying VM."
            qm set "${PROVISION_VM_ID}" -delete virtio1
            # remove from /etc/pve/qemu-server/ so it becomes unreferenced and cannot be deleted via qm destroy --purge
            sed -i "/unused0: ${PROVISION_VM_DATA_STORAGE_NAME}:vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME}\$/d" "/etc/pve/qemu-server/${PROVISION_VM_ID}.conf"
        fi
        qm stop "${PROVISION_VM_ID}"
        qm destroy --purge true --destroy-unreferenced false "${PROVISION_VM_ID}"
    else
        exit 1
    fi
fi

# Copy cloudinit user and network configuration to snippets directory in Proxmox storage
mkdir -p "${PROVISION_CLOUDINIT_STORAGE_PATH}/snippets/${PROVISION_VM_ID}/" && \
    cp "${CLOUDINIT_USER_DATA}" "${PROVISION_CLOUDINIT_STORAGE_PATH}/snippets/${PROVISION_VM_ID}-user-data" && \
    cp "${CLOUDINIT_NETWORK_CONFIG}" "${PROVISION_CLOUDINIT_STORAGE_PATH}/snippets/${PROVISION_VM_ID}-network-config"

# Create full clone from template VM (https://www.reddit.com/r/Proxmox/comments/18dp3h6/should_i_use_linked_clones/),
# resize root disk, configure resources and mount cloudinit snippet.
qm clone "${TEMPLATE_VM_ID}" "${PROVISION_VM_ID}" --name "${PROVISION_VM_NAME}" --storage "${PROVISION_VM_STORAGE_NAME}" --full true && \
    qm resize "${PROVISION_VM_ID}" virtio0 "${PROVISION_VM_ROOT_DISK_SIZE}" && \
    qm set "${PROVISION_VM_ID}" --memory "${PROVISION_VM_MEM_SIZE}" --cores "${PROVISION_VM_CORES}" ${PROVISION_VM_NETWORKING} && \
    qm set "${PROVISION_VM_ID}" --cicustom "user=${PROVISION_CLOUDINIT_STORAGE_NAME}:snippets/${PROVISION_VM_ID}-user-data,network=${PROVISION_CLOUDINIT_STORAGE_NAME}:snippets/${PROVISION_VM_ID}-network-config" && \
    qm set "${PROVISION_VM_ID}" --agent 1

# Data disk handling with support for persistence if enabled. If persistence is enabled but no existing disk is found, prompt to create a new one or abort.
if [[ -n "${PROVISION_VM_DATA_DISK_SIZE}" ]]; then
    if [[ "${PROVISION_VM_DATA_DISK_PERSISTENCE}" == "true" ]]; then
        if pvesm list "${PROVISION_VM_DATA_STORAGE_NAME}" | grep -w -q "${PROVISION_VM_DATA_STORAGE_NAME}:vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME}"; then
            qm rescan --vmid "${PROVISION_VM_ID}" && \
            qm set "${PROVISION_VM_ID}" --virtio1 "${PROVISION_VM_DATA_STORAGE_NAME}:vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME},size=${PROVISION_VM_DATA_DISK_SIZE},media=disk,discard=on"
        else
            read -p "ERROR: Data disk vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME} not found in storage ${PROVISION_VM_DATA_STORAGE_NAME}. Do you want to create a new data disk instead? (Y/N): " recreate_confirm
            if [[ "${recreate_confirm}" == [yY] || "${recreate_confirm}" == [yY][eE][sS] ]]; then
                PROVISION_VM_DATA_DISK_PERSISTENCE="false"
            else
                exit 1
            fi
        fi
    fi

    if [[ "${PROVISION_VM_DATA_DISK_PERSISTENCE}" == "false" ]]; then
        pvesm alloc "${PROVISION_VM_DATA_STORAGE_NAME}" "${PROVISION_VM_ID}" "vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME}" "${PROVISION_VM_DATA_DISK_SIZE}" && \
        qm set "${PROVISION_VM_ID}" --virtio1 "${PROVISION_VM_DATA_STORAGE_NAME}:vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME},size=${PROVISION_VM_DATA_DISK_SIZE},media=disk,discard=on"
    fi
fi

qm start "${PROVISION_VM_ID}" && \
echo "VM ${PROVISION_VM_NAME} successfully created!"

# Remove cloudinit disk (will apply at next reboot)
# qm set "${PROVISION_VM_ID}" -delete ide2
