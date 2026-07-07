#!/usr/bin/env bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}Запустите от root: sudo -i${NC}"; exit 1; }

CONFIG_FILE="/root/.relay_config"
HTML_FILE="/root/relay_info.html"

disable_ufw() {
    command -v ufw &>/dev/null && { ufw disable 2>/dev/null || true; systemctl stop ufw 2>/dev/null || true; systemctl disable ufw 2>/dev/null || true; echo -e "${GREEN}✓ UFW отключён${NC}"; }
}

# --- Запрос параметров EN сервера ---
ask_en_params() {
    echo -e "\n${BLUE}═══ Параметры EN сервера ═══${NC}"
    
    # ВАЖНО: сохраняем RU_MT_PORT из ask_mode()
    local SAVED_RU_MT_PORT=$RU_MT_PORT
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${YELLOW}Найдена предыдущая конфигурация:${NC}"
        echo "  EN IP: $EN_SERVER_IP"
        echo "  Режим: $WORK_MODE"
        echo "  MTProto RU: $RU_MT_PORT → EN: $EN_MT_PORT"
        echo ""
        read -rp "Использовать эти параметры? (Y/n): " use
        if [ "$use" != "n" ] && [ "$use" != "N" ]; then
            # Восстанавливаем RU_MT_PORT из режима, а не из конфига
            RU_MT_PORT=$SAVED_RU_MT_PORT
            # EN_MT_PORT должен совпадать с режимом
            if [ "$WORK_MODE" = "domain" ]; then
                EN_MT_PORT=8443
            else
                EN_MT_PORT=443
            fi
            echo -e "${GREEN}✓ Используем сохранённые данные (порты обновлены под режим)${NC}"
            return 0
        fi
    fi
    
    read -rp "IP EN сервера: " EN_SERVER_IP
    [ -z "$EN_SERVER_IP" ] && { echo -e "${RED}IP не может быть пустым${NC}"; return 1; }
    
    read -rp "Порт VLESS на EN [8443]: " input; EN_VLESS_PORT=${input:-8443}
    read -rp "Порт SOCKS на EN [10808]: " input; EN_SOCKS_PORT=${input:-10808}
    
    # Порт MTProto на EN зависит от режима
    if [ "$WORK_MODE" = "domain" ]; then
        read -rp "Порт MTProto на EN [8443]: " input; EN_MT_PORT=${input:-8443}
    else
        read -rp "Порт MTProto на EN [443]: " input; EN_MT_PORT=${input:-443}
    fi
    
    RU_VLESS_PORT=8443
    RU_SOCKS_PORT=10808
    # RU_MT_PORT уже установлен в ask_mode() — НЕ перезаписываем!
    
    echo -e "${GREEN}✓ Параметры установлены:${NC}"
    echo -e "  MTProto RU порт: $RU_MT_PORT"
    echo -e "  MTProto EN порт: $EN_MT_PORT"
}

# --- Запрос домена ---
ask_domain() {
    [ "$WORK_MODE" != "domain" ] && return 0  # Пропускаем для режима A
    
    echo -e "\n${BLUE}═══ Домен для HTTPS сайта ═══${NC}"
    echo "  Nginx будет обслуживать HTTPS-сайт на этом домене."
    echo "  MTProto будет работать на порту 8443."
    
    if [ -n "$PROXY_DOMAIN" ]; then
        echo -e "${YELLOW}Текущий домен: $PROXY_DOMAIN${NC}"
        read -rp "Изменить домен? (y/N): " change
        [ "$change" != "y" ] && [ "$change" != "Y" ] && return 0
    fi
    
    read -rp "Полный домен (например mysite.com): " PROXY_DOMAIN
    [ -z "$PROXY_DOMAIN" ] && { echo -e "${RED}Домен не может быть пустым${NC}"; return 1; }
    echo -e "${GREEN}✓ Домен: $PROXY_DOMAIN${NC}"
}

# --- Выбор типа IP ---
ask_ip_type() {
    echo -e "\n${BLUE}═══ Тип IP подключения ═══${NC}"
    echo "  1) Только IPv4 (рекомендуется)"
    echo "  2) Только IPv6"
    echo "  3) Оба (IPv4 + IPv6)"
    read -rp "Выбор [1]: " ip_choice
    case $ip_choice in
        2) IP_TYPE="ipv6" ;;
        3) IP_TYPE="both" ;;
        *) IP_TYPE="ipv4" ;;
    esac
    echo -e "${GREEN}✓ Выбран тип: $IP_TYPE${NC}"
}

# --- Запрос режима работы ---
ask_mode() {
    echo -e "\n${BLUE}═══ Режим работы RU сервера ═══${NC}"
    echo "  A) 🌐 MTProto на порту 443 (без своего домена)"
    echo "     Используется iptables/socat для проксирования"
    echo "     Клиент подключается к RU_IP:443"
    echo ""
    echo "  B) 🏠 Свой домен + Nginx на 443 + MTProto на 8443"
    echo "     Nginx обслуживает HTTPS-сайт на 443"
    echo "     MTProto работает на порту 8443"
    echo "     Клиент подключается к domain.com:8443"
    read -rp "Выбор [A]: " mode
    case $mode in
        B|b)
            WORK_MODE="domain"
            RU_MT_PORT=8443
            ;;
        *)
            WORK_MODE="simple"
            RU_MT_PORT=443
            ;;
    esac
    echo -e "${GREEN}✓ Режим: $WORK_MODE, MT порт на RU: $RU_MT_PORT${NC}"
}

# --- Выбор метода relay ---
ask_relay_method() {
    echo -e "\n${BLUE}═══ Метод relay ═══${NC}"
    echo "  1) Nginx stream (SNI routing, рекомендуется)"
    echo "  2) iptables (прозрачный DNAT)"
    echo "  3) socat (стабильнее)"
    read -rp "Выбор [1]: " m
    case $m in
        2) RELAY_METHOD="iptables" ;;
        3) RELAY_METHOD="socat" ;;
        *) RELAY_METHOD="nginx" ;;
    esac
    echo -e "${GREEN}✓ Выбран метод: $RELAY_METHOD${NC}"
}

# --- Установка зависимостей ---
install_deps() {
    echo -e "\n${YELLOW}→ Установка зависимостей...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y nginx certbot python3-certbot-nginx iptables iptables-persistent socat curl openssl dnsutils >/dev/null 2>&1
    echo -e "${GREEN}✓ Зависимости установлены${NC}"
}

# --- Проверка DNS ---
check_dns() {
    echo -e "\n${YELLOW}→ Проверка DNS записей для $PROXY_DOMAIN...${NC}"
    
    local ru_ipv4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 ipinfo.io/ip 2>/dev/null || ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    local ru_ipv6=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null || ip -6 addr show scope global | grep -oP '(?<=inet6\s)[\da-f:]+' | head -1)
    
    echo -e "  RU IPv4: $ru_ipv4"
    [ -n "$ru_ipv6" ] && echo -e "  RU IPv6: $ru_ipv6"
    
    # Проверяем A запись
    local dns_ipv4=$(dig +short $PROXY_DOMAIN A 2>/dev/null | tail -1)
    if [ -n "$dns_ipv4" ]; then
        echo -e "  DNS A: $dns_ipv4"
        if [ "$dns_ipv4" = "$ru_ipv4" ]; then
            echo -e "  ${GREEN}✓ A запись корректна${NC}"
        else
            echo -e "  ${YELLOW}⚠ A запись указывает на $dns_ipv4, а не на $ru_ipv4${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠ A запись не найдена${NC}"
    fi
    
    # Проверяем AAAA запись
    local dns_ipv6=$(dig +short $PROXY_DOMAIN AAAA 2>/dev/null | tail -1)
    if [ -n "$dns_ipv6" ]; then
        echo -e "  DNS AAAA: $dns_ipv6"
        if [ -n "$ru_ipv6" ] && [ "$dns_ipv6" = "$ru_ipv6" ]; then
            echo -e "  ${GREEN}✓ AAAA запись корректна${NC}"
        else
            echo -e "  ${YELLOW}⚠ AAAA запись не совпадает${NC}"
        fi
    else
        [ "$IP_TYPE" = "ipv6" ] || [ "$IP_TYPE" = "both" ] && echo -e "  ${YELLOW}⚠ AAAA запись не найдена${NC}"
    fi
    
    echo ""
    read -rp "Продолжить? DNS должен указывать на этот сервер (y/N): " ans
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "Отменено"; return 1; }
    return 0
}

# --- Настройка Nginx с stream модулем ---
setup_nginx() {
    [ "$WORK_MODE" != "domain" ] && return 0  # Пропускаем для режима A
    
    echo -e "\n${YELLOW}→ Настройка Nginx (HTTPS сайт на 443)...${NC}"
    
    apt-get install -y nginx certbot python3-certbot-nginx >/dev/null 2>&1
    
    # HTTP конфиг для Nginx (обычный HTTPS сайт, НЕ stream)
    cat > /etc/nginx/sites-available/default <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${PROXY_DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${PROXY_DOMAIN};
    
    # SSL сертификаты (будут получены позже)
    ssl_certificate /etc/letsencrypt/live/${PROXY_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PROXY_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    root /var/www/html;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX
    
    # Создаём простую страницу
    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<HTML
<!DOCTYPE html>
<html><head><title>Welcome</title></head>
<body><h1>Welcome to ${PROXY_DOMAIN}</h1></body></html>
HTML
    
    nginx -t 2>&1 || { echo -e "${RED}✗ Ошибка конфига Nginx${NC}"; return 1; }
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx
    echo -e "${GREEN}✓ Nginx настроен (HTTPS на 443)${NC}"
    return 0
}

# --- Получение SSL сертификата ---
setup_ssl() {
    [ "$WORK_MODE" != "domain" ] && return 0
    
    echo -e "\n${YELLOW}→ Получение SSL сертификата для $PROXY_DOMAIN...${NC}"
    
    systemctl stop nginx
    certbot certonly --standalone -d $PROXY_DOMAIN --non-interactive --agree-tos --email admin@$PROXY_DOMAIN 2>&1 | tail -5
    
    if [ ! -d "/etc/letsencrypt/live/$PROXY_DOMAIN" ]; then
        echo -e "${RED}✗ Не удалось получить сертификат${NC}"
        systemctl start nginx
        return 1
    fi
    
    systemctl start nginx
    echo "0 3 * * * certbot renew --quiet && systemctl reload nginx" | crontab -
    echo -e "${GREEN}✓ SSL сертификат получен и настроено автообновление${NC}"
    return 0
}

# --- Настройка iptables ---
setup_iptables() {
    echo -e "\n${YELLOW}→ Настройка iptables (DNAT)...${NC}"
    echo -e "  MTProto: $RU_MT_PORT → $EN_SERVER_IP:$EN_MT_PORT"
    
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || { echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf; sysctl -p >/dev/null 2>&1; }
    
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    SSH_PORT=${SSH_PORT:-22}
    
    iptables -C INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport $SSH_PORT -j ACCEPT
    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i lo -j ACCEPT
    iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    for port in $RU_VLESS_PORT $RU_SOCKS_PORT $RU_MT_PORT; do
        iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    iptables -C INPUT -p udp --dport $RU_SOCKS_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport $RU_SOCKS_PORT -j ACCEPT
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    
    iptables -t nat -F 2>/dev/null
    
    # VLESS
    iptables -t nat -A PREROUTING -p tcp --dport $RU_VLESS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_VLESS_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_VLESS_PORT} -j MASQUERADE
    
    # SOCKS5
    iptables -t nat -A PREROUTING -p tcp --dport $RU_SOCKS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_SOCKS_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_SOCKS_PORT} -j MASQUERADE
    iptables -t nat -A PREROUTING -p udp --dport $RU_SOCKS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_SOCKS_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p udp --dport ${EN_SOCKS_PORT} -j MASQUERADE
    
    # MTProto — ВАЖНО: используем $RU_MT_PORT и $EN_MT_PORT
    iptables -t nat -A PREROUTING -p tcp --dport $RU_MT_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_MT_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_MT_PORT} -j MASQUERADE
    
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    dpkg -l | grep -q iptables-persistent || { echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections; apt-get install -y iptables-persistent >/dev/null 2>&1; }
    echo -e "${GREEN}✓ iptables настроен (MT: $RU_MT_PORT → $EN_SERVER_IP:$EN_MT_PORT)${NC}"
}

# --- Настройка socat ---
setup_socat() {
    echo -e "\n${YELLOW}→ Создание systemd сервисов socat...${NC}"
    for proto in vless socks mtproto; do
        case $proto in vless) RP=$RU_VLESS_PORT; EP=$EN_VLESS_PORT ;; socks) RP=$RU_SOCKS_PORT; EP=$EN_SOCKS_PORT ;; mtproto) RP=$RU_MT_PORT; EP=$EN_MT_PORT ;; esac
        
        # MTProto через socat только если не Nginx
        [ "$proto" = "mtproto" ] && [ "$RELAY_METHOD" = "nginx" ] && continue
        
        cat > /etc/systemd/system/relay-${proto}.service <<SV
[Unit]
Description=${proto^^} Relay to EN
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${RP},reuseaddr,fork TCP:${EN_SERVER_IP}:${EP}
Restart=always
[Install]
WantedBy=multi-user.target
SV
    done
    systemctl daemon-reload
    systemctl enable relay-vless relay-socks >/dev/null 2>&1
    [ "$RELAY_METHOD" != "nginx" ] && systemctl enable relay-mtproto >/dev/null 2>&1
    systemctl restart relay-vless relay-socks
    [ "$RELAY_METHOD" != "nginx" ] && systemctl restart relay-mtproto
    sleep 1
    echo -e "${GREEN}✓ socat настроен${NC}"
}

# --- Генерация HTML ---
generate_html() {
    echo -e "\n${YELLOW}→ Генерация HTML-файла...${NC}"
    RU_IPV4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    RU_IPV6=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
    [ -z "$RU_IPV4" ] && RU_IPV4="unknown"
    
    echo -e "\n${BLUE}═══ Параметры MTProto для Telegram ═══${NC}"
    read -rp "MTProto secret EN сервера: " MT_SECRET
    [ -z "$MT_SECRET" ] && MT_SECRET="ВСТАВЬТЕ_SECRET_ИЗ_EN_СЕРВЕРА"
    
    # Определяем сервер и порт для ссылки
    if [ "$WORK_MODE" = "domain" ]; then
        MT_SERVER="$PROXY_DOMAIN"
        MT_PORT_DISPLAY="$RU_MT_PORT"
    else
        MT_SERVER="$RU_IPV4"
        MT_PORT_DISPLAY="$RU_MT_PORT"
    fi
    
    MT_LINK="tg://proxy?server=${MT_SERVER}&port=${MT_PORT_DISPLAY}&secret=${MT_SECRET}"
    
    # Определяем IP для подключения
    case $IP_TYPE in
        ipv4) CONNECT_IP="$RU_IPV4" ;;
        ipv6) CONNECT_IP="$RU_IPV6" ;;
        *) CONNECT_IP="$RU_IPV4" ;;
    esac
    
    cat > "$HTML_FILE" <<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>RU Relay - Настройки</title>
<style>
body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:20px;background:#f8f9fa}
.card{background:#fff;padding:20px;border-radius:10px;margin:15px 0;box-shadow:0 2px 8px rgba(0,0,0,.1)}
h1{text-align:center;color:#1a202c}
h2{color:#3182ce;border-bottom:2px solid #3182ce;padding-bottom:8px}
table{width:100%;border-collapse:collapse;margin:15px 0}
th,td{padding:10px;text-align:left;border-bottom:1px solid #e2e8f0}
th{background:#3182ce;color:#fff}
.row{display:flex;align-items:center;gap:8px;margin:8px 0;flex-wrap:wrap}
.box{background:#edf2f7;padding:12px;border-radius:6px;word-break:break-all;font-family:monospace;font-size:14px;flex:1;min-width:0}
.lbl{font-weight:600;color:#2d3748;display:block;margin-top:12px}
.btn{background:#3182ce;color:#fff;border:none;padding:6px 12px;border-radius:4px;cursor:pointer;white-space:nowrap;flex-shrink:0;text-decoration:none;font-size:14px;display:inline-block}
.btn:hover{background:#2c5282}
.btn.ok{background:#38a169}
.btn.tg{background:#0088cc;font-size:18px;padding:15px 30px}
.btn.tg:hover{background:#006699}
.warn{background:#fffbeb;border-left:4px solid #d69e2e;padding:15px;margin:20px 0}
.ok-box{background:#d4edda;border-left:4px solid #28a745;padding:15px;margin:20px 0}
.tg-section{background:#e3f2fd;border:3px solid #0088cc;border-radius:15px;padding:30px;margin:20px 0;text-align:center}
.tg-section h2{color:#0088cc;border:none;font-size:24px}
.domain-highlight{background:#fff3cd;border:2px solid #ffc107;border-radius:8px;padding:15px;margin:15px 0;font-size:16px}
</style>
</head>
<body>
<h1>🇷🇺 RU Relay Server</h1>
<div class="ok-box">
<strong>Режим:</strong> ${WORK_MODE}<br>
$([ "$WORK_MODE" = "domain" ] && echo "<strong>Домен:</strong> ${PROXY_DOMAIN}<br>")
<strong>RU IPv4:</strong> ${RU_IPV4}<br>
$([ -n "$RU_IPV6" ] && echo "<strong>RU IPv6:</strong> ${RU_IPV6}<br>")
<strong>EN IP:</strong> ${EN_SERVER_IP}<br>
<strong>Настроено:</strong> $(date '+%Y-%m-%d %H:%M:%S')
</div>

<div class="tg-section">
<h2>✈️ MTProto Proxy</h2>
<div class="domain-highlight">
🌐 <strong>${MT_SERVER}:${MT_PORT_DISPLAY}</strong><br>
<span style="font-size:14px;color:#666">$([ "$WORK_MODE" = "domain" ] && echo "Маскируется под HTTPS к вашему домену" || echo "Маскируется под HTTPS (FakeTLS)")</span>
</div>
<p style="font-size:18px;margin:20px 0">Нажмите кнопку, чтобы добавить прокси в Telegram:</p>
<a href="${MT_LINK}" class="btn tg">➕ Добавить в Telegram</a>
<p style="margin-top:20px;font-size:14px;color:#666">
Ссылка:<br><code>${MT_LINK}</code>
</p>
</div>

<div class="card">
<h2>⚙️ Маршрутизация</h2>
<table>
<tr><th>Протокол</th><th>RU Порт</th><th>→ EN</th><th>Метод</th></tr>
<tr><td><strong>MTProto</strong></td><td><strong>${RU_MT_PORT}</strong></td><td>${EN_SERVER_IP}:${EN_MT_PORT}</td><td>$([ "$WORK_MODE" = "domain" ] && echo "iptables" || echo "iptables/socat")</td></tr>
<tr><td>VLESS</td><td>${RU_VLESS_PORT}</td><td>${EN_SERVER_IP}:${EN_VLESS_PORT}</td><td>iptables/socat</td></tr>
<tr><td>SOCKS5</td><td>${RU_SOCKS_PORT}</td><td>${EN_SERVER_IP}:${EN_SOCKS_PORT}</td><td>iptables/socat</td></tr>
$([ "$WORK_MODE" = "domain" ] && echo "<tr><td>HTTPS сайт</td><td>443</td><td>локально</td><td>Nginx</td></tr>")
</table>
</div>

<div class="card">
<h2>📋 Данные для подключения</h2>
<span class="lbl">Сервер для MTProto:</span>
<div class="row"><div class="box">${MT_SERVER}</div><button class="btn" onclick="cp(this,'${MT_SERVER}')">📋 Копировать</button></div>

<span class="lbl">Порт MTProto:</span>
<div class="row"><div class="box">${MT_PORT_DISPLAY}</div><button class="btn" onclick="cp(this,'${MT_PORT_DISPLAY}')">📋 Копировать</button></div>

<span class="lbl">Secret:</span>
<div class="row"><div class="box">${MT_SECRET}</div><button class="btn" onclick="cp(this,'${MT_SECRET}')">📋 Копировать</button></div>

<span class="lbl">Ссылка для Telegram:</span>
<div class="row"><div class="box">${MT_LINK}</div><button class="btn" onclick="cp(this,'${MT_LINK}')">📋 Копировать</button></div>
</div>

<div class="warn">
<h3>⚠️ Важно</h3>
$([ "$WORK_MODE" = "domain" ] && echo "<p><strong>MTProto:</strong> подключайтесь к <strong>${PROXY_DOMAIN}:${RU_MT_PORT}</strong></p><p><strong>HTTPS сайт:</strong> доступен на <strong>https://${PROXY_DOMAIN}</strong> (порт 443)</p>" || echo "<p><strong>MTProto:</strong> подключайтесь к <strong>${RU_IPV4}:${RU_MT_PORT}</strong></p>")
</div>

<script>
function cp(b,t){
  navigator.clipboard.writeText(t).then(function(){
    var old=b.innerHTML;b.innerHTML='✓ Скопировано';b.classList.add('ok');
    setTimeout(function(){b.innerHTML=old;b.classList.remove('ok')},1500);
  }).catch(function(){
    var ta=document.createElement('textarea');ta.value=t;document.body.appendChild(ta);
    ta.select();document.execCommand('copy');document.body.removeChild(ta);
    b.innerHTML='✓ Скопировано';b.classList.add('ok');
    setTimeout(function(){b.innerHTML='📋 Копировать';b.classList.remove('ok')},1500);
  });
}
</script>
</body></html>
HTML
    echo -e "${GREEN}✓ HTML сгенерирован: $HTML_FILE${NC}"
}

# --- Сохранение конфига ---
save_config() {
    cat > "$CONFIG_FILE" <<CONF
EN_SERVER_IP="${EN_SERVER_IP}"
EN_VLESS_PORT="${EN_VLESS_PORT}"
EN_SOCKS_PORT="${EN_SOCKS_PORT}"
EN_MT_PORT="${EN_MT_PORT}"
RU_VLESS_PORT="${RU_VLESS_PORT}"
RU_SOCKS_PORT="${RU_SOCKS_PORT}"
RU_MT_PORT="${RU_MT_PORT}"
RELAY_METHOD="${RELAY_METHOD}"
PROXY_DOMAIN="${PROXY_DOMAIN}"
IP_TYPE="${IP_TYPE}"
CONF
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}✓ Конфигурация сохранена в $CONFIG_FILE${NC}"
}

# --- Главное меню ---
menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║              RU Relay Manager                         ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
            echo -e "${GREEN}✓ Конфиг: ${EN_SERVER_IP} | режим: ${WORK_MODE} | MT порт: ${RU_MT_PORT}${NC}"
        else
            echo -e "${YELLOW}⚠ Конфигурация не найдена — выполните п.1${NC}"
        fi
        echo ""
        echo -e "${YELLOW}Выберите действие:${NC}"
        echo "  1) 🚀 Полная настройка relay"
        echo "  2) 🔄 Перезапустить сервисы"
        echo "  3) ✏️  Изменить параметры"
        echo "  4) 📊 Показать статус"
        echo "  5) 📋 Показать настройки"
        echo "  6) 🗑️  Удалить relay"
        echo "  0) 🚪 Выход"
        echo ""
        read -rp "Введите номер: " choice
        case $choice in
            1)
            disable_ufw
            ask_mode              # ← ПЕРВЫМ! Устанавливает WORK_MODE и RU_MT_PORT
            ask_en_params || { read -rp "Enter..."; continue; }   # ← НЕ перезаписывает RU_MT_PORT
            ask_domain || { read -rp "Enter..."; continue; }
            ask_ip_type
            ask_relay_method
            [ "$WORK_MODE" = "domain" ] && check_dns || true
            install_deps
            setup_iptables
            [ "$RELAY_METHOD" = "socat" ] || [ "$RELAY_METHOD" = "both" ] && setup_socat
            [ "$WORK_MODE" = "domain" ] && { setup_nginx; setup_ssl; }
            save_config
            generate_html
            echo -e "\n${GREEN}✅ НАСТРОЙКА ЗАВЕРШЕНА${NC}"
            echo -e "HTML: ${YELLOW}$HTML_FILE${NC}"
            echo -e "MTProto: ${YELLOW}$RU_MT_PORT → $EN_SERVER_IP:$EN_MT_PORT${NC}"
            ;;
            # ... остальные пункты без изменений
            0) echo "Выход..."; exit 0 ;;
            *) echo -e "${RED}Неверный выбор${NC}" ;;
        esac
        echo ""; read -rp "Нажмите Enter для возврата в меню..."
    done
}

menu