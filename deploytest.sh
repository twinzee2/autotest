#!/bin/bash
set -e

echo "=== Настройка Proxmox (community репозитории) ==="

# Отключаем enterprise repo
sed -i 's|^deb https://enterprise.proxmox.com/debian/pve.*|# &|' /etc/apt/sources.list.d/pve-enterprise.list || true

# Добавляем no-subscription репозиторий
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-sub.list

apt update -y
apt install -y curl gnupg2 lsb-release apt-transport-https

echo "=== Загрузка шаблона Debian 12 ==="
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
STORAGE="local"

pveam update
if ! pveam list ${STORAGE} | grep -q "$TEMPLATE"; then
  pveam download ${STORAGE} $TEMPLATE
fi

echo "=== Создание LXC контейнера ==="

VMID=101
HOSTNAME="autolxc"
MEMORY=12288
CPUS=4
DISK="local:500"
BRIDGE="vmbr0"

pct create $VMID ${STORAGE}:vztmpl/$TEMPLATE \
  --hostname $HOSTNAME \
  --cores $CPUS \
  --memory $MEMORY \
  --rootfs $DISK \
  --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
  --unprivileged 1 \
  --start 1

echo "=== Установка Docker, Dockge и Runtipi ==="

pct exec $VMID -- bash -c "
  apt update -y &&
  apt install -y curl sudo git ca-certificates &&
  curl -fsSL https://get.docker.com | sh &&
  docker run hello-world || true &&
  mkdir -p /opt &&
  cd /opt &&
  git clone https://github.com/louislam/dockge &&
  cd dockge &&
  docker compose up -d &&
  curl -fsSL https://get.runtipi.com | bash
"

IP=$(pct exec $VMID -- hostname -I | awk '{print $1}')
echo "========================================="
echo "Ваш сервер настроен и доступен по адресу: http://$IP"
echo "========================================="
