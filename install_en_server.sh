#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}Ошибка: Запустите от имени root (sudo -i)${NC}"; exit 1; }

CONFIG_FILE="/root/.proxy_config"
HTML_FILE="/root/proxy_settings.html"

# --- Функции ---
check_installed() {
    echo -e "${BLUE}=== Проверка компонентов ===${NC}"
    command -v xray &>/dev/null && echo -e "${GREEN}✓ Xray установлен${NC}" || echo -e "${RED}✗ Xray не найден${NC}"
    systemctl is-active --quiet mtproto-proxy &>/dev/null && echo -e "${GREEN}✓ MTProto запущен${NC}" || echo -e "${YELLOW}⚠ MTProto не запущен${NC}"
    command -v ufw &>/dev/null && echo -e "${GREEN}✓ UFW установлен${NC}" || echo -e "${RED}✗ UFW не найден${NC}"
    echo ""
}

load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" && return 0
    return 1
}

save_config() {
    cat > "$CONFIG_FILE" <<CONF
SERVER_IP="${SERVER_IP}"
VLESS_UUID="${VLESS_UUID}"
SOCKS_USER="${SOCKS_USER}"
SOCKS_PASS="${SOCKS_PASS}"
MT_SECRET="${MT_SECRET}"
MT_TAG="${MT_TAG}"
VLESS_PORT="${VLESS_PORT}"
SOCKS_PORT="${SOCKS_PORT}"
MT_PORT="${MT_PORT}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
CONF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

generate_params() {
    SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    SOCKS_USER="proxy_user"
    SOCKS_PASS=$(openssl rand -hex 8)
    MT_SECRET="dd$(openssl rand -hex 16)"
    MT_TAG="ee$(openssl rand -hex 8)"
    VLESS_PORT=443; SOCKS_PORT=10808; MT_PORT=8888

    KEY_PAIR=$(xray x25519 2>/dev/null || xray uuid)
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep -i "Private" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep -i "Public" | awk '{print $3}')
    
    [ -z "$PRIVATE_KEY" ] && PRIVATE_KEY=$(openssl rand -hex 32)
    [ -z "$PUBLIC_KEY" ] && PUBLIC_KEY=$(openssl rand -hex 32)
}

install_deps() {
    apt-get update -y
    apt-get install -y curl wget jq openssl git build-essential cmake libssl-dev zlib1g-dev ufw
}

setup_xray() {
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    cat > /usr/local/etc/xray/config.json <<XRAY
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0", "port": ${VLESS_PORT}, "protocol": "vless",
      "settings": {"clients": [{"id": "${VLESS_UUID}", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "www.microsoft.com:443", "xver": 0,
          "serverNames": ["www.microsoft.com", "microsoft.com"],
          "privateKey": "${PRIVATE_KEY}", "shortIds": ["", "0123456789abcdef"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    },
    {
      "listen": "0.0.0.0", "port": ${SOCKS_PORT}, "protocol": "socks",
      "settings": {"auth": "password", "accounts": [{"user": "${SOCKS_USER}", "pass": "${SOCKS_PASS}"}], "udp": true}
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}]
}
XRAY
    systemctl enable --now xray
}

setup_mtproto() {
    [ ! -d "/opt/MTProxy" ] && cd /opt && git clone https://github.com/TelegramMessenger/MTProxy.git
    cd /opt/MTProxy && make -j$(nproc)
    mkdir -p /etc/mtproto
    cd /etc/mtproto
    curl -s https://core.telegram.org/getProxySecret -o proxy-secret
    curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf

    cat > /etc/systemd/system/mtproto-proxy.service <<MT
[Unit]
Description=MTProto Proxy
After=network.target
[Service]
Type=simple
WorkingDirectory=/etc/mtproto
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u nobody -p 8888 -H ${MT_PORT} -S ${MT_SECRET} -P ${MT_TAG} --aes-pwd proxy-secret proxy-multi.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
MT
    systemctl daemon-reload
    systemctl enable --now mtproto-proxy
}

setup_fw() {
    ufw allow ${VLESS_PORT}/tcp; ufw allow ${SOCKS_PORT}/tcp; ufw allow ${SOCKS_PORT}/udp; ufw allow ${MT_PORT}/tcp
    ufw --force enable
}

generate_html() {
    VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=&type=tcp&flow=xtls-rprx-vision#EN_VLESS"
    SOCKS_LINK="socks5://${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${SOCKS_PORT}#EN_SOCKS5"
    MT_LINK="tg://proxy?server=${SERVER_IP}&port=${MT_PORT}&secret=${MT_SECRET}${MT_TAG}"

    # Безопасная генерация HTML без конфликтов с JS
    cat > "$HTML_FILE" <<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Настройки прокси - EN Server</title>
<style>
body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:20px;background:#f8f9fa}
.card{background:#fff;border-radius:12px;padding:25px;margin:15px 0;box-shadow:0 4px 6px rgba(0,0,0,.1)}
h1{text-align:center;color:#1a202c} h2{color:#3182ce;border-bottom:2px solid #3182ce;padding-bottom:8px}
.box{background:#edf2f7;padding:12px;border-radius:6px;word-break:break-all;font-family:monospace;font-size:14px;margin:8px 0}
.lbl{font-weight:600;color:#2d3748;display:block;margin-top:12px}
.btn{background:#3182ce;color:#fff;border:none;padding:6px 12px;border-radius:4px;cursor:pointer;margin-left:8px}
.info{background:#ebf8ff;border-left:4px solid #3182ce;padding:15px;margin:20px 0}
</style>
</head>
<body>
<h1>🌐 EN Server - Настройки прокси</h1>
<div class="info"><strong>IP:</strong> ${SERVER_IP}<br><strong>Дата:</strong> $(date '+%Y-%m-%d %H:%M:%S')</div>
<div class="card"><h2>🔐 VLESS + REALITY</h2><span class="lbl">UUID:</span><div class="box">${VLESS_UUID}</div><span class="lbl">Public Key:</span><div class="box">${PUBLIC_KEY}</div><span class="lbl">Ссылка:</span><div class="box">${VLESS_LINK} <button class="btn" onclick="cp('${VLESS_LINK}')">📋</button></div></div>
<div class="card"><h2>🧦 SOCKS5</h2><span class="lbl">Логин:</span><div class="box">${SOCKS_USER}</div><span class="lbl">Пароль:</span><div class="box">${SOCKS_PASS}</div><span class="lbl">Ссылка:</span><div class="box">${SOCKS_LINK} <button class="btn" onclick="cp('${SOCKS_LINK}')">📋</button></div></div>
<div class="card"><h2>✈️ MTProto FakeTLS</h2><span class="lbl">Secret:</span><div class="box">${MT_SECRET}${MT_TAG}</div><span class="lbl">Ссылка:</span><div class="box">${MT_LINK} <button class="btn" onclick="cp('${MT_LINK}')">📋</button></div></div>
<script>function cp(t){navigator.clipboard.writeText(t).then(()=>alert('Скопировано!'))}</script>
</body></html>
HTML
}

# --- Меню ---
menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        EN Server Manager (Xray + MTProto)             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}\n"
    check_installed
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo "1) Полная установка/сброс"
    echo "2) Перезапуск сервисов"
    echo "3) Перегенерировать ключи и обновить конфиг"
    echo "4) Показать статус"
    echo "5) Вывести текущие настройки"
    echo "6) Полное удаление"
    echo "0) Выход"
    read -rp "Введите номер: " choice

    case $choice in
        1) echo -e "${GREEN}Установка...${NC}"; install_deps; generate_params; setup_xray; setup_mtproto; setup_fw; save_config; generate_html; echo -e "${GREEN}✅ Готово. HTML: $HTML_FILE${NC}";;
        2) systemctl restart xray mtproto-proxy 2>/dev/null && echo -e "${GREEN}✅ Перезапущено${NC}" || echo -e "${RED}❌ Ошибка${NC}";;
        3) load_config || true; generate_params; setup_xray; setup_mtproto; save_config; generate_html; echo -e "${GREEN}✅ Конфиг обновлен${NC}";;
        4) systemctl status xray mtproto-proxy --no-pager 2>/dev/null || echo "Сервисы не активны";;
        5) if load_config; then printf "IP: %s\nVLESS UUID: %s\nSOCKS: %s:%s\nMT Port: %s\nPubKey: %s\n" "$SERVER_IP" "$VLESS_UUID" "$SOCKS_USER" "$SOCKS_PASS" "$MT_PORT" "$PUBLIC_KEY"; else echo "Конфиг не найден"; fi;;
        6) read -rp "Удалить всё? (y/N): " ans; [ "$ans" = "y" ] && { systemctl stop xray mtproto-proxy 2>/dev/null; systemctl disable xray mtproto-proxy 2>/dev/null; rm -rf /usr/local/etc/xray /opt/MTProxy /etc/mtproto /etc/systemd/system/mtproto-proxy.service "$HTML_FILE" "$CONFIG_FILE"; systemctl daemon-reload; echo "✅ Удалено"; };;
        0) exit 0;;
        *) echo "Неверный ввод"; sleep 2; menu;;
    esac
    read -rp "Нажмите Enter для возврата в меню..."
    menu
}

menu