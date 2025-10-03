bash -s <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR at line $LINENO"; exit 2' ERR

# --------- Параметры (можно переопределить через env) ----------
CTID=${CTID:-101}
STORAGE=${STORAGE:-local}
ROOTFS_GB=${ROOTFS_GB:-16}
HOSTNAME=${HOSTNAME:-dashy-node}
PASSWORD=${PASSWORD:-ChangeMeStrong!}
CORES=${CORES:-2}
MEMORY=${MEMORY:-2048}
BRIDGE=${BRIDGE:-vmbr0}
# --------------------------------------------------------------

echo "=== 0) Настройка локалей (UTF-8) ==="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y locales console-data >/dev/null 2>&1 || true
if ! grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null; then
  echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
fi
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
echo "Locale set to: $LANG"

echo "=== 1) Обновляем список шаблонов pveam ==="
if ! pveam update >/dev/null 2>&1; then
  echo "WARNING: pveam update failed — проверь интернет/прокси. Попробую продолжить."
fi

echo "=== 2) Ищем подходящий debian-*-standard шаблон ==="
TEMPLATE_NAME=$(pveam available 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^debian-[0-9]+.*-standard.*\.tar\.zst$/) {print $i; exit}}' || true)
if [ -z "$TEMPLATE_NAME" ]; then
  TEMPLATE_NAME=$(pveam available 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^debian-.*-standard.*\.tar\.zst$/) {print $i; exit}}' || true)
fi

if [ -z "$TEMPLATE_NAME" ]; then
  echo "ERROR: не найден debian-*-standard шаблон в 'pveam available'. Вывод 'pveam available' для отладки:"
  pveam available | sed -n '1,200p'
  echo ""
  echo "Если в выводе есть строка вроде 'debian-12-standard_12.7-1_amd64.tar.zst', скопируй её и скачай вручную:"
  echo "  pveam download $STORAGE <имя-шаблона-из-вывода>"
  exit 1
fi

echo "Найден шаблон: $TEMPLATE_NAME"
echo "=== 3) Скачиваем шаблон в storage: $STORAGE ==="
pveam download "$STORAGE" "$TEMPLATE_NAME" || { echo "pveam download завершился с ошибкой"; exit 1; }
TEMPLATE_PATH="${STORAGE}:vztmpl/${TEMPLATE_NAME}"
echo "TEMPLATE_PATH = $TEMPLATE_PATH"

echo "=== 4) Создаём LXC (CTID=$CTID) ==="
pct create "$CTID" "$TEMPLATE_PATH" \
  --hostname "$HOSTNAME" \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --cores "$CORES" --memory "$MEMORY" --rootfs "${STORAGE}:${ROOTFS_GB}" \
  --password "$PASSWORD" --unprivileged 1 --onboot 1 \
  --features keyctl=1,nesting=1,fuse=1

echo "Запускаю контейнер..."
pct start "$CTID"
sleep 6

echo "=== 5) Устанавливаем Docker и зависимости внутри контейнера ==="
pct exec "$CTID" -- bash -lc "apt update && DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates curl gnupg lsb-release apt-transport-https fuse-overlayfs"
pct exec "$CTID" -- bash -lc "curl -fsSL https://get.docker.com | sh"
pct exec "$CTID" -- bash -lc "apt-get install -y docker-compose-plugin || true"

pct exec "$CTID" -- bash -lc 'cat >/etc/docker/daemon.json <<JSON
{
  "storage-driver": "fuse-overlayfs"
}
JSON
systemctl restart docker || true'

echo "=== 6) Разворачиваем Dashy (docker compose) ==="
pct exec "$CTID" -- bash -lc 'mkdir -p /opt/dashy/user-data && cat >/opt/dashy/docker-compose.yml <<EOF
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
cd /opt/dashy && docker compose up -d || docker compose up -d || true'

echo "=== 7) Устанавливаем Runtipi (официальный инсталлер) ==="
pct exec "$CTID" -- bash -lc "curl -L https://setup.runtipi.io | bash || true"

echo "=== DONE ==="
pct exec "$CTID" -- docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
echo "Если нужно — подключись: pct enter $CTID"
SCRIPT
