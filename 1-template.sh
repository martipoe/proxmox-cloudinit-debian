#!/bin/bash

### Create a Debian Cloud-Init Ready VM Template ###

set -euxo pipefail

env_file="./template/$1/.env"
if [[ -f "${env_file}" ]]; then
    set -a
    source "${env_file}"
    set +a
else
    echo "ERROR: ${env_file} not found"
    exit 1
fi

# https://pve.proxmox.com/pve-docs/qm.1.html

# Download and verify the image before touching any existing template, so a failed
# download/checksum never leaves the host without a working template in between.
qcow2_filename=$(basename "${TEMPLATE_QCOW2_URL}")
qcow2_sha512sums=$(basename "${TEMPLATE_QCOW2_CHECKSUMS_URL}")

if [[ "${qcow2_filename}" != *.qcow2 ]]; then
    echo "ERROR: ${qcow2_filename} is not a .qcow2 file"
    exit 1
fi

wget --timestamping "${TEMPLATE_QCOW2_URL}" && \
    wget "${TEMPLATE_QCOW2_CHECKSUMS_URL}" && \
    sha512sum -c <(grep "${qcow2_filename}" "${qcow2_sha512sums}")

if qm list | grep -q "${TEMPLATE_VM_ID}"; then
    read -r -p "WARNING: VM ${TEMPLATE_VM_ID} already exists. Destroy it including all associated disks and backup job configurations? (Y/N): " confirm
    if [[ "${confirm}" == [yY] || "${confirm}" == [yY][eE][sS] ]]; then
        qm stop "${TEMPLATE_VM_ID}"
        qm destroy --purge true "${TEMPLATE_VM_ID}"
    else
        exit 1
    fi
fi

qm create "${TEMPLATE_VM_ID}" --name "${TEMPLATE_VM_NAME}" --memory "${TEMPLATE_VM_MEM}" && \
    qm importdisk "${TEMPLATE_VM_ID}" "${qcow2_filename}" "${TEMPLATE_STORAGE_NAME}" && \
    qm set "${TEMPLATE_VM_ID}" --virtio0 "${TEMPLATE_STORAGE_NAME}:vm-${TEMPLATE_VM_ID}-disk-0,media=disk,discard=on" && \
    qm set "${TEMPLATE_VM_ID}" --ide2 "${TEMPLATE_STORAGE_NAME}:cloudinit" && \
    qm set "${TEMPLATE_VM_ID}" --boot c --bootdisk virtio0 && \
    qm set "${TEMPLATE_VM_ID}" --serial0 socket --vga serial0 && \
    qm template "${TEMPLATE_VM_ID}" && \
    echo "TEMPLATE ${TEMPLATE_VM_NAME} successfully created!"
