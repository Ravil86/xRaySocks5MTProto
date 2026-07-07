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

[Service]
Type=simple
WorkingDirectory=/etc/mtproto
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u nobody -p 8888 -H $MT_PORT -S $MT_SECRET -P $MT_TAG --aes-pwd proxy-secret proxy-multi.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start mtproto-proxy
systemctl enable mtproto-proxy

# 7. Файрвол и HTML
echo -e "${YELLOW}[7/7] Настройка UFW и генерация HTML...${NC}"
ufw allow $VLESS_PORT/tcp
ufw allow $SOCKS_PORT/tcp
ufw allow $SOCKS_PORT/udp
ufw allow $MT_PORT/tcp
ufw --force enable

# Формирование ссылок
VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=&type=tcp&flow=xtls-rprx-vision#EN_VLESS_REALITY"
SOCKS_LINK="socks5://${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${SOCKS_PORT}#EN_SOCKS5"
MT_LINK="tg://proxy?server=${SERVER_IP}&port=${MT_PORT}&secret=${MT_SECRET}${MT_TAG}"

# Создание HTML файла
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

echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo -e "${GREEN}HTML файл с настройками: /root/proxy_settings.html${NC}"
echo -e "${YELLOW}Откройте его в браузере для получения ссылок${NC}"
