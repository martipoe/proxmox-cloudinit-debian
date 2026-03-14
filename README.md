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
TEMPLATE_QCOW2_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
# ID of the Template VM
TEMPLATE_VM_ID=9001
# Name of the Template VM
TEMPLATE_VM_NAME="template-cloudinit-debian-13-generic-amd64"
# Storage of the Template VM
TEMPLATE_STORAGE_NAME="local-lvm"
# Resources
TEMPLATE_VM_MEM=512
```

```bash
# sync repository
rsync -avz --delete * proxmox.lan:proxmox-cloudinit-debian/

# create template VM
ssh proxmox.lan "cd proxmox-cloudinit-debian && /bin/bash ./1-template.sh debian-13"
```

### Provision a VM from the Template VM

Configs and .env for the provisioned VM in *./provision/docker-*.lan* are exemplary.

Each VM needs its own subdirectory in `./provision/${PROVISION_VM_NAME}/` with these files:
- .env
- user-data
- network-config

*./provision/${PROVISION_VM_NAME}/.env*:
```bash
# ID from template/name/.env
TEMPLATE_VM_ID=9001
# Storage directory used for cloudinit snippets
PROVISION_CLOUDINIT_STORAGE_NAME="local"
PROVISION_CLOUDINIT_STORAGE_PATH="/var/lib/vz"
# ID of the VM
PROVISION_VM_ID=102
# Name of the VM
PROVISION_VM_NAME="docker-xfs.lan"
# Storage of the VM
PROVISION_VM_STORAGE_NAME="local-lvm"
PROVISION_VM_ROOT_DISK_SIZE="8G"
# Retain data disk when VM is recreated
PROVISION_VM_DATA_DISK_PERSISTENCE="true"
PROVISION_VM_DATA_STORAGE_NAME="hdd-thin"
PROVISION_VM_DATA_DISK_NAME="data"
PROVISION_VM_DATA_DISK_SIZE="16G"
# Resources
PROVISION_VM_MEM_SIZE=4096
PROVISION_VM_CORES=4
# Networking with VLAN TAG '4'
PROVISION_VM_NETWORKING="--net0 virtio,bridge=vmbr0,firewall=1,tag=4"
```

Provisioning behavior:
1. If the target VM already exists, the script asks for confirmation before stopping and destroying it.
2. If `PROVISION_VM_DATA_DISK_PERSISTENCE="true"`, the data disk is detached and unreferenced before VM destruction and then reattached after the VM is recreated.
3. If persistence is enabled but the expected data disk cannot be found in `PROVISION_VM_DATA_STORAGE_NAME`, the script asks whether a new disk should be created instead.
4. If persistence is disabled, a new data disk is created during provisioning.

```bash
# sync repository
rsync -avz --delete * proxmox.lan:proxmox-cloudinit-debian/

# provision VM
ssh proxmox.lan "cd proxmox-cloudinit-debian && /bin/bash ./2-provision.sh docker-xfs.lan"
```

## Inspired by

- https://github.com/chris2k20/proxmox-cloud-init
