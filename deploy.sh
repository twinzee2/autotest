#!/usr/bin/env bash
set -euo pipefail
# ---- Настройки (подкорректируй) ----
CTID=101
NODE=$(hostname)
STORAGE=local          # proxmox storage, например local, local-lvm, SSD и т.д.
ROOTFS_GB=16
HOSTNAME="node"
PASSWORD="root"
CORES=2
MEMORY=2048            # MB
BRIDGE=vmbr0
# ------------------------------------

echo "1) Обновим список шаблонов..."
pveam update

# Попробуем найти свежий debian-12 template (если не нашли — вручную выставь TEMPLATE_NAME)
TEMPLATE_NAME=$(pveam available | awk '/debian-12-standard/ {print $1; exit}')
if [ -z "$TEMPLATE_NAME" ]; then
  echo "Не найден debian-12 шаблон. Выполни 'pveam available' и укажи TEMPLATE_NAME вручную."
  exit 1
fi
echo "Найден шаблон: $TEMPLATE_NAME"
echo "Скачиваем шаблон на хост storage=${STORAGE}..."
pveam download ${STORAGE} ${TEMPLATE_NAME}

TEMPLATE_PATH="${STORAGE}:vztmpl/${TEMPLATE_NAME}"
echo "TEMPLATE_PATH=${TEMPLATE_PATH}"

echo "2) Создаём LXC (CTID=${CTID}) с enabled features (keyctl,nesting,fuse)..."
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

echo "3) Запускаем контейнер и ждём..."
pct start ${CTID}
sleep 6
pct status ${CTID}

echo "4) Установка Docker и зависимостей внутри контейнера..."
pct exec ${CTID} -- bash -lc "apt update && DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates curl gnupg lsb-release apt-transport-https fuse-overlayfs"

# Установим Docker официальным скриптом
pct exec ${CTID} -- bash -lc "curl -fsSL https://get.docker.com | sh"

# Установим docker compose plugin (пакетный)
pct exec ${CTID} -- bash -lc "apt update && DEBIAN_FRONTEND=noninteractive apt install -y docker-compose-plugin || true"

# Прописать storage-driver (рекомендуется для unprivileged LXC)
pct exec ${CTID} -- bash -lc 'cat > /etc/docker/daemon.json <<JSON
{
  "storage-driver": "fuse-overlayfs"
}
JSON
systemctl restart docker || echo \"systemctl restart docker failed (check logs)\"'

echo "5) Создаём docker-compose для Dashy и поднимаем контейнер..."
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

echo "6) Установка Runtipi (официальный инсталлер)..."
pct exec ${CTID} -- bash -lc "curl -L https://setup.runtipi.io | bash"

echo "Готово. Проверим статус docker контейнеров:"
pct exec ${CTID} -- bash -lc "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true"

echo "Полезные команды:
- Просмотреть логи LXC: pct console ${CTID}  (или pct exec ${CTID} -- journalctl -u docker -n 200)
- Подключиться внутрь: pct enter ${CTID}
- Перезапустить dashy: pct exec ${CTID} -- docker restart dashy
"
