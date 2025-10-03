#!/bin/bash
set -e

echo "=== [1/6] Fixing locale and fonts ==="
apt-get update -y
apt-get install -y locales console-data
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8

echo "=== [2/6] Disabling enterprise repos and enabling no-subscription ==="
mkdir -p /root/pve-apt-backup
grep -Rl "enterprise.proxmox.com" /etc/apt 2>/dev/null | while read -r f; do
  echo "Backing up and disabling: $f"
  mv "$f" "/root/pve-apt-backup/$(basename "$f").disabled"
done

cat > /etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF

apt-get install -y wget gnupg || true
wget -qO- https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg | apt-key add - || true

echo "=== [3/6] Updating apt ==="
apt-get update -y
apt-get -y dist-upgrade

echo "=== [4/6] Ensuring Debian LXC template is available ==="
pveam update
TEMPLATE_NAME=$(pveam available | grep debian-12-standard | head -n1 | awk '{print $2}')

if [ -z "$TEMPLATE_NAME" ]; then
  echo "ERROR: No Debian LXC template found!"
  exit 1
fi

if ! ls /var/lib/vz/template/cache/ | grep -q "$TEMPLATE_NAME"; then
  echo "Downloading template: $TEMPLATE_NAME"
  pveam download local "$TEMPLATE_NAME"
else
  echo "Template already exists: $TEMPLATE_NAME"
fi

echo "=== [5/6] Deploying LXC with Debian 12 ==="
# Пример: создаём контейнер с ID 101 (можно менять)
VMID=101
HOSTNAME="autostack"
STORAGE="local-lvm"

if pct status $VMID &>/dev/null; then
  echo "Container $VMID already exists, skipping creation"
else
  pct create $VMID local:vztmpl/$TEMPLATE_NAME \
    --hostname $HOSTNAME \
    --cores 2 \
    --memory 2048 \
    --swap 512 \
    --rootfs $STORAGE:8 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --unprivileged 1 \
    --password root
  pct start $VMID
fi

echo "=== [6/6] Installing stack inside LXC ==="
pct exec $VMID -- bash -c "apt-get update -y && apt-get install -y curl git docker.io docker-compose"

# Dashy
pct exec $VMID -- bash -c "docker run -d \
  -p 8080:80 \
  --name dashy \
  -v /opt/dashy:/app/public \
  lissy93/dashy"

# Dockge
pct exec $VMID -- bash -c "docker run -d \
  --name dockge \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 5001:5001 \
  louislam/dockge:latest"

# Runtipi (ставим через скрипт)
pct exec $VMID -- bash -c "curl -fsSL https://get.runtipi.com | bash"

echo "=== Deployment finished! ==="
echo "Dashy: http://<LXC-IP>:8080"
echo "Dockge: http://<LXC-IP>:5001"
