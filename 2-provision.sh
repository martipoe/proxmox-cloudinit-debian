#!/bin/bash

### Provision VM from VM template ###

set -euxo pipefail

ENV_DIR=$1
ENV="./provision/${ENV_DIR}/.env"

if [[ -f "${ENV}" ]]; then
    set -a
    source "${ENV}"
    set +a
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
    if [[ "${PROVISION_VM_DATA_DISK_PERSISTENCE}" == "true" ]]; then
        # unattach data disk
        qm set "${PROVISION_VM_ID}" -delete virtio1
        # remove from /etc/pve/qemu-server/ so it becomes unreferenced and cannot be deleted via qm destroy --purge
        sed -i "/unused0: ${PROVISION_VM_DATA_STORAGE_NAME}:vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME}\$/d" "/etc/pve/qemu-server/${PROVISION_VM_ID}.conf"
    fi

    read -p "WARNING: VM ${PROVISION_VM_ID} already exists. Destroy it including all associated disks and backup job configurations? (Y/N): " confirm
    if [[ "${confirm}" == [yY] || "${confirm}" == [yY][eE][sS] ]]; then
        qm stop "${PROVISION_VM_ID}"
        qm destroy --purge true --destroy-unreferenced false "${PROVISION_VM_ID}"
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
if [[ -n "${PROVISION_VM_DATA_DISK_SIZE}" ]]; then
    if [[ "${PROVISION_VM_DATA_DISK_PERSISTENCE}" == "true" ]]; then
        if pvesm list "${PROVISION_VM_DATA_STORAGE_NAME}" | grep -w -q "${PROVISION_VM_DATA_STORAGE_NAME}:vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME}"; then
            qm rescan --vmid "${PROVISION_VM_ID}" && \
            qm set "${PROVISION_VM_ID}" --virtio1 "${PROVISION_VM_DATA_STORAGE_NAME}:vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME},size=${PROVISION_VM_DATA_DISK_SIZE},media=disk,discard=on"
        else
            read -p "ERROR: Data disk vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME} not found in storage ${PROVISION_VM_DATA_STORAGE_NAME}. Do you want to create a new data disk instead? (Y/N): " recreate_confirm
            if [[ "${recreate_confirm}" == [yY] || "${recreate_confirm}" == [yY][eE][sS] ]]; then
                CREATE_DISK=true
            else
                echo "Aborting: persistence was requested, but no existing data disk was found."
                exit 1
            fi
        fi
    fi

    if [[ "${PROVISION_VM_DATA_DISK_PERSISTENCE}" == "false" || "${CREATE_DISK:-}" == "true" ]]; then
        pvesm alloc "${PROVISION_VM_DATA_STORAGE_NAME}" "${PROVISION_VM_ID}" "vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME}" "${PROVISION_VM_DATA_DISK_SIZE}"
        qm set "${PROVISION_VM_ID}" --virtio1 "${PROVISION_VM_DATA_STORAGE_NAME}:vm-${PROVISION_VM_ID}-${PROVISION_VM_DATA_DISK_NAME},size=${PROVISION_VM_DATA_DISK_SIZE},media=disk,discard=on"
    fi
fi

qm start "${PROVISION_VM_ID}" && echo "VM ${PROVISION_VM_NAME} successfully created!"

# Remove cloudinit disk (will apply at next reboot)
# qm set "${PROVISION_VM_ID}" -delete ide2
