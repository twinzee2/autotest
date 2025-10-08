#!/bin/bash
set -e

echo "=== Настройка Proxmox (no-subscription репозиторий) ==="

# Отключаем enterprise репозиторий, если он есть
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
  sed -i 's|^deb https://enterprise.proxmox.com/debian/pve.*|# &|' /etc/apt/sources.list.d/pve-enterprise.list || true
fi

# Добавляем репозиторий без подписки (если не добавлен)
if [ ! -f /etc/apt/sources.list.d/pve-no-sub.list ]; then
  echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-sub.list
fi

apt update -y
apt install -y curl gnupg2 lsb-release apt-transport-https

echo "=== Создание LXC контейнера на Debian 12 ==="

# Настройки контейнера
VMID=101
HOSTNAME="autolxc"
MEMORY=12288      # 12 GB
CPUS=4
DISK="local:500"  # 500 GB
BRIDGE="vmbr0"
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"

# Проверяем, существует ли контейнер с таким VMID
if pct status $VMID &>/dev/null; then
  echo "⚠️ Контейнер с VMID=$VMID уже существует. Удалите его перед запуском скрипта."
  exit 1
fi

# Создание LXC
pct create $VMID $TEMPLATE \
  --hostname $HOSTNAME \
  --cores $CPUS \
  --memory $MEMORY \
  --rootfs $DISK \
  --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
  --unprivileged 1 \
  --start 1

echo "=== Установка Docker, Dockge и Runtipi в контейнер ==="

pct exec $VMID -- bash -c "
  set -e
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

# Получаем IP контейнера
IP=$(pct exec $VMID -- hostname -I | awk '{print $1}')

echo "========================================="
echo "✅ Ваш сервер настроен и доступен по адресу: http://$IP"
echo "========================================="
