#!/usr/bin/env bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}Запустите от root: sudo -i${NC}"; exit 1; }

CONFIG_FILE="/root/.proxy_config"
HTML_FILE="/root/proxy_settings.html"

# --- Проверка компонентов ---
check_installed() {
    echo -e "${BLUE}=== Статус компонентов ===${NC}"
    if command -v xray &>/dev/null; then
        echo -e "  ${GREEN}✓ Xray: $(xray version 2>/dev/null | head -1)${NC}"
    else
        echo -e "  ${RED}✗ Xray не установлен${NC}"
    fi
    if command -v mtg &>/dev/null; then
        echo -e "  ${GREEN}✓ MTG (MTProto): установлен${NC}"
    else
        echo -e "  ${RED}✗ MTG не установлен${NC}"
    fi
    if systemctl is-active --quiet mtg 2>/dev/null; then
        echo -e "  ${GREEN}✓ MTProto: запущен${NC}"
    else
        echo -e "  ${YELLOW}⚠ MTProto: не запущен${NC}"
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
MT_PORT="${MT_PORT}"
TLS_DOMAIN="${TLS_DOMAIN}"
VLESS_PORT="${VLESS_PORT}"
SOCKS_PORT="${SOCKS_PORT}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
XRAY_CFG="${XRAY_CFG}"
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
    SOCKS_USER=$(openssl rand -hex 4)
    SOCKS_PASS=$(openssl rand -hex 8)
    
    # Короткий MTProto secret (32 символа: ee + 30 hex)
    MT_SECRET="ee$(openssl rand -hex 15)"
    
    MT_PORT=8888
    TLS_DOMAIN="ya.ru"  # Домен для FakeTLS
    
    VLESS_PORT=443
    SOCKS_PORT=10808

    XRAY_BIN=$(which xray 2>/dev/null || echo "/usr/local/bin/xray")
    echo -e "  Генерация x25519 ключей..."
    KEY_OUTPUT=$("$XRAY_BIN" x25519 2>&1)
    echo "$KEY_OUTPUT" | sed 's/^/    /'

    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -iE "Private" | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -iE "Public" | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')

    if [ -z "$PRIVATE_KEY" ] || [ ${#PRIVATE_KEY} -lt 30 ]; then
        PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk '/[Pp]rivate/{print $NF}' | tr -d '[:space:]')
        PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk '/[Pp]ublic/{print $NF}' | tr -d '[:space:]')
    fi

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ ${#PRIVATE_KEY} -lt 30 ]; then
        echo -e "${RED}✗ ОШИБКА: не удалось получить ключи!${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Параметры сгенерированы:${NC}"
    echo -e "  IP: $SERVER_IP"
    echo -e "  UUID: $VLESS_UUID"
    echo -e "  SOCKS: $SOCKS_USER / $SOCKS_PASS"
    echo -e "  MTProto secret: $MT_SECRET (FakeTLS → $TLS_DOMAIN)"
    echo -e "  Public Key: ${PUBLIC_KEY:0:20}..."
    return 0
}

# --- Запрос TLS домена ---
ask_tls_domain() {
    echo -e "\n${BLUE}═══ Домен для FakeTLS ═══${NC}"
    echo "  Трафик MTProto будет маскироваться под HTTPS к этому домену."
    echo "  Выберите домен, который НЕ заблокирован у вас:"
    echo "    1) ya.ru (Яндекс, рекомендуется для РФ)"
    echo "    2) google.com"
    echo "    3) microsoft.com"
    echo "    4) apple.com"
    echo "    5) github.com"
    echo "    6) Свой домен"
    read -rp "Выбор [1]: " choice
    case $choice in
        2) TLS_DOMAIN="google.com" ;;
        3) TLS_DOMAIN="microsoft.com" ;;
        4) TLS_DOMAIN="apple.com" ;;
        5) TLS_DOMAIN="github.com" ;;
        6) 
            read -rp "Введите домен: " TLS_DOMAIN
            [ -z "$TLS_DOMAIN" ] && TLS_DOMAIN="ya.ru"
            ;;
        *) TLS_DOMAIN="ya.ru" ;;
    esac
    echo -e "${GREEN}✓ Выбран домен: $TLS_DOMAIN${NC}"
}

# --- Отключение UFW ---
disable_ufw() {
    if command -v ufw &>/dev/null; then
        echo -e "${YELLOW}→ Отключение UFW...${NC}"
        ufw disable 2>/dev/null || true
        systemctl stop ufw 2>/dev/null || true
        systemctl disable ufw 2>/dev/null || true
        echo -e "${GREEN}✓ UFW отключён${NC}"
    fi
}

# --- Установка зависимостей ---
install_deps() {
    echo -e "${YELLOW}→ Установка зависимостей...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget jq openssl git iptables >/dev/null 2>&1
    echo -e "${GREEN}✓ Зависимости установлены${NC}"
}

# --- Установка Xray ---
setup_xray() {
    echo -e "${YELLOW}→ Установка/обновление Xray-core...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>&1 | tail -5

    XRAY_BIN=$(which xray 2>/dev/null || echo "/usr/local/bin/xray")
    XRAY_CFG=""
    for path in "/usr/local/etc/xray/config.json" "/etc/xray/config.json"; do
        dir=$(dirname "$path")
        if [ -d "$dir" ] || [ -f "$path" ]; then
            XRAY_CFG="$path"
            break
        fi
    done

    if [ -z "$XRAY_CFG" ]; then
        mkdir -p /usr/local/etc/xray
        XRAY_CFG="/usr/local/etc/xray/config.json"
    fi

    [ ! -d "$(dirname "$XRAY_CFG")" ] && mkdir -p "$(dirname "$XRAY_CFG")"
    chmod 755 "$(dirname "$XRAY_CFG")"

    if command -v xray &>/dev/null; then
        echo -e "${GREEN}✓ Xray установлен: $(xray version 2>/dev/null | head -1)${NC}"
    else
        echo -e "${RED}✗ ОШИБКА: Xray не установлен!${NC}"
        return 1
    fi
    return 0
}

# --- Конфигурация Xray ---
configure_xray() {
    echo -e "${YELLOW}→ Запись конфигурации Xray...${NC}"
    
    if [ -z "$VLESS_UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo -e "${RED}✗ ОШИБКА: Не все параметры сгенерированы!${NC}"
        return 1
    fi

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
          "dest": "${TLS_DOMAIN}:443",
          "serverNames": ["${TLS_DOMAIN}", "www.${TLS_DOMAIN}"],
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

    [ ! -f "$XRAY_CFG" ] && { echo -e "${RED}✗ Файл конфига не создан!${NC}"; return 1; }

    XRAY_BIN=$(which xray 2>/dev/null || echo "/usr/local/bin/xray")
    TEST_OUT=$("$XRAY_BIN" run -test -config "$XRAY_CFG" 2>&1)
    if echo "$TEST_OUT" | grep -qi "ok\|valid\|success"; then
        echo -e "${GREEN}✓ Конфиг Xray валиден${NC}"
    else
        echo -e "${YELLOW}⚠ Предупреждение:${NC}"
        echo "$TEST_OUT" | sed 's/^/    /'
    fi

    if [ -f "/etc/systemd/system/xray.service" ]; then
        sed -i "s|/usr/local/etc/xray/config.json|$XRAY_CFG|g" /etc/systemd/system/xray.service 2>/dev/null || true
        systemctl daemon-reload
    fi

    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 2

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ Xray запущен (VLESS:${VLESS_PORT}, SOCKS:${SOCKS_PORT})${NC}"
    else
        echo -e "${RED}✗ Xray не запустился!${NC}"
        journalctl -u xray -n 15 --no-pager
        return 1
    fi
    return 0
}

# --- Установка MTG (MTProto с FakeTLS) - ИСПРАВЛЕННАЯ ВЕРСИЯ ---
setup_mtg() {
    echo -e "${YELLOW}→ Установка MTG (MTProto proxy с FakeTLS)...${NC}"
    
    # Определяем архитектуру с правильными именами архивов
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)          MTG_ARCH="linux-amd64" ;;
        aarch64|arm64)   MTG_ARCH="linux-arm64v8" ;;
        armv7l)          MTG_ARCH="linux-armv7" ;;
        *)
            echo -e "${RED}✗ Неподдерживаемая архитектура: $ARCH${NC}"
            return 1
            ;;
    esac
    
    # Фиксированная стабильная версия (fallback)
    MTG_VERSION="2.1.0"
    
    # Пытаемся получить последнюю версию с GitHub (не критично)
    LATEST=$(curl -s --max-time 5 https://api.github.com/repos/9seconds/mtg/releases/latest 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' | head -1 | sed 's/^v//')
    [ -n "$LATEST" ] && MTG_VERSION="$LATEST"
    
    echo -e "  Версия: $MTG_VERSION, архитектура: $MTG_ARCH ($ARCH)"
    
    cd /tmp
    rm -rf mtg-install && mkdir mtg-install && cd mtg-install
    
    DOWNLOAD_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-${MTG_ARCH}.tar.gz"
    echo -e "  Скачивание: $DOWNLOAD_URL"
    
    if ! wget -q --timeout=30 "$DOWNLOAD_URL" -O mtg.tar.gz; then
        # Fallback: пробуем без "v" в URL
        DOWNLOAD_URL="https://github.com/9seconds/mtg/releases/download/${MTG_VERSION}/mtg-${MTG_VERSION}-${MTG_ARCH}.tar.gz"
        echo -e "  ${YELLOW}Повторная попытка: $DOWNLOAD_URL${NC}"
        if ! wget -q --timeout=30 "$DOWNLOAD_URL" -O mtg.tar.gz; then
            echo -e "${RED}✗ Не удалось скачать mtg. Проверьте доступ к GitHub.${NC}"
            return 1
        fi
    fi
    
    # Проверяем, что это действительно архив, а не HTML-ошибка
    if ! file mtg.tar.gz | grep -qi "gzip"; then
        echo -e "${RED}✗ Скачан некорректный файл (возможно, 404):${NC}"
        file mtg.tar.gz
        head -c 200 mtg.tar.gz
        return 1
    fi
    
    # Распаковка
    if ! tar -xzf mtg.tar.gz; then
        echo -e "${RED}✗ Ошибка распаковки архива${NC}"
        return 1
    fi
    
    # Ищем бинарник (он может быть в подпапке или в корне)
    MTG_BIN=$(find . -name "mtg" -type f | head -1)
    if [ -z "$MTG_BIN" ]; then
        echo -e "${RED}✗ Бинарник mtg не найден в архиве!${NC}"
        ls -la
        return 1
    fi
    
    # Проверка формата файла ДО установки
    FILE_INFO=$(file "$MTG_BIN")
    echo -e "  Файл: $FILE_INFO"
    if ! echo "$FILE_INFO" | grep -qiE "ELF.*executable"; then
        echo -e "${RED}✗ Файл не является ELF-бинарником!${NC}"
        return 1
    fi
    
    # Установка
    chmod +x "$MTG_BIN"
    mv "$MTG_BIN" /usr/local/bin/mtg
    
    # Очистка
    cd /tmp && rm -rf mtg-install
    
    # Финальная проверка
    if ! command -v mtg &>/dev/null; then
        echo -e "${RED}✗ mtg не установлен в PATH${NC}"
        return 1
    fi
    
    MTG_VER_OUTPUT=$(mtg --version 2>&1 || echo "unknown")
    echo -e "${GREEN}✓ MTG успешно установлен${NC}"
    echo -e "  Версия: $MTG_VER_OUTPUT"
    echo -e "  Путь: $(which mtg)"
    return 0
}

# --- Настройка сервиса MTG ---
configure_mtg() {
    echo -e "${YELLOW}→ Настройка systemd сервиса MTProto (FakeTLS → ${TLS_DOMAIN})...${NC}"
    
    cat > /etc/systemd/system/mtg.service <<MT
[Unit]
Description=MTProto Proxy (MTG with FakeTLS)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run --bind 0.0.0.0:${MT_PORT} --tls=${TLS_DOMAIN} ${MT_SECRET}
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
MT
    
    systemctl daemon-reload
    systemctl enable mtg >/dev/null 2>&1
    systemctl restart mtg
    sleep 1
    
    if systemctl is-active --quiet mtg; then
        echo -e "${GREEN}✓ MTProto запущен на порту ${MT_PORT} (FakeTLS → ${TLS_DOMAIN})${NC}"
    else
        echo -e "${RED}✗ MTProto не запустился!${NC}"
        journalctl -u mtg -n 15 --no-pager
        return 1
    fi
    return 0
}

# --- Файрвол ---
setup_fw() {
    echo -e "${YELLOW}→ Настройка iptables...${NC}"
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    SSH_PORT=${SSH_PORT:-22}

    iptables -C INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p tcp --dport $SSH_PORT -j ACCEPT
    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -i lo -j ACCEPT
    iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT

    for port in $VLESS_PORT $SOCKS_PORT $MT_PORT; do
        iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    iptables -C INPUT -p udp --dport $SOCKS_PORT -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p udp --dport $SOCKS_PORT -j ACCEPT

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    if ! dpkg -l | grep -q iptables-persistent; then
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        apt-get install -y iptables-persistent >/dev/null 2>&1
    fi
    echo -e "${GREEN}✓ iptables настроен (SSH:${SSH_PORT}, VLESS:${VLESS_PORT}, SOCKS:${SOCKS_PORT}, MT:${MT_PORT})${NC}"
}

# --- Генерация HTML ---
generate_html() {
    echo -e "${YELLOW}→ Генерация HTML-файла...${NC}"
    VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=reality&sni=${TLS_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=&type=tcp&flow=xtls-rprx-vision#EN_VLESS"
    SOCKS_LINK="socks5://${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${SOCKS_PORT}#EN_SOCKS5"
    MT_LINK="tg://proxy?server=${SERVER_IP}&port=${MT_PORT}&secret=${MT_SECRET}"

    cat > "$HTML_FILE" <<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>EN Server - Настройки</title>
<style>
body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:20px;background:#f8f9fa}
.card{background:#fff;border-radius:12px;padding:25px;margin:15px 0;box-shadow:0 4px 6px rgba(0,0,0,.1)}
h1{text-align:center;color:#1a202c}
h2{color:#3182ce;border-bottom:2px solid #3182ce;padding-bottom:8px}
.row{display:flex;align-items:center;gap:8px;margin:8px 0;flex-wrap:wrap}
.box{background:#edf2f7;padding:12px;border-radius:6px;word-break:break-all;font-family:monospace;font-size:14px;flex:1;min-width:0}
.lbl{font-weight:600;color:#2d3748;display:block;margin-top:12px}
.btn{background:#3182ce;color:#fff;border:none;padding:6px 12px;border-radius:4px;cursor:pointer;white-space:nowrap;flex-shrink:0;text-decoration:none;font-size:14px}
.btn:hover{background:#2c5282}
.btn.ok{background:#38a169}
.btn.tg{background:#0088cc}
.btn.tg:hover{background:#006699}
.info{background:#ebf8ff;border-left:4px solid #3182ce;padding:15px;margin:20px 0}
.fake-tls{background:#f0fff4;border-left:4px solid #38a169;padding:10px;margin:10px 0;font-size:13px}
</style>
</head>
<body>
<h1>🌐 EN Server - Настройки прокси</h1>
<div class="info"><strong>IP:</strong> ${SERVER_IP}<br><strong>Дата:</strong> $(date '+%Y-%m-%d %H:%M:%S')</div>

<div class="card">
<h2>🔐 VLESS + REALITY</h2>
<div class="fake-tls">🛡️ <strong>REALITY</strong>: трафик маскируется под HTTPS к <code>${TLS_DOMAIN}</code></div>
<span class="lbl">UUID:</span>
<div class="row"><div class="box">${VLESS_UUID}</div><button class="btn" onclick="cp(this,'${VLESS_UUID}')">📋 Копировать</button></div>
<span class="lbl">Public Key:</span>
<div class="row"><div class="box">${PUBLIC_KEY}</div><button class="btn" onclick="cp(this,'${PUBLIC_KEY}')">📋 Копировать</button></div>
<span class="lbl">SNI (домен):</span>
<div class="row"><div class="box">${TLS_DOMAIN}</div><button class="btn" onclick="cp(this,'${TLS_DOMAIN}')">📋 Копировать</button></div>
<span class="lbl">Порт:</span>
<div class="row"><div class="box">${VLESS_PORT}</div><button class="btn" onclick="cp(this,'${VLESS_PORT}')">📋 Копировать</button></div>
<span class="lbl">Ссылка для импорта:</span>
<div class="row"><div class="box">${VLESS_LINK}</div><button class="btn" onclick="cp(this,'${VLESS_LINK}')">📋 Копировать</button></div>
</div>

<div class="card">
<h2>🧦 SOCKS5</h2>
<span class="lbl">Логин:</span>
<div class="row"><div class="box">${SOCKS_USER}</div><button class="btn" onclick="cp(this,'${SOCKS_USER}')">📋 Копировать</button></div>
<span class="lbl">Пароль:</span>
<div class="row"><div class="box">${SOCKS_PASS}</div><button class="btn" onclick="cp(this,'${SOCKS_PASS}')">📋 Копировать</button></div>
<span class="lbl">Порт:</span>
<div class="row"><div class="box">${SOCKS_PORT}</div><button class="btn" onclick="cp(this,'${SOCKS_PORT}')">📋 Копировать</button></div>
<span class="lbl">Ссылка для импорта:</span>
<div class="row"><div class="box">${SOCKS_LINK}</div><button class="btn" onclick="cp(this,'${SOCKS_LINK}')">📋 Копировать</button></div>
</div>

<div class="card">
<h2>✈️ MTProto FakeTLS</h2>
<div class="fake-tls">🛡️ <strong>FakeTLS</strong>: трафик маскируется под браузер, обращающийся к <code>${TLS_DOMAIN}</code></div>
<span class="lbl">Secret:</span>
<div class="row"><div class="box">${MT_SECRET}</div><button class="btn" onclick="cp(this,'${MT_SECRET}')">📋 Копировать</button></div>
<span class="lbl">Порт:</span>
<div class="row"><div class="box">${MT_PORT}</div><button class="btn" onclick="cp(this,'${MT_PORT}')">📋 Копировать</button></div>
<span class="lbl">IP сервера:</span>
<div class="row"><div class="box">${SERVER_IP}</div><button class="btn" onclick="cp(this,'${SERVER_IP}')">📋 Копировать</button></div>
<span class="lbl">Ссылка для Telegram:</span>
<div class="row"><div class="box">${MT_LINK}</div><button class="btn" onclick="cp(this,'${MT_LINK}')">📋 Копировать</button></div>
<div style="margin-top:15px;text-align:center">
<a href="${MT_LINK}" class="btn tg">➕ Добавить в Telegram</a>
</div>
</div>

<script>
function cp(b,t){
  navigator.clipboard.writeText(t).then(function(){
    var old=b.innerHTML;
    b.innerHTML='✓ Скопировано';
    b.classList.add('ok');
    setTimeout(function(){b.innerHTML=old;b.classList.remove('ok')},1500);
  }).catch(function(){
    var ta=document.createElement('textarea');
    ta.value=t;document.body.appendChild(ta);
    ta.select();document.execCommand('copy');
    document.body.removeChild(ta);
    b.innerHTML='✓ Скопировано';
    b.classList.add('ok');
    setTimeout(function(){b.innerHTML='📋 Копировать';b.classList.remove('ok')},1500);
  });
}
</script>
</body></html>
HTML
    echo -e "${GREEN}✓ HTML сгенерирован: $HTML_FILE${NC}"
}

# --- ПУНКТ 1: Полная установка ---
do_full_install() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ПОЛНАЯ УСТАНОВКА EN СЕРВЕРА       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${YELLOW}⚠ Обнаружена существующая конфигурация:${NC}"
        echo -e "  IP:          $SERVER_IP"
        echo -e "  UUID:        $VLESS_UUID"
        echo -e "  Public Key:  ${PUBLIC_KEY:0:30}..."
        echo -e "  SOCKS:       $SOCKS_USER / $SOCKS_PASS"
        echo -e "  MT secret:   $MT_SECRET"
        echo -e "  TLS домен:   $TLS_DOMAIN"
        echo -e "  Порты:       VLESS=$VLESS_PORT, SOCKS=$SOCKS_PORT, MT=$MT_PORT"
        echo ""
        echo -e "${YELLOW}Что сделать?${NC}"
        echo "  1) 🔄 Использовать СОХРАНЁННЫЕ данные"
        echo "  2) 🆕 Сгенерировать НОВЫЕ данные"
        echo "  0) Отмена"
        read -rp "Ваш выбор [1]: " mode
        mode=${mode:-1}
        
        case $mode in
            2)
                read -rp "Вы уверены? (y/N): " ans
                [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "Отменено"; return; }
                ;;
            1)
                disable_ufw
                install_deps
                setup_xray || return
                if [ -z "$VLESS_UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
                    generate_params || return
                fi
                configure_xray || return
                setup_mtg || return
                configure_mtg
                setup_fw
                save_config
                generate_html
                echo -e "\n${GREEN}✅ КОНФИГУРАЦИИ ПЕРЕЗАПИСАНЫ С ТЕМИ ЖЕ КЛЮЧАМИ${NC}"
                return
                ;;
            *) echo "Отменено"; return ;;
        esac
    else
        read -rp "Начать полную установку? (y/N): " ans
        [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "Отменено"; return; }
    fi
    
    disable_ufw
    install_deps
    ask_tls_domain
    setup_xray || return
    generate_params || return
    configure_xray || return
    setup_mtg || return
    configure_mtg
    setup_fw
    save_config
    generate_html
    
    echo -e "\n${GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО${NC}"
    echo -e "HTML-файл: ${YELLOW}$HTML_FILE${NC}"
}

# --- ПУНКТ 2: Перезапуск ---
do_restart() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ПЕРЕЗАПУСК СЕРВИСОВ            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    [ ! -f "$CONFIG_FILE" ] && { echo -e "${RED}✗ Конфиг не найден!${NC}"; return; }
    source "$CONFIG_FILE"
    
    systemctl restart xray 2>&1
    sleep 2
    systemctl is-active --quiet xray && echo -e "${GREEN}✓ Xray перезапущен${NC}" || echo -e "${RED}✗ Xray не запустился${NC}"
    
    systemctl restart mtg 2>&1
    sleep 1
    systemctl is-active --quiet mtg && echo -e "${GREEN}✓ MTProto перезапущен${NC}" || echo -e "${RED}✗ MTProto не запустился${NC}"
    
    echo -e "\n${GREEN}✅ Перезапуск завершён${NC}"
}

# --- ПУНКТ 3: Перегенерация ключей ---
do_regen_keys() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ПЕРЕГЕНЕРАЦИЯ КЛЮЧЕЙ              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    if ! load_config; then
        echo -e "${RED}✗ Конфиг не найден${NC}"
        return
    fi
    
    echo -e "${YELLOW}Старые параметры:${NC}"
    echo "  UUID: $VLESS_UUID"
    echo "  Public Key: $PUBLIC_KEY"
    echo "  MT secret: $MT_SECRET"
    
    read -rp "Сгенерировать новые ключи? (y/N): " ans
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "Отменено"; return; }
    
    generate_params || return
    configure_xray || return
    configure_mtg
    save_config
    generate_html
    
    echo -e "\n${GREEN}✅ КЛЮЧИ ПЕРЕГЕНЕРИРОВАНЫ${NC}"
    echo -e "${YELLOW}⚠️ Обновите настройки во всех клиентах!${NC}"
}

# --- ПУНКТ 4: Сменить TLS домен ---
do_change_tls() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ИЗМЕНИТЬ TLS ДОМЕН                ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    if ! load_config; then
        echo -e "${RED}✗ Конфиг не найден${NC}"
        return
    fi
    
    echo -e "${YELLOW}Текущий домен: $TLS_DOMAIN${NC}"
    ask_tls_domain
    
    configure_xray || return
    configure_mtg
    save_config
    generate_html
    
    echo -e "\n${GREEN}✅ TLS домен изменён на: $TLS_DOMAIN${NC}"
}

# --- ПУНКТ 5: Статус ---
do_status() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           СТАТУС СЕРВИСОВ              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    echo -e "${BLUE}═══ Xray ═══${NC}"
    systemctl status xray --no-pager 2>&1 | head -10
    echo -e "\n${BLUE}═══ MTProto (mtg) ═══${NC}"
    systemctl status mtg --no-pager 2>&1 | head -10
    echo -e "\n${BLUE}═══ Открытые порты ═══${NC}"
    ss -tlnp | grep -E ":(443|10808|8888)" || echo "Ничего не слушает"
}

# --- ПУНКТ 6: Показать настройки ---
do_show_config() {
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ТЕКУЩИЕ НАСТРОЙКИ              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    
    if ! load_config; then
        echo -e "${RED}✗ Конфиг не найден${NC}"
        return
    fi
    
    echo -e "${BLUE}IP сервера:${NC}      $SERVER_IP"
    echo -e "${BLUE}TLS домен:${NC}       $TLS_DOMAIN"
    echo -e "${BLUE}VLESS UUID:${NC}      $VLESS_UUID"
    echo -e "${BLUE}Public Key:${NC}      $PUBLIC_KEY"
    echo -e "${BLUE}SOCKS:${NC}           $SOCKS_USER / $SOCKS_PASS"
    echo -e "${BLUE}MTProto secret:${NC}  $MT_SECRET"
    echo -e "${BLUE}Порты:${NC}           VLESS=$VLESS_PORT, SOCKS=$SOCKS_PORT, MT=$MT_PORT"
    echo -e "\n${YELLOW}HTML-файл:${NC} $HTML_FILE"
}

# --- ПУНКТ 7: Удаление ---
do_uninstall() {
    echo -e "\n${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║         ПОЛНОЕ УДАЛЕНИЕ                ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}\n"
    
    read -rp "${RED}Удалить ВСЕ компоненты? (y/N): ${NC}" ans
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "Отменено"; return; }
    
    systemctl stop xray mtg 2>/dev/null
    systemctl disable xray mtg 2>/dev/null
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/bin/mtg
    rm -f /etc/systemd/system/mtg.service
    rm -f "$HTML_FILE" "$CONFIG_FILE"
    systemctl daemon-reload
    
    echo -e "${GREEN}✅ Всё удалено${NC}"
}

# --- Главное меню ---
menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║   EN Server Manager (Xray + MTProto FakeTLS)         ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        check_installed
        echo -e "${YELLOW}Выберите действие:${NC}"
        echo "  1) 🚀 Полная установка"
        echo "  2) 🔄 Перезапустить сервисы"
        echo "  3) 🔑 Перегенерировать ключи"
        echo "  4) 🌐 Изменить TLS домен (FakeTLS маскировка)"
        echo "  5) 📊 Показать статус сервисов"
        echo "  6) 📋 Показать текущие настройки"
        echo "  7) 🗑️  Полное удаление"
        echo "  0) 🚪 Выход"
        echo ""
        read -rp "Введите номер: " choice
        
        case $choice in
            1) do_full_install ;;
            2) do_restart ;;
            3) do_regen_keys ;;
            4) do_change_tls ;;
            5) do_status ;;
            6) do_show_config ;;
            7) do_uninstall ;;
            0) echo "Выход..."; exit 0 ;;
            *) echo -e "${RED}Неверный выбор${NC}" ;;
        esac
        
        echo ""
        read -rp "Нажмите Enter для возврата в меню..."
    done
}

menu