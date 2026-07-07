#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите от имени root${NC}"
  exit 1
fi

echo -e "${GREEN}=== Настройка RU relay сервера ===${NC}"

# Запрос IP EN сервера
read -p "Введите IP EN сервера: " EN_SERVER_IP
read -p "Введите порт VLESS EN сервера (по умолчанию 443): " EN_VLESS_PORT
read -p "Введите порт SOCKS5 EN сервера (по умолчанию 10808): " EN_SOCKS_PORT
read -p "Введите порт MTProto EN сервера (по умолчанию 8888): " EN_MT_PORT

EN_VLESS_PORT=${EN_VLESS_PORT:-443}
EN_SOCKS_PORT=${EN_SOCKS_PORT:-10808}
EN_MT_PORT=${EN_MT_PORT:-8888}

# Порты на RU сервере (можно изменить)
RU_VLESS_PORT=443
RU_SOCKS_PORT=10808
RU_MT_PORT=8888

# 1. Установка зависимостей
echo -e "${YELLOW}[1/4] Установка зависимостей...${NC}"
apt-get update -y
apt-get install -y iptables iptables-persistent socat ufw

# 2. Настройка iptables для прозрачного проксирования
echo -e "${YELLOW}[2/4] Настройка iptables (DNAT)...${NC}"

# Включение IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Очистка старых правил
iptables -t nat -F
iptables -F

# VLESS relay
iptables -t nat -A PREROUTING -p tcp --dport $RU_VLESS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_VLESS_PORT}
iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_VLESS_PORT} -j MASQUERADE

# SOCKS5 relay
iptables -t nat -A PREROUTING -p tcp --dport $RU_SOCKS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_SOCKS_PORT}
iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_SOCKS_PORT} -j MASQUERADE
iptables -t nat -A PREROUTING -p udp --dport $RU_SOCKS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_SOCKS_PORT}
iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p udp --dport ${EN_SOCKS_PORT} -j MASQUERADE

# MTProto relay
iptables -t nat -A PREROUTING -p tcp --dport $RU_MT_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_MT_PORT}
iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_MT_PORT} -j MASQUERADE

# Сохранение правил iptables
iptables-save > /etc/iptables/rules.v4

# 3. Альтернатива: socat для более надежного проксирования (опционально)
echo -e "${YELLOW}[3/4] Создание systemd сервисов для socat (альтернатива iptables)...${NC}"

# VLESS через socat
cat > /etc/systemd/system/relay-vless.service <<EOF
[Unit]
Description=VLESS Relay to EN Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${RU_VLESS_PORT},reuseaddr,fork TCP:${EN_SERVER_IP}:${EN_VLESS_PORT}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# SOCKS5 через socat
cat > /etc/systemd/system/relay-socks.service <<EOF
[Unit]
Description=SOCKS5 Relay to EN Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${RU_SOCKS_PORT},reuseaddr,fork TCP:${EN_SERVER_IP}:${EN_SOCKS_PORT}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# MTProto через socat
cat > /etc/systemd/system/relay-mtproto.service <<EOF
[Unit]
Description=MTProto Relay to EN Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${RU_MT_PORT},reuseaddr,fork TCP:${EN_SERVER_IP}:${EN_MT_PORT}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# 4. Файрвол
echo -e "${YELLOW}[4/4] Настройка UFW...${NC}"
ufw allow $RU_VLESS_PORT/tcp
ufw allow $RU_SOCKS_PORT/tcp
ufw allow $RU_SOCKS_PORT/udp
ufw allow $RU_MT_PORT/tcp
ufw --force enable

RU_SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)

# Создание HTML с инструкциями
cat > /root/relay_info.html <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>RU Relay - Информация</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; background: #f5f5f5; }
        .card { background: white; border-radius: 10px; padding: 25px; margin: 20px 0; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #2c3e50; text-align: center; }
        .info { background: #d5edf8; border-left: 4px solid #3498db; padding: 15px; margin: 20px 0; }
        .warning { background: #fcf8e3; border-left: 4px solid #f0ad4e; padding: 15px; margin: 20px 0; }
        code { background: #ecf0f1; padding: 2px 6px; border-radius: 3px; }
    </style>
</head>
<body>
    <h1>🇷🇺 RU Relay Server</h1>
    
    <div class="info">
        <strong>RU Server IP:</strong> ${RU_SERVER_IP}<br>
        <strong>EN Server IP:</strong> ${EN_SERVER_IP}
    </div>

    <div class="card">
        <h2>⚙️ Настроенные порты</h2>
        <ul>
            <li><strong>VLESS:</strong> ${RU_VLESS_PORT} → ${EN_SERVER_IP}:${EN_VLESS_PORT}</li>
            <li><strong>SOCKS5:</strong> ${RU_SOCKS_PORT} → ${EN_SERVER_IP}:${EN_SOCKS_PORT}</li>
            <li><strong>MTProto:</strong> ${RU_MT_PORT} → ${EN_SERVER_IP}:${EN_MT_PORT}</li>
        </ul>
    </div>

    <div class="warning">
        <h3>⚠️ Важно для клиентов:</h3>
        <p>Используйте <strong>IP RU сервера (${RU_SERVER_IP})</strong> вместо IP EN сервера в настройках клиентов!</p>
        <p>Все остальные параметры (UUID, ключи, пароли) остаются такими же, как на EN сервере.</p>
    </div>

    <div class="card">
        <h2>🔧 Управление relay</h2>
        <p><strong>iptables (прозрачный relay):</strong></p>
        <code>systemctl status iptables</code><br>
        <code>iptables -t nat -L -n -v</code>
        
        <p style="margin-top: 20px;"><strong>socat (альтернативный relay):</strong></p>
        <code>systemctl start relay-vless relay-socks relay-mtproto</code><br>
        <code>systemctl enable relay-vless relay-socks relay-mtproto</code>
    </div>
</body>
</html>
EOF

echo -e "${GREEN}=== Настройка RU relay завершена! ===${NC}"
echo -e "${GREEN}HTML файл: /root/relay_info.html${NC}"
echo -e "${YELLOW}Важно: В клиентах используйте IP RU сервера (${RU_SERVER_IP})${NC}"
