# Use Cloud-init yaml with Proxmox

## Introduction

- https://pve.proxmox.com/wiki/Cloud-Init_Support
- https://cloud-init.io/
- https://pve.proxmox.com/pve-docs/qm.1.html

In order to use Cloud-init with Proxmox, the following steps are recommended:
1. Get a dedicated Cloud-init image for the Linux distribution.
2. Use this image to build a template VM.
3. Provision servers by cloning the template VM and mounting the Cloud-init configuration, so that it will be applied during startup.

Multiple ways to provide Cloud-init configuration exist in Proxmox, also via GUI. Most cloud providers do support [yaml configuration files](https://cloudinit.readthedocs.io/en/latest/reference/examples.html) and this can be done in Proxmox as well - via [Custom Cloud-Init Configuration](https://pve.proxmox.com/wiki/Cloud-Init_Support#_custom_cloud_init_configuration).


## Prerequisites

[Storage](https://pve.proxmox.com/wiki/Storage):
1. **LVM-thin** storage pool: *local-lvm*
    - For thin provisioning, `discard=on` is recommended on disks and therefore set by the provisioning scripts. The guest OS must be configured to regularly run fstrim in order to clean up unused blocks - Debian does this by default, see `systemctl status fstrim.timer`: https://gist.github.com/hostberg/86bfaa81e50cc0666f1745e1897c0a56
2. **Directory** with cloudinit snippets: *local*
    - Snippets are not enabled by default and must be added in e.g. "Datacenter" -> "Storage" -> Edit: *local*.
    ![Configure a snippet](docs/snippets.png)
    - **In Proxmox clusters, these snippets must be accessible for all nodes in a shared storage, [Link](https://www.thomas-krenn.com/de/wiki/Custom_Cloud_Init_Config_in_Proxmox_VE#Snippet-Directory_erstellen). - unless they are removed after provisioning**

[Networking](https://pve.proxmox.com/wiki/Network_Configuration):
1. Network interfaces with vlans

Additional information:
- Cloud-init configs for user data and networking must be split, as implemented by the provisioning script: `qm set 9001 --cicustom "user=<volume>,network=<volume>,meta=<volume>"`


## Usage

```bash
# user@local:~#
git clone git@github.com:martipoe/proxmox-cloudinit-debian.git
cd proxmox-cloudinit-debian
```

**All configuration changes should be committed to this repository and can then be reused for future rebuilds and migrations.**

### Create Template VM

Debian provides cloudinit-ready daily image builds at https://cloud.debian.org/images/cloud/trixie/latest/. They only have a single root partition - creating templates with a partitioning schemes requires custom installations with preseeds, not implemented here.

The VM does not require networking, because we will not boot it.

Each Template VM needs its own subdirectory in `./template/${TEMPLATE_VM_NAME}/` with these files:
- .env

*./template/${TEMPLATE_VM_NAME}/.env*:
```bash
# source for cloudinit ready Debian Image
export TEMPLATE_QCOW2_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
# ID of the Template VM
export TEMPLATE_VM_ID=9001
# Name of the Template VM
export TEMPLATE_VM_NAME="template-cloudinit-debian-13-generic-amd64"
# Storage of the Template VM
export TEMPLATE_STORAGE_NAME="local-lvm"
# Resources
export TEMPLATE_VM_MEM=512
```

```bash
# user@local:~#
rsync -avz --delete * proxmox.lan:proxmox-cloudinit-debian/

# root@proxmox:~#
cd proxmox-cloudinit-debian

# create template vm
bash ./1-template.sh debian-13
```

### Provision a VM from the Template VM

Configs and .env for the provisioned VM in *./provision/docker-01* are exemplary.

Each VM needs its own subdirectory in `./provision/${PROVISION_VM_NAME}/` with these files:
- .env
- user-data
- network-config

*./provision/${PROVISION_VM_NAME}/.env*:
```bash
# ID from template/name/.env
export TEMPLATE_VM_ID=9001
# Storage directory used for cloudinit snippets
export PROVISION_CLOUDINIT_STORAGE_NAME="local"
export PROVISION_CLOUDINIT_STORAGE_PATH="/mnt/pve/local"
# ID of the VM
export PROVISION_VM_ID=9002
# Name of the VM
export PROVISION_VM_NAME="docker-01"
# Storage of the VM
export PROVISION_VM_STORAGE_NAME="local-lvm"
# Root disk size
export PROVISION_VM_ROOT_DISK_SIZE="10G"
# PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID will attempt to import the data partition from the VM ID that has been created using this script
export PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID=""
# Ignored if PROVISION_VM_DATA_DISK_MIGRATE_FROM_ID is set, otherwise a data disk of the specified size will be created
export PROVISION_VM_DATA_STORAGE_NAME="hdd-thin"
export PROVISION_VM_DATA_STORAGE_LV="${PROVISION_VM_DATA_STORAGE_NAME}"
export PROVISION_VM_DATA_STORAGE_VG="${PROVISION_VM_DATA_STORAGE_NAME}"
export PROVISION_VM_DATA_DISK_SIZE="2G"
# Resources
export PROVISION_VM_MEM_SIZE=2048
export PROVISION_VM_CORES=2
# Networking
export PROVISION_VM_NETWORKING="--net0 virtio,bridge=vmbr0,firewall=1,tag=4"
```


```bash
# user@local:~#
rsync -avz --delete * proxmox.lan:proxmox-cloudinit-debian/

# root@proxmox:~#
cd proxmox-cloudinit-debian

# provision from template vm
bash ./2-provision.sh docker-01
```

## Inspired by

- https://github.com/chris2k20/proxmox-cloud-init
