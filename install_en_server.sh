#!/usr/bin/env bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}Ошибка: Запустите от имени root (sudo -i)${NC}"; exit 1; }

CONFIG_FILE="/root/.proxy_config"
HTML_FILE="/root/proxy_settings.html"
XRAY_CFG="/usr/local/etc/xray/config.json"
MT_DIR="/opt/MTProxy"
MT_CONF="/etc/mtproto"

# --- Проверка компонентов ---
check_installed() {
    echo -e "${BLUE}=== Статус компонентов ===${NC}"
    if command -v xray &>/dev/null; then
        echo -e "  ${GREEN}✓ Xray: $(xray version 2>/dev/null | head -1)${NC}"
    else
        echo -e "  ${RED}✗ Xray не установлен${NC}"
    fi
    if systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
        echo -e "  ${GREEN}✓ MTProto: запущен${NC}"
    elif [ -f "$MT_DIR/objs/bin/mtproto-proxy" ]; then
        echo -e "  ${YELLOW}⚠ MTProto: установлен, но не запущен${NC}"
    else
        echo -e "  ${RED}✗ MTProto: не установлен${NC}"
    fi
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "  ${GREEN}✓ Конфигурация сохранена${NC}"
    else
        echo -e "  ${YELLOW}⚠ Конфигурация не найдена${NC}"
    fi
    if [ -f "$HTML_FILE" ]; then
        echo -e "  ${GREEN}✓ HTML-файл: $HTML_FILE${NC}"
    else
        echo -e "  ${YELLOW}⚠ HTML не сгенерирован${NC}"
    fi
    echo ""
}

# --- Загрузка/сохранение конфига ---
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
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
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}✓ Конфигурация сохранена в $CONFIG_FILE${NC}"
}

# --- Генерация параметров ---
generate_params() {
    echo -e "${YELLOW}→ Генерация новых параметров...${NC}"
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ipinfo.io/ip)
    [ -z "$SERVER_IP" ] && SERVER_IP="unknown"
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    SOCKS_USER="proxy_user"
    SOCKS_PASS=$(openssl rand -hex 8)
    MT_SECRET="dd$(openssl rand -hex 16)"
    MT_TAG="ee$(openssl rand -hex 8)"
    VLESS_PORT=443
    SOCKS_PORT=10808
    MT_PORT=8888

    if command -v xray &>/dev/null; then
        KEY_PAIR=$(xray x25519 2>/dev/null)
        PRIVATE_KEY=$(echo "$KEY_PAIR" | grep -i "Private" | awk '{print $3}')
        PUBLIC_KEY=$(echo "$KEY_PAIR" | grep -i "Public" | awk '{print $3}')
    fi
    [ -z "$PRIVATE_KEY" ] && PRIVATE_KEY=$(openssl rand -hex 32)
    [ -z "$PUBLIC_KEY" ] && PUBLIC_KEY=$(openssl rand -hex 32)

    echo -e "${GREEN}✓ Параметры сгенерированы (IP: $SERVER_IP)${NC}"
}

# --- Установка зависимостей (БЕЗ UFW) ---
install_deps() {
    echo -e "${YELLOW}→ Установка зависимостей...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget jq openssl git build-essential cmake libssl-dev zlib1g-dev iptables >/dev/null 2>&1
    echo -e "${GREEN}✓ Зависимости установлены${NC}"
}

# --- Отключение UFW (если был установлен ранее) ---
disable_ufw() {
    if systemctl is-active --quiet ufw 2>/dev/null; then
        echo -e "${YELLOW}→ Обнаружен активный UFW. Отключаю, чтобы не блокировать SSH...${NC}"
        ufw disable >/dev/null 2>&1 || true
        systemctl stop ufw 2>/dev/null || true
        systemctl disable ufw 2>/dev/null || true
        echo -e "${GREEN}✓ UFW отключён${NC}"
    fi
}

# --- Установка Xray ---
setup_xray() {
    echo -e "${YELLOW}→ Установка/обновление Xray-core...${NC}"
    if command -v xray &>/dev/null; then
        echo -e "  Xray уже установлен, обновление..."
    fi
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>&1 | tail -5
    if [ ! -d "/usr/local/etc/xray" ]; then
        mkdir -p /usr/local/etc/xray
    fi
    echo -e "${GREEN}✓ Xray установлен${NC}"
}

# --- Конфигурация Xray ---
configure_xray() {
    echo -e "${YELLOW}→ Запись конфигурации Xray...${NC}"
    cat > "$XRAY_CFG" <<XRAY
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${VLESS_UUID}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com", "microsoft.com"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["", "0123456789abcdef"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    },
    {
      "listen": "0.0.0.0",
      "port": ${SOCKS_PORT},
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [{"user": "${SOCKS_USER}", "pass": "${SOCKS_PASS}"}],
        "udp": true
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
XRAY
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ Xray настроен и запущен (VLESS:${VLESS_PORT}, SOCKS:${SOCKS_PORT})${NC}"
    else
        echo -e "${RED}✗ Xray не запустился. Проверьте: journalctl -u xray -n 20${NC}"
    fi
}

# --- Установка MTProto ---
setup_mtproto() {
    echo -e "${YELLOW}→ Компиляция MTProto Proxy...${NC}"
    if [ ! -d "$MT_DIR" ]; then
        echo -e "  Клонирование репозитория..."
        cd /opt && git clone https://github.com/TelegramMessenger/MTProxy.git >/dev/null 2>&1
    fi
    cd "$MT_DIR"
    echo -e "  Компиляция (может занять 2-5 минут)..."
    make clean >/dev/null 2>&1
    make -j$(nproc) >/dev/null 2>&1
    if [ ! -f "$MT_DIR/objs/bin/mtproto-proxy" ]; then
        echo -e "${RED}✗ Ошибка компиляции MTProto${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ MTProto скомпилирован${NC}"

    mkdir -p "$MT_CONF"
    cd "$MT_CONF"
    curl -s https://core.telegram.org/getProxySecret -o proxy-secret
    curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf
    echo -e "${GREEN}✓ Конфигурация Telegram загружена${NC}"
}

# --- Настройка сервиса MTProto ---
configure_mtproto() {
    echo -e "${YELLOW}→ Настройка systemd сервиса MTProto...${NC}"
    cat > /etc/systemd/system/mtproto-proxy.service <<MT
[Unit]
Description=MTProto Proxy Server
After=network.target
[Service]
Type=simple
WorkingDirectory=${MT_CONF}
ExecStart=${MT_DIR}/objs/bin/mtproto-proxy -u nobody -p 8888 -H ${MT_PORT} -S ${MT_SECRET} -P ${MT_TAG} --aes-pwd proxy-secret proxy-multi.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
MT
    systemctl daemon-reload
    systemctl enable mtproto-proxy >/dev/null 2>&1
    systemctl restart mtproto-proxy
    sleep 1
    if systemctl is-active --quiet mtproto-proxy; then
        echo -e "${GREEN}✓ MTProto запущен на порту ${MT_PORT}${NC}"
    else
        echo -e "${RED}✗ MTProto не запустился. Проверьте: journalctl -u mtproto-proxy -n 20${NC}"
    fi
}

# --- Файрвол через iptables (БЕЗ UFW) ---
setup_fw() {
    echo -e "${YELLOW}→ Настройка iptables (открытие портов)...${NC}"
    
    # Определяем SSH порт (обычно 22)
    local SSH_PORT
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    SSH_PORT=${SSH_PORT:-22}
    
    # Разрешаем SSH ВСЕГДА (критично!)
    iptables -C INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p tcp --dport $SSH_PORT -j ACCEPT
    
    # Разрешаем loopback
    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -i lo -j ACCEPT
    
    # Разрешаем установленные соединения
    iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Открываем порты прокси
    for port in $VLESS_PORT $SOCKS_PORT $MT_PORT; do
        iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    # UDP для SOCKS
    iptables -C INPUT -p udp --dport $SOCKS_PORT -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p udp --dport $SOCKS_PORT -j ACCEPT
    
    # Сохранение правил iptables
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    
    # Установка iptables-persistent для автозагрузки
    if ! dpkg -l | grep -q iptables-persistent; then
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        apt-get install -y iptables-persistent >/dev/null 2>&1
    fi
    
    echo -e "${GREEN}✓ iptables настроен (SSH:${SSH_PORT}, VLESS:${VLESS_PORT}, SOCKS:${SOCKS_PORT}, MT:${MT_PORT})${NC}"
    echo -e "${YELLOW}  ⚠ UFW НЕ используется — только iptables${NC}"
}

# --- Генерация HTML ---
generate_html() {
    echo -e "${YELLOW}→ Генерация HTML-файла...${NC}"
    local VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=&type=tcp&flow=xtls-rprx-vision#EN_VLESS"
    local SOCKS_LINK="socks5://${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${SOCKS_PORT}#EN_SOCKS5"
    local MT_LINK="tg://proxy?server=${SERVER_IP}&port=${MT_PORT}&secret=${MT_SECRET}${MT_TAG}"

    cat > "$HTML_FILE" <<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Настройки прокси - EN Server</title>
<style>
body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:20px;background:#f8f9fa}
.card{background:#fff;border-radius:12px;padding:25px;margin:15px 0;box-shadow:0 4px 6px rgba(0,0,0,.1)}
h1{text-align:center;color:#1a202c}
h2{color:#3182ce;border-bottom:2px solid #3182ce;padding-bottom:8px}
.box{background:#edf2f7;padding:12px;border-radius:6px;word-break:break-all;font-family:monospace;font-size:14px;margin:8px 0}
.lbl{font-weight:600;color:#2d3748;display:block;margin-top:12px}
.btn{background:#3182ce;color:#fff;border:none;padding:6px 12px;border-radius:4px;cursor:pointer;margin-left:8px}
.info{background:#ebf8ff;border-left:4px solid #3182ce;padding:15px;margin:20px 0}
</style>
</head>
<body>
<h1>🌐 EN Server - Настройки прокси</h1>
<div class="info"><strong>IP:</strong> ${SERVER_IP}<br><strong>Дата:</strong> $(date '+%Y-%m-%d %H:%M:%S')</div>
<div class="card"><h2>🔐 VLESS + REALITY</h2><span class="lbl">UUID:</span><div class="box">${VLESS_UUID}</div><span class="lbl">Public Key:</span><div class="box">${PUBLIC_KEY}</div><span class="lbl">Порт:</span><div class="box">${VLESS_PORT}</div><span class="lbl">Ссылка:</span><div class="box">${VLESS_LINK} <button class="btn" onclick="cp(this,'${VLESS_LINK}')">📋</button></div></div>
<div class="card"><h2>🧦 SOCKS5</h2><span class="lbl">Логин:</span><div class="box">${SOCKS_USER}</div><span class="lbl">Пароль:</span><div class="box">${SOCKS_PASS}</div><span class="lbl">Порт:</span><div class="box">${SOCKS_PORT}</div><span class="lbl">Ссылка:</span><div class="box">${SOCKS_LINK} <button class="btn" onclick="cp(this,'${SOCKS_LINK}')">📋</button></div></div>
<div class="card"><h2>✈️ MTProto FakeTLS</h2><span class="lbl">Secret:</span><div class="box">${MT_SECRET}${MT_TAG}</div><span class="lbl">Порт:</span><div class="box">${MT_PORT}</div><span class="lbl">Ссылка:</span><div class="box">${MT_LINK} <button class="btn" onclick="cp(this,'${MT_LINK}')">📋</button></div></div>
<script>function cp(b,t){navigator.clipboard.writeText(t).then(function(){b.textContent='✓';setTimeout(function(){b.textContent='📋'},1500)})}</script>
</body></html>
HTML
    echo -e "${GREEN}✓ HTML сгенерирован: $HTML_FILE${NC}"
}

# --- ПУНКТ 1: Полная установка ---
do_full_install() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ПОЛНАЯ УСТАНОВКА EN СЕРВЕРА       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    read -rp "Начать полную установку? Все текущие настройки будут перезаписаны (y/N): " ans
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "Отменено"; return; }
    
    disable_ufw
    install_deps
    setup_xray
    generate_params
    configure_xray
    setup_mtproto
    configure_mtproto
    setup_fw
    save_config
    generate_html
    
    echo -e "\n${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "HTML-файл с настройками: ${YELLOW}$HTML_FILE${NC}"
}

# --- ПУНКТ 2: Перезапуск ---
do_restart() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ПЕРЕЗАПУСК СЕРВИСОВ            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    echo -e "${YELLOW}→ Перезапуск Xray...${NC}"
    systemctl restart xray 2>&1
    sleep 1
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}  ✓ Xray перезапущен${NC}"
    else
        echo -e "${RED}  ✗ Xray не запустился${NC}"
    fi
    
    echo -e "${YELLOW}→ Перезапуск MTProto...${NC}"
    systemctl restart mtproto-proxy 2>&1
    sleep 1
    if systemctl is-active --quiet mtproto-proxy; then
        echo -e "${GREEN}  ✓ MTProto перезапущен${NC}"
    else
        echo -e "${RED}  ✗ MTProto не запустился${NC}"
    fi
    
    echo -e "\n${GREEN}✅ Перезапуск завершён${NC}"
}

# --- ПУНКТ 3: Перегенерация ключей ---
do_regen_keys() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ПЕРЕГЕНЕРАЦИЯ КЛЮЧЕЙ И ССЫЛОК     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    if ! load_config; then
        echo -e "${RED}✗ Конфигурация не найдена. Сначала выполните полную установку (п.1)${NC}"
        return
    fi
    
    echo -e "${YELLOW}Старые параметры:${NC}"
    echo "  UUID: $VLESS_UUID"
    echo "  Public Key: $PUBLIC_KEY"
    echo "  SOCKS пароль: $SOCKS_PASS"
    echo "  MTProto secret: $MT_SECRET"
    
    read -rp "Сгенерировать новые ключи? (y/N): " ans
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "Отменено"; return; }
    
    generate_params
    configure_xray
    configure_mtproto
    save_config
    generate_html
    
    echo -e "\n${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ КЛЮЧИ ПЕРЕГЕНЕРИРОВАНЫ${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠️  ВАЖНО: Обновите настройки во всех клиентах!${NC}"
    echo -e "Новый HTML: ${YELLOW}$HTML_FILE${NC}"
}

# --- ПУНКТ 4: Статус ---
do_status() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           СТАТУС СЕРВИСОВ              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    echo -e "${BLUE}═══ Xray ═══${NC}"
    systemctl status xray --no-pager 2>&1 | head -15
    echo ""
    echo -e "${BLUE}═══ MTProto ═══${NC}"
    systemctl status mtproto-proxy --no-pager 2>&1 | head -15
    echo ""
    echo -e "${BLUE}═══ iptables правила ═══${NC}"
    iptables -L INPUT -n -v 2>&1 | head -20
    echo ""
    echo -e "${BLUE}═══ Открытые порты ═══${NC}"
    ss -tlnp | grep -E ":(443|10808|8888)" || echo "Ничего не слушает"
}

# --- ПУНКТ 5: Показать настройки ---
do_show_config() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ТЕКУЩИЕ НАСТРОЙКИ              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    if ! load_config; then
        echo -e "${RED}✗ Конфигурация не найдена${NC}"
        return
    fi
    
    echo -e "${BLUE}IP сервера:${NC}      $SERVER_IP"
    echo -e "${BLUE}VLESS UUID:${NC}      $VLESS_UUID"
    echo -e "${BLUE}VLESS порт:${NC}      $VLESS_PORT"
    echo -e "${BLUE}Public Key:${NC}      $PUBLIC_KEY"
    echo -e "${BLUE}Private Key:${NC}     $PRIVATE_KEY"
    echo -e "${BLUE}SOCKS логин:${NC}     $SOCKS_USER"
    echo -e "${BLUE}SOCKS пароль:${NC}    $SOCKS_PASS"
    echo -e "${BLUE}SOCKS порт:${NC}      $SOCKS_PORT"
    echo -e "${BLUE}MTProto порт:${NC}    $MT_PORT"
    echo -e "${BLUE}MTProto secret:${NC}  $MT_SECRET$MT_TAG"
    echo ""
    echo -e "${YELLOW}HTML-файл:${NC} $HTML_FILE"
}

# --- ПУНКТ 6: Удаление ---
do_uninstall() {
    echo -e "\n${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║         ПОЛНОЕ УДАЛЕНИЕ                ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}\n"
    
    read -rp "${RED}Удалить ВСЕ компоненты (Xray, MTProto, конфиги, HTML)? (y/N): ${NC}" ans
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "Отменено"; return; }
    
    echo -e "${YELLOW}→ Остановка сервисов...${NC}"
    systemctl stop xray 2>/dev/null
    systemctl stop mtproto-proxy 2>/dev/null
    systemctl disable xray 2>/dev/null
    systemctl disable mtproto-proxy 2>/dev/null
    
    echo -e "${YELLOW}→ Удаление файлов...${NC}"
    rm -rf /usr/local/etc/xray
    rm -rf "$MT_DIR"
    rm -rf "$MT_CONF"
    rm -f /etc/systemd/system/mtproto-proxy.service
    rm -f "$HTML_FILE"
    rm -f "$CONFIG_FILE"
    systemctl daemon-reload
    
    echo -e "${GREEN}✅ Всё удалено${NC}"
}

# --- Главное меню ---
menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║        EN Server Manager (Xray + MTProto)            ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        check_installed
        echo -e "${YELLOW}Выберите действие:${NC}"
        echo "  1) 🚀 Полная установка (с нуля)"
        echo "  2) 🔄 Перезапустить сервисы"
        echo "  3) 🔑 Перегенерировать ключи и обновить конфиг"
        echo "  4) 📊 Показать статус сервисов"
        echo "  5) 📋 Показать текущие настройки"
        echo "  6) 🗑️  Полное удаление"
        echo "  0) 🚪 Выход"
        echo ""
        read -rp "Введите номер: " choice
        
        case $choice in
            1) do_full_install ;;
            2) do_restart ;;
            3) do_regen_keys ;;
            4) do_status ;;
            5) do_show_config ;;
            6) do_uninstall ;;
            0) echo "Выход..."; exit 0 ;;
            *) echo -e "${RED}Неверный выбор${NC}" ;;
        esac
        
        echo ""
        read -rp "Нажмите Enter для возврата в меню..."
    done
}

menu