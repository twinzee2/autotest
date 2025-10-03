#!/usr/bin/env bash
set -euo pipefail

# ========== ШАГ 0. Фикс локалей / шрифтов ==========
echo ">>> Настройка UTF-8 локали..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y locales console-data
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8
echo ">>> Локаль выставлена: $LANG"

# ========== ШАГ 1. Настройки ==========
CTID=101
NODE=$(hostname)
STORAGE=local
ROOTFS_GB=16
HOSTNAME="dashy-node"
PASSWORD="ChangeMeStrong!"
CORES=2
MEMORY=2048
BRIDGE=vmbr0

# ========== ШАГ 2. Поиск и загрузка шаблона ==========
echo ">>> Обновляем список LXC шаблонов..."
pveam update

TEMPLATE_NAME=$(pveam available | grep -m1 debian-12-standard | awk '{print $2}')
if [ -z "${TEMPLATE_NAME}" ]; then
  echo ">>> Шаблон debian-12-standard не найден в списке, пробуем напрямую..."
  TEMPLATE_NAME="debian-12-standard_12.7-1_amd64.tar.zst"
fi

echo ">>> Скачиваем шаблон: $TEMPLATE_NAME в хранилище $STORAGE..."
if ! pveam list $STORAGE | grep -q "$TEMPLATE_NAME"; then
  pveam download $STORAGE $TEMPLATE_NAME
fi
TEMPLATE_PATH="${STORAGE}:vztmpl/${TEMPLATE_NAME}"

# ========== ШАГ 3. Создание контейнера ==========
echo ">>> Создаем LXC (CTID=$CTID)..."
pct create ${CTID} ${TEMPLATE_PATH} \
  --hostname ${HOSTNAME} \
  --net0 name=eth0,bridge=${BRIDGE},ip=dhcp \
  --cores ${CORES} \
  --memory ${MEMORY} \
  --rootfs ${STORAGE}:${ROOTFS_GB} \
  --password "${PASSWORD}" \
  --unprivileged 1 \
  --onboot 1 \
  --features keyctl=1,nesting=1,fuse=1

pct start ${CTID}
sleep 6

# ========== ШАГ 4. Установка Docker и утилит ==========
echo ">>> Устанавливаем Docker и зависимости в контейнер..."
pct exec ${CTID} -- bash -lc "apt update && DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates curl gnupg lsb-release apt-transport-https fuse-overlayfs"
pct exec ${CTID} -- bash -lc "curl -fsSL https://get.docker.com | sh"
pct exec ${CTID} -- bash -lc "apt install -y docker-compose-plugin"

pct exec ${CTID} -- bash -lc 'cat > /etc/docker/daemon.json <<JSON
{
  "storage-driver": "fuse-overlayfs"
}
JSON
systemctl restart docker || echo \"docker restart failed\"'

# ========== ШАГ 5. Dashy ==========
echo ">>> Разворачиваем Dashy..."
pct exec ${CTID} -- bash -lc 'mkdir -p /opt/dashy /opt/dashy/user-data && cat > /opt/dashy/docker-compose.yml <<EOF
version: "3.8"
services:
  dashy:
    image: ghcr.io/lissy93/dashy:latest
    container_name: dashy
    ports:
      - "8080:80"
    volumes:
      - /opt/dashy/user-data:/app/user-data
    restart: unless-stopped
EOF
cd /opt/dashy && docker compose up -d'

# ========== ШАГ 6. Runtipi ==========
echo ">>> Устанавливаем Runtipi..."
pct exec ${CTID} -- bash -lc "curl -L https://setup.runtipi.io | bash"

echo ">>> Всё готово! Проверка контейнеров:"
pct exec ${CTID} -- docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
