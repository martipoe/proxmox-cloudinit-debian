#!/bin/bash

### Create a Debian Cloud-Init Ready VM Template ###

set -euxo pipefail

ENV_DIR=$1
ENV="./template/${ENV_DIR}/.env"

if [[ -f "${ENV}" ]]; then
    set -a
    source "${ENV}"
    set +a
else
    echo "ERROR: ${ENV} not found"
    exit 1
fi

# https://pve.proxmox.com/pve-docs/qm.1.html

if qm list | grep -q "${TEMPLATE_VM_ID}"; then
    read -p "WARNING: VM ${TEMPLATE_VM_ID} already exists. Destroy it including all associated disks and backup job configurations? (Y/N): " confirm
    if [[ "${confirm}" == [yY] || "${confirm}" == [yY][eE][sS] ]]; then
        qm stop "${TEMPLATE_VM_ID}"
        qm destroy --purge true "${TEMPLATE_VM_ID}"
    else
        exit 1
    fi
fi

QCOW2_FILENAME=$(basename "${TEMPLATE_QCOW2_URL}")
if [[ "${QCOW2_FILENAME}" != *.qcow2 ]]; then
    echo "ERROR: ${QCOW2_FILENAME} is not a .qcow2 file"
    exit 1
fi

wget --timestamping -O "${QCOW2_FILENAME}" "${TEMPLATE_QCOW2_URL}" && \
    qm create "${TEMPLATE_VM_ID}" --name "${TEMPLATE_VM_NAME}" --memory "${TEMPLATE_VM_MEM}" && \
    qm importdisk "${TEMPLATE_VM_ID}" "${QCOW2_FILENAME}" "${TEMPLATE_STORAGE_NAME}" && \
    qm set "${TEMPLATE_VM_ID}" --virtio0 "${TEMPLATE_STORAGE_NAME}:vm-${TEMPLATE_VM_ID}-disk-0,media=disk,discard=on" && \
    qm set "${TEMPLATE_VM_ID}" --ide2 "${TEMPLATE_STORAGE_NAME}:cloudinit" && \
    qm set "${TEMPLATE_VM_ID}" --boot c --bootdisk virtio0 && \
    qm set "${TEMPLATE_VM_ID}" --serial0 socket --vga serial0 && \
    qm template "${TEMPLATE_VM_ID}" && \
    echo "TEMPLATE ${TEMPLATE_VM_NAME} successfully created!"
