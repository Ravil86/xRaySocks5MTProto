#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите от имени root${NC}"
  exit 1
fi

echo -e "${GREEN}=== Установка EN сервера (Xray + MTProto + SOCKS5) ===${NC}"

# Получение IP
SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)
echo -e "${YELLOW}IP сервера: $SERVER_IP${NC}"

# 1. Установка зависимостей
echo -e "${YELLOW}[1/7] Установка зависимостей...${NC}"
apt-get update -y
apt-get install -y curl wget unzip jq openssl ufw git build-essential cmake libssl-dev zlib1g-dev

# 2. Генерация параметров
echo -e "${YELLOW}[2/7] Генерация ключей и паролей...${NC}"
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
SOCKS_USER="proxy_user"
SOCKS_PASS=$(openssl rand -hex 8)
MT_SECRET="dd$(openssl rand -hex 16)"
MT_TAG="ee$(openssl rand -hex 8)"

VLESS_PORT=443
SOCKS_PORT=10808
MT_PORT=8888

# 3. Установка Xray-core
echo -e "${YELLOW}[3/7] Установка Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Генерация ключей x25519 для REALITY
KEY_PAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "Public" | awk '{print $3}')

# 4. Конфигурация Xray
echo -e "${YELLOW}[4/7] Настройка Xray (VLESS + REALITY + SOCKS5)...${NC}"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$VLESS_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": [
            "www.microsoft.com",
            "microsoft.com"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "",
            "0123456789abcdef"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "0.0.0.0",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$SOCKS_USER",
            "pass": "$SOCKS_PASS"
          }
        ],
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

systemctl restart xray
systemctl enable xray

# 5. Компиляция MTProto Proxy без Docker
echo -e "${YELLOW}[5/7] Компиляция MTProto Proxy из исходников...${NC}"
cd /opt
git clone https://github.com/TelegramMessenger/MTProxy.git
cd MTProxy
make -j$(nproc)

# Создание директории для конфигов
mkdir -p /etc/mtproto
cd /etc/mtproto

# Получение telegram secret и конфига
curl -s https://core.telegram.org/getProxySecret -o proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf

# 6. Создание systemd сервиса для MTProto
echo -e "${YELLOW}[6/7] Настройка systemd сервиса MTProto...${NC}"
cat > /etc/systemd/system/mtproto-proxy.service <<EOF
[Unit]
Description=MTProto Proxy Server
After=network.target

#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите от имени root${NC}"
  exit 1
fi

# Файл для сохранения параметров
CONFIG_FILE="/root/.proxy_config"

# Функция проверки установленных компонентов
check_installed() {
    echo -e "${BLUE}=== Проверка установленных компонентов ===${NC}"
    
    INSTALLED_XRAY=false
    INSTALLED_MTPROTO=false
    INSTALLED_UFW=false
    
    if command -v xray &> /dev/null; then
        XRAY_VERSION=$(xray version | head -n 1)
        echo -e "${GREEN}✓ Xray установлен: $XRAY_VERSION${NC}"
        INSTALLED_XRAY=true
    else
        echo -e "${RED}✗ Xray не установлен${NC}"
    fi
    
    if systemctl is-active --quiet mtproto-proxy; then
        echo -e "${GREEN}✓ MTProto Proxy запущен${NC}"
        INSTALLED_MTPROTO=true
    elif [ -f "/opt/MTProxy/objs/bin/mtproto-proxy" ]; then
        echo -e "${YELLOW}⚠ MTProto Proxy установлен, но не запущен${NC}"
        INSTALLED_MTPROTO=true
    else
        echo -e "${RED}✗ MTProto Proxy не установлен${NC}"
    fi
    
    if command -v ufw &> /dev/null; then
        echo -e "${GREEN}✓ UFW установлен${NC}"
        INSTALLED_UFW=true
    else
        echo -e "${RED}✗ UFW не установлен${NC}"
    fi
    
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${GREEN}✓ Конфигурация найдена: $CONFIG_FILE${NC}"
    else
        echo -e "${YELLOW}⚠ Конфигурация не найдена${NC}"
    fi
    
    echo ""
}

# Функция загрузки старых параметров
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# Функция сохранения параметров
save_config() {
    cat > "$CONFIG_FILE" <<EOF
SERVER_IP="$SERVER_IP"
VLESS_UUID="$VLESS_UUID"
SOCKS_USER="$SOCKS_USER"
SOCKS_PASS="$SOCKS_PASS"
MT_SECRET="$MT_SECRET"
MT_TAG="$MT_TAG"
VLESS_PORT="$VLESS_PORT"
SOCKS_PORT="$SOCKS_PORT"
MT_PORT="$MT_PORT"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
EOF
    chmod 600 "$CONFIG_FILE"
}

# Функция генерации новых параметров
generate_new_params() {
    echo -e "${YELLOW}Генерация новых параметров...${NC}"
    SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    SOCKS_USER="proxy_user"
    SOCKS_PASS=$(openssl rand -hex 8)
    MT_SECRET="dd$(openssl rand -hex 16)"
    MT_TAG="ee$(openssl rand -hex 8)"
    
    VLESS_PORT=443
    SOCKS_PORT=10808
    MT_PORT=8888
    
    # Генерация ключей x25519 для REALITY
    KEY_PAIR=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "Private" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "Public" | awk '{print $3}')
}

# Функция установки Xray
install_xray() {
    echo -e "${YELLOW}[Xray] Установка/обновление Xray-core...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# Функция создания конфигурации Xray
configure_xray() {
    echo -e "${YELLOW}[Xray] Создание конфигурации...${NC}"
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$VLESS_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": [
            "www.microsoft.com",
            "microsoft.com"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "",
            "0123456789abcdef"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "0.0.0.0",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$SOCKS_USER",
            "pass": "$SOCKS_PASS"
          }
        ],
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
    
    systemctl restart xray
    systemctl enable xray
}

# Функция установки MTProto
install_mtproto() {
    echo -e "${YELLOW}[MTProto] Компиляция MTProto Proxy...${NC}"
    
    # Проверка наличия исходников
    if [ ! -d "/opt/MTProxy" ]; then
        cd /opt
        git clone https://github.com/TelegramMessenger/MTProxy.git
        cd MTProxy
        make -j$(nproc)
    else
        echo -e "${BLUE}Исходники уже существуют, перекомпиляция...${NC}"
        cd /opt/MTProxy
        make clean
        make -j$(nproc)
    fi
    
    # Создание директории для конфигов
    mkdir -p /etc/mtproto
    cd /etc/mtproto
    
    # Получение telegram secret и конфига
    curl -s https://core.telegram.org/getProxySecret -o proxy-secret
    curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf
}

# Функция настройки MTProto сервиса
configure_mtproto() {
    echo -e "${YELLOW}[MTProto] Настройка systemd сервиса...${NC}"
    cat > /etc/systemd/system/mtproto-proxy.service <<EOF
[Unit]
Description=MTProto Proxy Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/mtproto
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u nobody -p 8888 -H $MT_PORT -S $MT_SECRET -P $MT_TAG --aes-pwd proxy-secret proxy-multi.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl restart mtproto-proxy
    systemctl enable mtproto-proxy
}

# Функция генерации HTML
generate_html() {
    echo -e "${YELLOW}[HTML] Генерация файла с настройками...${NC}"
    
    VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=&type=tcp&flow=xtls-rprx-vision#EN_VLESS_REALITY"
    SOCKS_LINK="socks5://${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${SOCKS_PORT}#EN_SOCKS5"
    MT_LINK="tg://proxy?server=${SERVER_IP}&port=${MT_PORT}&secret=${MT_SECRET}${MT_TAG}"
    
    cat > /root/proxy_settings.html <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Настройки прокси - EN Server</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 900px; margin: 50px auto; padding: 20px; background: #f5f5f5; }
        .card { background: white; border-radius: 10px; padding: 25px; margin: 20px 0; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #2c3e50; text-align: center; }
        h2 { color: #3498db; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        .config-box { background: #ecf0f1; padding: 15px; border-radius: 5px; word-break: break-all; font-family: monospace; font-size: 14px; }
        .label { font-weight: bold; color: #2c3e50; margin-top: 15px; display: block; }
        .value { color: #e74c3c; margin: 5px 0 15px 0; }
        .copy-btn { background: #3498db; color: white; border: none; padding: 8px 15px; border-radius: 5px; cursor: pointer; margin-left: 10px; }
        .copy-btn:hover { background: #2980b9; }
        .info { background: #d5edf8; border-left: 4px solid #3498db; padding: 15px; margin: 20px 0; }
    </style>
</head>
<body>
    <h1>🌐 Настройки прокси - EN Server</h1>
    
    <div class="info">
        <strong>IP сервера:</strong> ${SERVER_IP}<br>
        <strong>Дата создания:</strong> $(date '+%Y-%m-%d %H:%M:%S')
    </div>

    <div class="card">
        <h2>🔐 VLESS + REALITY (Vision)</h2>
        <span class="label">UUID:</span>
        <div class="config-box">${VLESS_UUID}</div>
        
        <span class="label">Public Key:</span>
        <div class="config-box">${PUBLIC_KEY}</div>
        
        <span class="label">SNI:</span>
        <div class="config-box">www.microsoft.com</div>
        
        <span class="label">Порт:</span>
        <div class="config-box">${VLESS_PORT}</div>
        
        <span class="label">Ссылка для импорта:</span>
        <div class="config-box">${VLESS_LINK} <button class="copy-btn" onclick="copyToClipboard('${VLESS_LINK}')">Копировать</button></div>
    </div>

    <div class="card">
        <h2>🧦 SOCKS5</h2>
        <span class="label">Логин:</span>
        <div class="config-box">${SOCKS_USER}</div>
        
        <span class="label">Пароль:</span>
        <div class="config-box">${SOCKS_PASS}</div>
        
        <span class="label">Порт:</span>
        <div class="config-box">${SOCKS_PORT}</div>
        
        <span class="label">Ссылка для импорта:</span>
        <div class="config-box">${SOCKS_LINK} <button class="copy-btn" onclick="copyToClipboard('${SOCKS_LINK}')">Копировать</button></div>
    </div>

    <div class="card">
        <h2>✈️ MTProto (FakeTLS)</h2>
        <span class="label">Secret:</span>
        <div class="config-box">${MT_SECRET}${MT_TAG}</div>
        
        <span class="label">Порт:</span>
        <div class="config-box">${MT_PORT}</div>
        
        <span class="label">Ссылка для Telegram:</span>
        <div class="config-box">${MT_LINK} <button class="copy-btn" onclick="copyToClipboard('${MT_LINK}')">Копировать</button></div>
    </div>

    <script>
        function copyToClipboard(text) {
            navigator.clipboard.writeText(text).then(() => {
                alert('Скопировано в буфер обмена!');
            });
        }
    </script>
</body>
</html>
EOF
}

# Функция настройки файрвола
configure_firewall() {
    echo -e "${YELLOW}[UFW] Настройка файрвола...${NC}"
    apt-get install -y ufw
    ufw allow $VLESS_PORT/tcp
    ufw allow $SOCKS_PORT/tcp
    ufw allow $SOCKS_PORT/udp
    ufw allow $MT_PORT/tcp
    ufw --force enable
}

# Функция полной установки
full_install() {
    echo -e "${GREEN}=== Полная установка ===${NC}"
    
    echo -e "${YELLOW}[1/7] Установка зависимостей...${NC}"
    apt-get update -y
    apt-get install -y curl wget unzip jq openssl git build-essential cmake libssl-dev zlib1g-dev
    
    echo -e "${YELLOW}[2/7] Генерация параметров...${NC}"
    generate_new_params
    
    echo -e "${YELLOW}[3/7] Установка Xray...${NC}"
    install_xray
    
    echo -e "${YELLOW}[4/7] Настройка Xray...${NC}"
    configure_xray
    
    echo -e "${YELLOW}[5/7] Установка MTProto...${NC}"
    install_mtproto
    
    echo -e "${YELLOW}[6/7] Настройка MTProto...${NC}"
    configure_mtproto
    
    echo -e "${YELLOW}[7/7] Настройка файрвола...${NC}"
    configure_firewall
    
    save_config
    generate_html
    
    echo -e "${GREEN}=== Установка завершена! ===${NC}"
    echo -e "${GREEN}HTML файл: /root/proxy_settings.html${NC}"
}

# Функция перезапуска всех сервисов
restart_all() {
    echo -e "${GREEN}=== Перезапуск всех сервисов ===${NC}"
    
    if [ -f "$CONFIG_FILE" ]; then
        load_config
        systemctl restart xray
        systemctl restart mtproto-proxy
        echo -e "${GREEN}✓ Сервисы перезапущены${NC}"
    else
        echo -e "${RED}✗ Конфигурация не найдена${NC}"
    fi
}

# Функция обновления только конфигурации
update_config_only() {
    echo -e "${GREEN}=== Обновление конфигурации ===${NC}"
    
    if [ -f "$CONFIG_FILE" ]; then
        load_config
        echo -e "${YELLOW}Использовать существующие параметры? (y/n)${NC}"
        read -p "> " USE_OLD
        
        if [ "$USE_OLD" != "y" ]; then
            generate_new_params
        fi
        
        configure_xray
        configure_mtproto
        save_config
        generate_html
        
        echo -e "${GREEN}✓ Конфигурация обновлена${NC}"
    else
        echo -e "${RED}✗ Конфигурация не найдена. Выполните полную установку.${NC}"
    fi
}

# Функция удаления
uninstall_all() {
    echo -e "${RED}=== Удаление всех компонентов ===${NC}"
    echo -e "${YELLOW}Вы уверены? (y/n)${NC}"
    read -p "> " CONFIRM
    
    if [ "$CONFIRM" = "y" ]; then
        systemctl stop xray mtproto-proxy 2>/dev/null
        systemctl disable xray mtproto-proxy 2>/dev/null
        
        rm -rf /usr/local/etc/xray
        rm -rf /opt/MTProxy
        rm -rf /etc/mtproto
        rm -f /etc/systemd/system/mtproto-proxy.service
        rm -f /root/proxy_settings.html
        rm -f "$CONFIG_FILE"
        
        systemctl daemon-reload
        
        echo -e "${GREEN}✓ Все компоненты удалены${NC}"
    else
        echo -e "${BLUE}Отменено${NC}"
    fi
}

# Главное меню
show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     EN Server - Управление прокси (Xray + MTProto)    ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_installed
    
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo "1) Полная установка (с нуля)"
    echo "2) Перезапустить все сервисы"
    echo "3) Обновить конфигурацию (перегенерировать ключи)"
    echo "4) Показать статус сервисов"
    echo "5) Показать текущие настройки"
    echo "6) Удалить все компоненты"
    echo "0) Выход"
    echo ""
    read -p "Введите номер: " CHOICE
    
    case $CHOICE in
        1) full_install ;;
        2) restart_all ;;
        3) update_config_only ;;
        4) 
            echo -e "${BLUE}=== Статус сервисов ===${NC}"
            systemctl status xray --no-pager
            echo ""
            systemctl status mtproto-proxy --no-pager
            read -p "Нажмите Enter для продолжения..."
            show_menu
            ;;
        5)
            if [ -f "$CONFIG_FILE" ]; then
                load_config
                echo -e "${BLUE}=== Текущие настройки ===${NC}"
                echo "IP: $SERVER_IP"
                echo "VLESS UUID: $VLESS_UUID"
                echo "VLESS Port: $VLESS_PORT"
                echo "SOCKS User: $SOCKS_USER"
                echo "SOCKS Pass: $SOCKS_PASS"
                echo "SOCKS Port: $SOCKS_PORT"
                echo "MTProto Port: $MT_PORT"
                echo "Public Key: $PUBLIC_KEY"
            else
                echo -e "${RED}Конфигурация не найдена${NC}"
            fi
            read -p "Нажмите Enter для продолжения..."
            show_menu
            ;;
        6) uninstall_all; show_menu ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверный выбор${NC}"; sleep 2; show_menu ;;
    esac
}

# Запуск
show_menu