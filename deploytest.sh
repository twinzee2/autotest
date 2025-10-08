#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log() { echo "[$(date +'%F %T')] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти скрипт от root (sudo)."
  exit 1
fi

# --- Отключаем enterprise repo и добавляем no-subscription ---
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
  log "Disabling /etc/apt/sources.list.d/pve-enterprise.list"
  mv /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.disabled || true
fi

cat > /etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF

log "Обновляем пакеты"
apt update -y || true
apt install -y curl wget gnupg2 lsb-release apt-transport-https ca-certificates

# --- Обновляем список шаблонов и находим Debian 12 template ---
log "Обновляем список шаблонов pveam"
pveam update || true

TEMPLATE=$(pveam available | grep -m1 -E 'debian-12-standard' | awk '{print $1}' || true)
if [ -z "$TEMPLATE" ]; then
  log "Не найден debian-12-standard в списке pveam. Пытаюсь ещё раз..."
  pveam update || true
  TEMPLATE=$(pveam available | grep -m1 -E 'debian-12-standard' | awk '{print $1}' || true)
fi
if [ -z "$TEMPLATE" ]; then
  log "Не удалось найти шаблон Debian 12 (debian-12-standard). Прекращаю."
  exit 1
fi
log "Найден шаблон: $TEMPLATE"

# --- Выбираем хранилища ---
STORAGE_DIR=$(pvesm status 2>/dev/null | awk 'NR>1 && $2=="dir" {print $1; exit}' || true)
if [ -z "$STORAGE_DIR" ]; then
  STORAGE_DIR=$(pvesm status 2>/dev/null | awk 'NR>1 {print $1; exit}' || true)
fi
if [ -z "$STORAGE_DIR" ]; then
  log "Не найдено доступных хранилищ (pvesm). Прекращаю."
  exit 1
fi

# для rootfs (попробуем lvmthin/zfs/dir по приоритету)
STORAGE_ROOT=$(pvesm status 2>/dev/null | awk 'NR>1 && ($2=="lvmthin" || $2=="zfspool" || $2=="zfs" || $2=="dir") {print $1; exit}' || true)
if [ -z "$STORAGE_ROOT" ]; then
  STORAGE_ROOT=$STORAGE_DIR
fi

log "Шаблоны будут скачаны в storage (dir): $STORAGE_DIR"
log "Rootfs контейнера будет размещён в: $STORAGE_ROOT"

# --- Скачиваем шаблон ---
log "Скачиваю шаблон: $TEMPLATE -> storage $STORAGE_DIR"
pveam download "$STORAGE_DIR" "$TEMPLATE"

TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE"
if [ ! -f "$TEMPLATE_PATH" ]; then
  log "Ожидал найти шаблон по пути $TEMPLATE_PATH, но не нашёл. Прекращаю."
  exit 1
fi

# --- Получаем следующий свободный VMID ---
VMID=$(pvesh get /cluster/nextid 2>/dev/null || true)
if [ -z "$VMID" ]; then
  log "Не удалось получить nextid через pvesh. Прекращаю."
  exit 1
fi

# --- Ищем бридж (vmbr0 или любой доступный) ---
BRIDGE="vmbr0"
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
  BRIDGE=$(ip -o link show | awk -F': ' '/br[0-9]/{print $2; exit}' || true)
  if [ -z "$BRIDGE" ]; then
    log "Не обнаружен bridge vmbr0 и нет других bridge-интерфейсов. Прекрати."
    exit 1
  fi
fi
log "Использую bridge: $BRIDGE"

# --- Параметры контейнера ---
HOSTNAME="lxc-debian12"
CORES=4
MEM=12288   # в MB = 12GB
ROOTFS_SIZE="500G"

log "Создаю LXC (vmid=$VMID) с $CORES CPU, $MEM MB RAM, $ROOTFS_SIZE rootfs..."
# Привилегированный контейнер + nesting для Docker
pct create "$VMID" "$TEMPLATE_PATH" --cores "$CORES" --memory "$MEM" --swap 0 \
  --hostname "$HOSTNAME" --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --rootfs "${STORAGE_ROOT}:${ROOTFS_SIZE}" --unprivileged 0 --features nesting=1,keyctl=1 --start 1

log "Контейнер создан и запущен. Ожидаю получения IP по DHCP..."

# --- Ожидаем IP в контейнере ---
IP=""
for i in $(seq 1 40); do
  sleep 3
  # получаем первый непустой IPv4 адрес
  IP=$(pct exec "$VMID" -- bash -lc "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | grep -v '^127.' | head -n1" 2>/dev/null || true)
  if [ -n "$IP" ]; then
    break
  fi
  log "Ожидание IP... попытка $i/40"
done

if [ -z "$IP" ]; then
  log "Контейнер не получил IP по DHCP в течение ожидаемого времени. Проверь сеть/браидж."
  pct status "$VMID" || true
  exit 1
fi

log "Контейнер $VMID получил IP: $IP"

# --- Установка Docker внутри контейнера ---
log "Устанавливаю Docker внутри контейнера $VMID..."
pct exec "$VMID" -- bash -lc "set -e; apt update; DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates curl gnupg lsb-release apt-transport-https; \
  mkdir -p /etc/apt/keyrings; \
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmour -o /etc/apt/keyrings/docker.gpg || true; \
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list; \
  apt update; DEBIAN_FRONTEND=noninteractive apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true"

# Попытка запустить Docker (в LXC systemd должен работать)
pct exec "$VMID" -- bash -lc "systemctl enable --now docker || true"

# --- Разворачиваем Portainer (UI для Docker) ---
log "Устанавливаю Portainer (Docker GUI)..."
pct exec "$VMID" -- bash -lc "docker volume create portainer_data >/dev/null 2>&1 || true; \
  docker run -d --name portainer --restart=always -p 9000:9000 -p 8000:8000 \
    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest >/dev/null 2>&1 || true"

# --- Разворачиваем Dashy (простой статический образ в контейнере) ---
log "Устанавливаю Dashy (панель ссылок)..."
pct exec "$VMID" -- bash -lc "mkdir -p /opt/dashy; \
  docker run -d --name dashy --restart unless-stopped -p 8080:80 -v /opt/dashy:/dashy ghcr.io/lissy93/dashy:latest >/dev/null 2>&1 || true"

# --- Пробуем установить Runtipi (если образ доступен) ---
log "Пробую запустить Runtipi (если образ доступен)..."
pct exec "$VMID" -- bash -lc "docker run -d --name runtipi --restart unless-stopped -p 3000:3000 twinzee/runtipi:latest >/dev/null 2>&1 || echo 'Runtipi image not found / failed to run'"

# --- Финальный вывод ---
cat <<EOF

Ваш сервер настроен и доступен по адресу: ${IP}

Сервисы (если успешно запущены):
 - Portainer:  http://${IP}:9000
 - Dashy:      http://${IP}:8080
 - Runtipi:    http://${IP}:3000   (если образ был доступен)

VMID контейнера: $VMID
Шаблон: $TEMPLATE

EOF

log "Готово."
