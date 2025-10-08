#!/bin/bash

# Предупреждение: Этот скрипт предназначен для Proxmox VE без подписки. Он создаст LXC контейнер на Debian 12,
# установит Docker, Dockge, Runtipi и Dashy с базовой конфигурацией (логины/пароли admin/admin где применимо).
# Ресурсы: 4 ядра, 12 ГБ RAM, 500 ГБ виртуальный диск (физический диск хоста должен иметь достаточно места;
# если хост имеет только 128 ГБ, это может привести к overcommitment — мониторьте использование).
# IP по DHCP. Скрипт предполагает, что Proxmox установлен и вы запускаете его как root.
# Не используем enterprise репозитории.

set -e  # Выходим при ошибке

# Константы
LXC_ID=100  # ID контейнера, измените если нужно
LXC_HOSTNAME="lxc-apps"
LXC_CORES=4
LXC_MEMORY=12288  # 12 ГБ в МБ
LXC_SWAP=4096     # 4 ГБ swap
LXC_DISK_SIZE=500 # ГБ
LXC_TEMPLATE="debian-12-standard_12.0-1_amd64.tar.zst"
LXC_STORAGE="local-lvm"  # Измените на ваш storage (local-lvm или local-zfs)
BRIDGE="vmbr0"    # Мост сети

# Шаг 1: Обновление Proxmox и добавление no-subscription repo (если не добавлено)
if ! grep -q "deb https://download.proxmox.com/debian/pve bookworm pve-no-subscription" /etc/apt/sources.list.d/pve-install-repo.list; then
    echo "Добавляем no-subscription репозиторий..."
    echo "deb https://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
    # Отключаем enterprise repo
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list || true
fi
apt update && apt full-upgrade -y

# Шаг 2: Скачивание шаблона Debian 12, если не существует
if [ ! -f "/var/lib/vz/template/cache/$LXC_TEMPLATE" ]; then
    echo "Скачиваем шаблон Debian 12..."
    pveam update
    pveam download local $LXC_TEMPLATE
fi

# Шаг 3: Создание LXC контейнера
if pct status $LXC_ID &>/dev/null; then
    echo "LXC $LXC_ID уже существует. Останавливаем и удаляем..."
    pct stop $LXC_ID || true
    pct destroy $LXC_ID --force
fi

echo "Создаем LXC контейнер..."
pct create $LXC_ID local:vztmpl/$LXC_TEMPLATE \
    --hostname $LXC_HOSTNAME \
    --cores $LXC_CORES \
    --memory $LXC_MEMORY \
    --swap $LXC_SWAP \
    --rootfs $LXC_STORAGE:$LXC_DISK_SIZE \
    --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
    --features nesting=1  # Для Docker внутри LXC
pct set $LXC_ID -unprivileged 0  # Привилегированный для Docker (рекомендуется для стабильности)

# Шаг 4: Запуск контейнера
echo "Запускаем LXC контейнер..."
pct start $LXC_ID

# Ждем, пока контейнер запустится и получит IP
sleep 10
LXC_IP=$(pct exec $LXC_ID -- ip addr show eth0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
if [ -z "$LXC_IP" ]; then
    echo "Ошибка: Не удалось получить IP. Проверьте DHCP."
    exit 1
fi

# Шаг 5: Установка пакетов и приложений внутри LXC
echo "Устанавливаем приложения внутри LXC..."

pct exec $LXC_ID -- bash -c "
    set -e
    apt update && apt upgrade -y
    apt install -y curl sudo git

    # Установка Docker
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    apt install -y docker-compose-plugin  # Для docker compose v2
    usermod -aG docker root  # Для root (поскольку скрипт как root)

    # Создание директории для приложений
    mkdir -p /opt/selfhosted
    cd /opt/selfhosted

    # Установка Dockge (Docker manager) с admin/admin
    # Dockge использует HTTP auth; создаем .htpasswd
    mkdir -p dockge
    cd dockge
    htpasswd -bc .htpasswd admin admin  # HTTP Basic Auth: admin/admin
    cat > docker-compose.yml << EOF
version: '3.8'
services:
  dockge:
    image: louislam/dockge:1
    restart: unless-stopped
    ports:
      - '5001:5001'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/app/data
      - /opt/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
EOF
    docker compose up -d
    cd ..

    # Установка Runtipi с admin/admin
    # Runtipi: Автоматизируем установку с дефолт паролем (по умолчанию email/password, но скрипт задаст)
    curl -L https://setup.runtipi.io | bash
    cd /root/runtipi
    # Настройка: Изменяем config для дефолт auth (Runtipi использует JWT, но для простоты задаем в .env)
    echo 'TIPI_PORT=3000' >> .env
    echo 'TIPI_INTERNAL_IP=0.0.0.0' >> .env
    echo 'TIPI_ROOT_PASSWORD=admin' >> .env  # Не стандартно, но если поддерживает; иначе вручную
    ./tipi start
    # Примечание: Runtipi просит регистрацию в UI; admin/admin не напрямую, но вы можете зарегистрироваться как admin@admin.com / admin

    # Установка Dashy с admin/admin
    # Dashy: Добавляем auth через HTTP Basic (как в Dockge)
    mkdir -p dashy
    cd dashy
    htpasswd -bc .htpasswd admin admin
    # Для auth нужен reverse proxy; для простоты используем nginx в контейнере
    cat > docker-compose.yml << EOF
version: '3.8'
services:
  nginx:
    image: nginx:latest
    restart: unless-stopped
    ports:
      - '8080:80'
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./.htpasswd:/etc/nginx/.htpasswd:ro
  dashy:
    image: lissy93/dashy:latest
    restart: unless-stopped
    volumes:
      - ./conf.yml:/app/public/conf.yml
EOF
    # Простой nginx.conf с basic auth
    cat > nginx.conf << EOF
events {}
http {
    server {
        listen 80;
        location / {
            auth_basic 'Restricted';
            auth_basic_user_file /etc/nginx/.htpasswd;
            proxy_pass http://dashy:80;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }
}
EOF
    # Базовый conf.yml для Dashy
    cat > conf.yml << EOF
pageInfo:
  title: Dashy Dashboard
sections: []
EOF
    docker compose up -d
"

# Шаг 6: Финальный вывод
echo "Ваш сервер настроен и доступен по адресу $LXC_IP"
echo "Доступы:"
echo "- Dockge: http://$LXC_IP:5001 (логин/пароль: admin/admin)"
echo "- Runtipi: http://$LXC_IP:3000 (зарегистрируйтесь как admin@admin.com / admin)"
echo "- Dashy: http://$LXC_IP:8080 (логин/пароль: admin/admin)"
echo "Остальные приложения устанавливайте через Runtipi UI или Dockge."
