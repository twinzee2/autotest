#!/bin/bash
# ================================
# Proxmox LXC Deploy with UTF-8 fix
# ================================

CTID=103
HOSTNAME="docker-lxc"
MEMORY=2048
DISK_SIZE=16
STORAGE="local-lvm"

LOGFILE="/var/log/proxmox_lxc_deploy_${CTID}.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "===================================="
echo " Запуск деплоя контейнера CT $CTID "
echo "===================================="

# --- 1. Исправляем локаль на хосте ---
echo ">> Настраиваем локаль UTF-8 на хосте..."
apt-get update
apt-get install -y locales
locale-gen en_US.UTF-8 ru_RU.UTF-8
update-locale LANG=en_US.UTF-8

# --- 2. Проверим, нет ли старого контейнера ---
if pct status $CTID &>/dev/null; then
    echo ">> Контейнер $CTID уже существует, удаляю..."
    pct stop $CTID || true
    pct destroy $CTID -force || true
fi

# --- 3. Создаём LXC ---
echo ">> Создаём LXC $CTID..."
pveam update
TEMPLATE=$(pveam available | grep debian-12 | grep amd64 | awk '{print $2}' | head -n1)

if [ -z "$TEMPLATE" ]; then
    echo ">> Не найден шаблон Debian 12, скачиваю..."
    pveam download local debian-12-standard_12.7-1_amd64.tar.zst
    TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
fi

pct create $CTID $TEMPLATE \
    -hostname $HOSTNAME \
    -memory $MEMORY \
    -net0 name=eth0,bridge=vmbr0,ip=dhcp \
    -rootfs $STORAGE:${DISK_SIZE} \
    -features nesting=1 \
    -cores 2 -swap 512

# --- 4. Запуск ---
echo ">> Запускаем CT $CTID..."
pct start $CTID

# --- 5. Настройка локали внутри контейнера ---
echo ">> Настройка UTF-8 в контейнере..."
pct exec $CTID -- bash -lc "apt-get update && apt-get install -y locales"
pct exec $CTID -- bash -lc "locale-gen en_US.UTF-8 ru_RU.UTF-8"
pct exec $CTID -- bash -lc "update-locale LANG=en_US.UTF-8"

echo "===================================="
echo " Контейнер $CTID успешно развернут! "
echo " Лог: $LOGFILE"
echo "===================================="
