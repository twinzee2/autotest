#!/bin/bash

# This script must be run as root on the Proxmox host.
# It configures the no-subscription repository if needed, creates an LXC container based on Debian 12,
# installs Docker inside it, and then sets up Dashy, Dockge, and RunTipi using their respective installation methods.
# Customize variables as needed.

# First, ensure no-subscription repository is configured
echo "Configuring Proxmox no-subscription repository..."
if ! grep -q "pve-no-subscription" /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null; then
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
    # Disable enterprise repo if it exists
    if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
        sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
    fi
    # Disable ceph enterprise repo if it exists
    if [ -f /etc/apt/sources.list.d/ceph.list ]; then
        sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list
    fi
    apt update
fi

# Variables for the LXC container
CTID=100  # Change to a unique ID if needed
HOSTNAME="dashy-container"
STORAGE="local-lvm"  # Your storage name for rootfs, e.g., local-lvm or local
DISKSIZE=16  # Disk size in GB (increased for apps and Docker images)
MEMORY=4096  # Memory in MB
CORES=4  # Number of cores
BRIDGE="vmbr0"  # Network bridge
IP="dhcp"  # Use 'dhcp' or static like '192.168.1.100/24,gw=192.168.1.1'
PASSWORD="changeme"  # Change this to a secure password
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"  # Updated to the latest available as of October 2025

# Check if template exists, download if not
if [ ! -f "/var/lib/vz/template/cache/${TEMPLATE}" ]; then
    echo "Updating template list..."
    pveam update
    echo "Downloading Debian 12 template..."
    pveam download local ${TEMPLATE}
    if [ $? -ne 0 ]; then
        echo "Failed to download template. Check available templates with 'pveam available --section system | grep debian-12' and update TEMPLATE variable."
        exit 1
    fi
fi

# Create the LXC container with nesting enabled for Docker
echo "Creating LXC container ${CTID}..."
pct create ${CTID} local:vztmpl/${TEMPLATE} \
    --hostname ${HOSTNAME} \
    --rootfs ${STORAGE}:${DISKSIZE} \
    --net0 name=eth0,bridge=${BRIDGE},ip=${IP} \
    --cores ${CORES} \
    --memory ${MEMORY} \
    --password ${PASSWORD} \
    --ostype debian \
    --features nesting=1,keyctl=1

if [ $? -ne 0 ]; then
    echo "Failed to create container."
    exit 1
fi

# Start the container
echo "Starting container ${CTID}..."
pct start ${CTID}
sleep 10  # Wait for container to start

# Update packages and install Docker inside the container
echo "Installing Docker inside the container..."
pct exec ${CTID} -- bash -c "apt update && apt upgrade -y && apt install -y ca-certificates curl gnupg"
pct exec ${CTID} -- bash -c "install -m 0755 -d /etc/apt/keyrings"
pct exec ${CTID} -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"
pct exec ${CTID} -- bash -c "chmod a+r /etc/apt/keyrings/docker.asc"
pct exec ${CTID} -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
pct exec ${CTID} -- bash -c "apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

# Install Dashy via Docker (basic setup; customize config as needed)
echo "Installing Dashy..."
pct exec ${CTID} -- bash -c "docker run -d -p 8080:80 --name dashy --restart=unless-stopped lissy93/dashy"
# Note: Access at http://container-ip:8080. Create /app/public/conf.yml volume for config if needed.

# Install Dockge via Docker
echo "Installing Dockge..."
pct exec ${CTID} -- bash -c "mkdir -p /opt/dockge/data /opt/dockge/stacks"
pct exec ${CTID} -- bash -c "docker run -d --name dockge -p 5001:5001 -v /var/run/docker.sock:/var/run/docker.sock -v /opt/dockge/data:/app/data -v /opt/dockge/stacks:/opt/stacks --restart unless-stopped louislam/dockge"
# Note: Access at http://container-ip:5001

# Install RunTipi
echo "Installing RunTipi..."
pct exec ${CTID} -- bash -c "apt install -y git"  # Needed for RunTipi if not already
pct exec ${CTID} -- bash -c "curl -L https://setup.runtipi.io | bash"
pct exec ${CTID} -- bash -c "cd /root/runtipi && ./tipi run"
# Note: RunTipi installs in /root/runtipi by default. Access at http://container-ip:80 (or configured port). Check RunTipi docs for further config.

echo "Installation complete! Container ID: ${CTID}"
echo "Login to container with: pct enter ${CTID}"
echo "Check services:"
echo "- Dashy: http://<container-ip>:8080"
echo "- Dockge: http://<container-ip>:5001"
echo "- RunTipi: http://<container-ip>:80 (default)"
echo "Note: If using static IP, set it in variables. Ensure ports are not conflicting and firewall allows them."
echo "For production, secure passwords, expose ports properly, and configure each app."
