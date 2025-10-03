#!/bin/bash
set -euo pipefail

# Proxmox LXC + Docker deploy script
# Автор: ChatGPT (подготовлено для пользователя)
# Запускается на хосте Proxmox под root.
# Измените переменные в блоке ниже перед запуском.

#########################
# Настройки (подредактируйте)
#########################
CTID=103                         # ID контейнера (уникальный)
HOSTNAME="dashy-container"      # hostname внутри контейнера
STORAGE="local-lvm"             # хранилище для rootfs (local, local-lvm и т.п.)
DISKSIZE=15                      # размер диска в GB
MEMORY=4096                      # MB
CORES=4                          # vCPU
BRIDGE="vmbr0"                 # мост на хосте Proxmox
# Сетевая настройка: поставьте 'dhcp' или статический в формате 'IP/MASK,gw=GW'
# Пример статического: "192.168.1.150/24,gw=192.168.1.1"
STATIC_IP="dhcp"
PASSWORD="changeme"             # смените на безопасный пароль
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"  # шаблон (проверьте версию на своём хосте)

# Порты (можно изменить)
DASHY_PORT=8080
DOCKGE_PORT=5001
RUNTIPI_PORT=80

LOGFILE="/var/log/proxmox_lxc_deploy_${CTID}.log"

#########################
# Вспомогательные функции
#########################
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE"; }
err(){ echo "ERROR: $*" | tee -a "$LOGFILE"; exit 1; }

# Проверки
if [ "$(id -u)" -ne 0 ]; then
    err "Этот скрипт должен быть запущен от root на Proxmox хосте."
fi

log "Запуск скрипта. Лог: $LOGFILE"

# Проверим наличие моста
if ! ip link show "${BRIDGE}" >/dev/null 2>&1; then
    err "Bridge ${BRIDGE} не найден на хосте. Проверьте конфигурацию сети в Proxmox (обычно vmbr0)."
fi

# Настроим no-subscription репо если нужно (не перепишет, если уже есть)
if ! grep -q "pve-no-subscription" /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null; then
    log "Добавляю no-subscription репозиторий Proxmox..."
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
    if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
        sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list || true
    fi
    if [ -f /etc/apt/sources.list.d/ceph.list ]; then
        sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list || true
    fi
    apt update -y || true
fi

# Проверим шаблон и скачиваем при необходимости
if [ ! -f "/var/lib/vz/template/cache/${TEMPLATE}" ]; then
    log "Шаблон ${TEMPLATE} не найден — обновляю список и пытаюсь скачать..."
    pveam update || true
    pveam download local ${TEMPLATE} || err "Не удалось скачать шаблон. Проверьте наличее шаблонов (pveam available --section system)."
fi

# Проверим существование контейнера
if pct status ${CTID} >/dev/null 2>&1; then
    err "Контейнер с CTID=${CTID} уже существует. Удалите его или выберите другой CTID."
fi

# Подготовим параметр сети для pct create
if [ -z "${STATIC_IP}" ] || [ "${STATIC_IP}" = "dhcp" ]; then
    NET_PARAM="dhcp"
else
    NET_PARAM="${STATIC_IP}"
fi

# Создание контейнера (privileged для корректной работы Docker в LXC)
log "Создаю контейнер ${CTID} (privileged, nesting=1)..."
pct create ${CTID} local:vztmpl/${TEMPLATE} \
    --hostname ${HOSTNAME} \
    --rootfs ${STORAGE}:${DISKSIZE}G \
    --net0 name=eth0,bridge=${BRIDGE},ip=${NET_PARAM} \
    --cores ${CORES} \
    --memory ${MEMORY} \
    --password ${PASSWORD} \
    --ostype debian \
    --features nesting=1,keyctl=1 \
    --unprivileged 0

log "Запуск контейнера ${CTID}..."
pct start ${CTID}

# Ждём, пока контейнер запустится
for i in {1..30}; do
    status=$(pct status ${CTID} | awk '{print $2}' || true)
    if [ "${status}" = "running" ]; then
        break
    fi
    sleep 1
done

if [ "${status}" != "running" ]; then
    err "Контейнер не запущен. Статус: ${status}. Проверьте журнал.")
fi

# Получим IP контейнера
CT_IP=""
if [ "${NET_PARAM}" != "dhcp" ]; then
    # когда задан статический IP в формате IP/MASK,gw=GW — извлекаем IP
    ippart=$(echo "${NET_PARAM}" | cut -d',' -f1)
    CT_IP=$(echo "${ippart}" | cut -d'/' -f1)
else
    log "Ожидаю назначения DHCP IP контейнеру (макс. 60 сек)..."
    for i in {1..60}; do
        CT_IP=$(pct exec ${CTID} -- bash -lc "ip -4 -o addr show eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" || true)
        if [ -n "${CT_IP}" ]; then break; fi
        sleep 1
    done
fi

if [ -z "${CT_IP}" ]; then
    err "Не удалось получить IP контейнера. Проверьте сеть, DHCP или статические настройки."
fi

log "Контейнер запущен, IP: ${CT_IP}"

# Проверим доступ в интернет из контейнера (нужно для apt и docker install)
if ! pct exec ${CTID} -- bash -lc "ping -c1 -W1 1.1.1.1 >/dev/null 2>&1"; then
    log "Внимание: контейнер не имеет доступа в интернет. Убедитесь в правильности шлюза и правил firewall на хосте/proxmox." 
    # не выходим — пользователь может хотеть локальный deploy, но установку Docker без интернета не сделать
    err "Контейнеру нужен интернет для установки Docker — проверьте настройки сети."
fi

# Установка Docker внутри контейнера
log "Устанавливаю Docker внутри контейнера..."
# Устанавливаем пакеты и репозиторий Docker
pct exec ${CTID} -- bash -lc "apt update && apt upgrade -y && apt install -y ca-certificates curl gnupg lsb-release apt-transport-https"

pct exec ${CTID} -- bash -lc "install -m0755 -d /etc/apt/keyrings"
pct exec ${CTID} -- bash -lc "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.gpg && chmod a+r /etc/apt/keyrings/docker.gpg"

pct exec ${CTID} -- bash -lc 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo \$VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list'

pct exec ${CTID} -- bash -lc "apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

# Убедимся, что docker запущен
pct exec ${CTID} -- bash -lc "systemctl enable --now docker || service docker start || true"

if ! pct exec ${CTID} -- bash -lc "docker version >/dev/null 2>&1"; then
    err "Docker не запустился корректно внутри контейнера. Проверьте логи (pct exec ${CTID} -- journalctl -u docker).")
fi

log "Docker установлен и запущен."

# Установка Dashy
log "Устанавливаю Dashy (docker)..."
# Готовим папку для данных — опционально
pct exec ${CTID} -- bash -lc "mkdir -p /opt/dashy"
pct exec ${CTID} -- bash -lc "docker run -d -p ${DASHY_PORT}:80 --name dashy --restart=unless-stopped lissy93/dashy >/dev/null"
log "Dashy Dashboard установлен и настроен, доступен по адресу: http://${CT_IP}:${DASHY_PORT}"

# Установка Dockge
log "Устанавливаю Dockge (docker)..."
pct exec ${CTID} -- bash -lc "mkdir -p /opt/dockge/data /opt/dockge/stacks"
pct exec ${CTID} -- bash -lc "docker run -d --name dockge -p ${DOCKGE_PORT}:5001 -v /var/run/docker.sock:/var/run/docker.sock -v /opt/dockge/data:/app/data -v /opt/dockge/stacks:/opt/stacks --restart unless-stopped louislam/dockge >/dev/null"
log "Dockge установлен и доступен по адресу: http://${CT_IP}:${DOCKGE_PORT}"

# Установка RunTipi
log "Устанавливаю RunTipi..."
pct exec ${CTID} -- bash -lc "apt install -y git"
pct exec ${CTID} -- bash -lc "curl -L https://setup.runtipi.io | bash" || log "RunTipi установщик вернул код ошибки (возможно, требуется интерактив)."
# Попробуем запустить в фоне (nohup)
pct exec ${CTID} -- bash -lc "if [ -x /root/runtipi/tipi ]; then nohup /root/runtipi/tipi run >/var/log/runtipi.log 2>&1 & sleep 1; fi" || true
log "RunTipi (если успешно установлен) запущен в фоне. Проверьте: pct exec ${CTID} -- bash -lc 'ss -tlnp | grep tipi || true'"
log "RunTipi доступен (если сервис поднялся) по: http://${CT_IP}:${RUNTIPI_PORT}"

log "Установка завершена. Резюме:"
log "- CTID: ${CTID}"
log "- IP контейнера: ${CT_IP}"
log "- Dashy: http://${CT_IP}:${DASHY_PORT}"
log "- Dockge: http://${CT_IP}:${DOCKGE_PORT}"
log "- RunTipi: http://${CT_IP}:${RUNTIPI_PORT} (если поднялся)"

log "Если вы не можете подключиться из локальной сети, проверьте следующее на хосте Proxmox:"
cat <<EOF | tee -a "$LOGFILE"
1) Наличие моста: ip link show ${BRIDGE}
2) Форвардинг IPv4: sysctl net.ipv4.ip_forward (должно быть 1)
3) Правила firewall на хосте: pve-firewall status (или iptables -L FORWARD -n)
4) Сетевой статус контейнера: pct exec ${CTID} -- ip a
5) Список запущенных контейнеров и их IP: pct list; pct exec ${CTID} -- ip -4 -o addr show eth0
EOF

log "Готово. Лог: $LOGFILE"

# Конец скрипта
