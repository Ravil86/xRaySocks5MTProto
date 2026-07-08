#!/usr/bin/env bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}Запустите от root: sudo -i${NC}"; exit 1; }

CONFIG_FILE="/root/.relay_config"
HTML_FILE="/root/relay_info.html"

# === ФУНКЦИИ ПРОВЕРКИ И ОСВОБОЖДЕНИЯ ПОРТОВ ===

# Проверка кто занял порт
check_port() {
 local port=$1
 local result=$(ss -tulnp 2>/dev/null | grep ":${port} " | head -1)
 if [ -n "$result" ]; then
   echo "$result"
   return 0
 fi
 return 1
}

# Освобождение порта
free_port() {
 local port=$1
 local reason=$2
 
 echo -e "${YELLOW}→ Освобождение порта $port ($reason)...${NC}"
 
 # Находим PID процесса
 local pid_info=$(ss -tulnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1)
 
 if [ -z "$pid_info" ]; then
   # Пробуем через lsof
   pid_info=$(lsof -ti :${port} 2>/dev/null | head -1)
 fi
 
 if [ -n "$pid_info" ]; then
   local proc_name=$(ps -p $pid_info -o comm= 2>/dev/null)
   echo -e "  Найден процесс: $proc_name (PID: $pid_info)"
   
   # Если это nginx - не убиваем, а исправляем конфиг
   if [ "$proc_name" = "nginx" ]; then
     echo -e "  ${YELLOW}Это nginx - исправляем конфиг...${NC}"
     fix_nginx_port_conflict $port
     return 0
   fi
   
   # Если это socat - останавливаем сервис
   if [ "$proc_name" = "socat" ]; then
     echo -e "  ${YELLOW}Это socat - останавливаем сервис...${NC}"
     systemctl stop relay-mtproto 2>/dev/null
     systemctl stop relay-vless 2>/dev/null
     systemctl stop relay-socks 2>/dev/null
     sleep 1
   fi
   
   # Если процесс всё ещё жив - убиваем
   if check_port $port >/dev/null; then
     echo -e "  ${YELLOW}Принудительно завершаем процесс $pid_info...${NC}"
     kill -9 $pid_info 2>/dev/null
     sleep 1
   fi
 fi
 
 # Проверяем результат
 if check_port $port >/dev/null; then
   echo -e "  ${RED}✗ Не удалось освободить порт $port${NC}"
   return 1
 else
   echo -e "  ${GREEN}✓ Порт $port освобождён${NC}"
   return 0
 fi
}

# Исправление конфликтов nginx
fix_nginx_port_conflict() {
 local port=$1
 
 echo -e "${YELLOW}→ Поиск и исправление конфигов nginx с портом $port...${NC}"
 
 # Находим все конфиги с этим портом
 local configs=$(grep -rl "listen.*:${port}\|listen.*${port}" /etc/nginx/ 2>/dev/null)
 
 if [ -z "$configs" ]; then
   echo -e "  ${YELLOW}Конфиги не найдены${NC}"
   return 0
 fi
 
 for config in $configs; do
   echo -e "  Обрабатываю: $config"
   
   # Создаём backup
   cp "$config" "${config}.backup.$(date +%s)" 2>/dev/null
   
   # Удаляем строки с listen на этот порт
   sed -i "/listen.*:${port}/d" "$config"
   sed -i "/listen.*${port}/d" "$config"
   
   echo -e "  ${GREEN}✓ Удалены строки с listen $port${NC}"
 done
 
 # Проверяем конфиг nginx
 if nginx -t 2>&1 | grep -q "successful"; then
   echo -e "  ${GREEN}✓ Конфиг nginx корректен${NC}"
   systemctl reload nginx 2>/dev/null
   sleep 1
 else
   echo -e "  ${RED}✗ Ошибка в конфиге nginx${NC}"
   nginx -t 2>&1
   return 1
 fi
 
 # Проверяем что порт освободился
 sleep 1
 if check_port $port >/dev/null; then
   echo -e "  ${RED}✗ Порт $port всё ещё занят${NC}"
   return 1
 else
   echo -e "  ${GREEN}✓ Порт $port освобождён${NC}"
   return 0
 fi
}

# Проверка всех необходимых портов
check_all_ports() {
 local mode=$1
 local mt_port=$2
 
 echo -e "\n${BLUE}═══ Проверка портов ═══${NC}"
 
 local ports_to_check=(80)
 
 if [ "$mode" = "domain" ]; then
   ports_to_check+=(443)
 fi
 
 # Порт MTProto проверяем отдельно
 if ! check_port $mt_port >/dev/null; then
   echo -e "  ${GREEN}✓ Порт $mt_port свободен${NC}"
 else
   echo -e "  ${YELLOW}⚠ Порт $mt_port занят${NC}"
   free_port $mt_port "MTProto relay" || return 1
 fi
 
 for port in "${ports_to_check[@]}"; do
   if check_port $port >/dev/null; then
     local occupier=$(ss -tulnp 2>/dev/null | grep ":${port} " | grep -oP 'users:\(\("\K[^"]+' | head -1)
     echo -e "  ${YELLOW}⚠ Порт $port занят процессом: $occupier${NC}"
     
     # Если это nginx и порт 443 в режиме domain - оставляем
     if [ "$port" = "443" ] && [ "$mode" = "domain" ] && [ "$occupier" = "nginx" ]; then
       echo -e "  ${GREEN}✓ Nginx на 443 - это нормально для режима domain${NC}"
       continue
     fi
     
     # Пытаемся освободить
     free_port $port "необходим для установки" || return 1
   else
     echo -e "  ${GREEN}✓ Порт $port свободен${NC}"
   fi
 done
 
 return 0
}

# === ОСНОВНЫЕ ФУНКЦИИ УСТАНОВКИ ===

disable_ufw() {
 command -v ufw &>/dev/null && { ufw disable 2>/dev/null || true; systemctl stop ufw 2>/dev/null || true; systemctl disable ufw 2>/dev/null || true; echo -e "${GREEN}✓ UFW отключён${NC}"; }
}

ask_mode() {
 echo -e "\n${BLUE}═══ Режим работы RU сервера ═══${NC}"
 echo " A) 🌐 MTProto на порту 443 (без своего домена)"
 echo "    Простой relay: Клиент → RU:443 → EN:443"
 echo ""
 echo " B) 🏠 Свой домен + MTProto на 8443 с FakeTLS"
 echo "    Nginx HTTPS на 443, MTProto relay на 8443"
 echo "    Клиент → домен:8443 → EN:8443 (с FakeTLS)"
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

ask_en_params() {
 echo -e "\n${BLUE}═══ Параметры EN сервера ═══${NC}"

 local NEW_WORK_MODE="$WORK_MODE"
 local NEW_RU_MT_PORT="$RU_MT_PORT"

 if [ -f "$CONFIG_FILE" ]; then
   source "$CONFIG_FILE"
   echo -e "${YELLOW}Найдена предыдущая конфигурация:${NC}"
   echo " EN IP: $EN_SERVER_IP"
   echo " Режим (старый): $WORK_MODE"
   echo " MTProto RU (старый): $RU_MT_PORT → EN: $EN_MT_PORT"
   echo ""
   echo -e "${YELLOW}Новый режим: $NEW_WORK_MODE, новый MT порт: $NEW_RU_MT_PORT${NC}"
   read -rp "Использовать сохранённые параметры EN сервера? (Y/n): " use
   if [ "$use" != "n" ] && [ "$use" != "N" ]; then
     WORK_MODE="$NEW_WORK_MODE"
     RU_MT_PORT="$NEW_RU_MT_PORT"
     if [ "$WORK_MODE" = "domain" ]; then
       EN_MT_PORT=8443
     else
       EN_MT_PORT=443
     fi
     echo -e "${GREEN}✓ Используем сохранённые данные (порты обновлены)${NC}"
     return 0
   fi
   WORK_MODE="$NEW_WORK_MODE"
   RU_MT_PORT="$NEW_RU_MT_PORT"
 fi

 read -rp "IP EN сервера: " EN_SERVER_IP
 [ -z "$EN_SERVER_IP" ] && { echo -e "${RED}IP не может быть пустым${NC}"; return 1; }

 if [ "$WORK_MODE" = "domain" ]; then
   read -rp "Порт MTProto на EN [8443]: " input; EN_MT_PORT=${input:-8443}
 else
   read -rp "Порт MTProto на EN [443]: " input; EN_MT_PORT=${input:-443}
 fi

 echo -e "${GREEN}✓ Параметры установлены:${NC}"
 echo -e " Режим: $WORK_MODE"
 echo -e " MTProto RU порт: $RU_MT_PORT"
 echo -e " MTProto EN порт: $EN_MT_PORT"
}

ask_domain() {
 [ "$WORK_MODE" != "domain" ] && return 0

 echo -e "\n${BLUE}═══ Домен для HTTPS сайта ═══${NC}"
 echo " Nginx будет обслуживать HTTPS-сайт на этом домене."
 echo " MTProto будет работать на порту 8443 с FakeTLS."

 if [ -n "$PROXY_DOMAIN" ]; then
   echo -e "${YELLOW}Текущий домен: $PROXY_DOMAIN${NC}"
   read -rp "Изменить домен? (y/N): " change
   [ "$change" != "y" ] && [ "$change" != "Y" ] && return 0
 fi

 read -rp "Полный домен (например mysite.com): " PROXY_DOMAIN
 [ -z "$PROXY_DOMAIN" ] && { echo -e "${RED}Домен не может быть пустым${NC}"; return 1; }
 echo -e "${GREEN}✓ Домен: $PROXY_DOMAIN${NC}"
}

install_deps() {
 echo -e "\n${YELLOW}→ Установка зависимостей...${NC}"
 export DEBIAN_FRONTEND=noninteractive
 apt-get update -y >/dev/null 2>&1
 apt-get install -y iptables iptables-persistent socat curl openssl dnsutils lsof >/dev/null 2>&1
 if [ "$WORK_MODE" = "domain" ]; then
   apt-get install -y nginx certbot python3-certbot-nginx >/dev/null 2>&1
 fi
 echo -e "${GREEN}✓ Зависимости установлены${NC}"
}

enable_forwarding() {
 echo -e "\n${YELLOW}→ Включение IP forwarding...${NC}"
 grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || {
   echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
   sysctl -p >/dev/null 2>&1
 }
 echo -e "${GREEN}✓ IP forwarding включён${NC}"
}

setup_nginx() {
 [ "$WORK_MODE" != "domain" ] && return 0

 echo -e "\n${YELLOW}→ Настройка Nginx (HTTPS сайт на 443)...${NC}"

 # Останавливаем nginx перед изменением конфига
 systemctl stop nginx 2>/dev/null

 # Удаляем все старые конфиги с listen 8443
 echo -e "${YELLOW}→ Очистка старых конфигов nginx...${NC}"
 find /etc/nginx/ -name "*.conf" -o -name "default" | while read config; do
   if grep -q "listen.*8443" "$config" 2>/dev/null; then
     echo -e "  Удаляю listen 8443 из: $config"
     cp "$config" "${config}.backup.$(date +%s)" 2>/dev/null
     sed -i '/listen.*8443/d' "$config"
   fi
 done

 # Создаём новый конфиг ТОЛЬКО с 443
 cat > /etc/nginx/sites-available/default <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name ${PROXY_DOMAIN};

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

 mkdir -p /var/www/html
 cat > /var/www/html/index.html <<HTML
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body>
<h1>Welcome to ${PROXY_DOMAIN}</h1>
<p>This site works. MTProto is available on port 8443.</p>
</body>
</html>
HTML

 # Удаляем все лишние конфиги
 rm -f /etc/nginx/sites-enabled/* 2>/dev/null
 ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

 echo " Проверка конфига..."
 if ! nginx -t 2>&1; then
   echo -e "${RED}✗ Ошибка конфига Nginx${NC}"
   nginx -t 2>&1
   return 1
 fi

 systemctl enable nginx >/dev/null 2>&1
 systemctl start nginx
 sleep 2

 if systemctl is-active --quiet nginx; then
   echo -e "${GREEN}✓ Nginx настроен (HTTPS сайт на 443)${NC}"
   echo -e " HTTPS сайт: https://${PROXY_DOMAIN}"
   echo -e " MTProto: ${PROXY_DOMAIN}:8443"
 else
   echo -e "${RED}✗ Nginx не запустился${NC}"
   journalctl -u nginx -n 15 --no-pager
   return 1
 fi
 return 0
}

setup_ssl() {
 [ "$WORK_MODE" != "domain" ] && return 0

 echo -e "\n${YELLOW}→ Получение SSL сертификата для $PROXY_DOMAIN...${NC}"

 # Проверяем есть ли уже сертификат
 if [ -d "/etc/letsencrypt/live/$PROXY_DOMAIN" ]; then
   echo -e "${GREEN}✓ Сертификат уже существует${NC}"
   return 0
 fi

 systemctl stop nginx

 certbot certonly --standalone -d $PROXY_DOMAIN \
   --non-interactive --agree-tos \
   --email admin@${PROXY_DOMAIN} 2>&1 | tail -5

 if [ ! -d "/etc/letsencrypt/live/$PROXY_DOMAIN" ]; then
   echo -e "${RED}✗ Не удалось получить сертификат${NC}"
   systemctl start nginx
   return 1
 fi

 echo -e "${GREEN}✓ SSL сертификат получен${NC}"

 systemctl start nginx
 sleep 1

 if systemctl is-active --quiet nginx; then
   echo -e "${GREEN}✓ Nginx запущен с SSL${NC}"
 else
   echo -e "${RED}✗ Nginx не запустился${NC}"
   return 1
 fi

 echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'" | crontab -
 echo -e "${GREEN}✓ Автообновление сертификата настроено${NC}"
 return 0
}

setup_iptables() {
 echo -e "\n${YELLOW}→ Настройка iptables...${NC}"

 SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
 SSH_PORT=${SSH_PORT:-22}

 iptables -C INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport $SSH_PORT -j ACCEPT
 iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i lo -j ACCEPT
 iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT

 iptables -C INPUT -p tcp --dport $RU_MT_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $RU_MT_PORT -j ACCEPT

 if [ "$WORK_MODE" = "domain" ]; then
   iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
   iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 443 -j ACCEPT
 fi

 iptables -t nat -F 2>/dev/null
 iptables -t nat -A PREROUTING -p tcp --dport $RU_MT_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_MT_PORT}
 iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_MT_PORT} -j MASQUERADE

 mkdir -p /etc/iptables
 iptables-save > /etc/iptables/rules.v4 2>/dev/null

 echo -e "${GREEN}✓ iptables настроен${NC}"
 echo -e " MT: $RU_MT_PORT → $EN_SERVER_IP:$EN_MT_PORT"
}

setup_socat() {
 echo -e "\n${YELLOW}→ Создание systemd сервисов socat...${NC}"

 # Останавливаем старые сервисы
 systemctl stop relay-mtproto 2>/dev/null
 rm -f /etc/systemd/system/relay-mtproto.service
 systemctl daemon-reload

 # Проверяем что порт свободен
 if check_port $RU_MT_PORT >/dev/null; then
   echo -e "${YELLOW}⚠ Порт $RU_MT_PORT всё ещё занят, пытаемся освободить...${NC}"
   free_port $RU_MT_PORT "socat relay" || {
     echo -e "${RED}✗ Не удалось освободить порт $RU_MT_PORT${NC}"
     return 1
   }
 fi

 cat > /etc/systemd/system/relay-mtproto.service <<EOF
[Unit]
Description=Socat relay for MTProto ($RU_MT_PORT → $EN_SERVER_IP:$EN_MT_PORT)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/socat TCP-LISTEN:${RU_MT_PORT},reuseaddr,fork TCP:${EN_SERVER_IP}:${EN_MT_PORT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

 systemctl daemon-reload
 systemctl enable relay-mtproto >/dev/null 2>&1
 systemctl start relay-mtproto
 sleep 3

 if systemctl is-active --quiet relay-mtproto; then
   echo -e "${GREEN}✓ socat настроен ($RU_MT_PORT → $EN_SERVER_IP:$EN_MT_PORT)${NC}"
 else
   echo -e "${RED}✗ socat не запустился${NC}"
   journalctl -u relay-mtproto -n 10 --no-pager
   return 1
 fi
}

generate_html() {
 echo -e "\n${YELLOW}→ Генерация HTML-файла с QR-кодом...${NC}"
 RU_IPV4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
 RU_IPV6=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
 [ -z "$RU_IPV4" ] && RU_IPV4="unknown"

 echo -e "\n${BLUE}═══ Параметры MTProto для Telegram ═══${NC}"
 read -rp "MTProto secret EN сервера: " MT_SECRET
 [ -z "$MT_SECRET" ] && MT_SECRET="ВСТАВЬТЕ_SECRET_ИЗ_EN_СЕРВЕРА"

 if [ "$WORK_MODE" = "domain" ]; then
   MT_SERVER="$PROXY_DOMAIN"
   MT_PORT_DISPLAY="8443"
 else
   MT_SERVER="$RU_IPV4"
   MT_PORT_DISPLAY="$RU_MT_PORT"
 fi

 MT_LINK="tg://proxy?server=${MT_SERVER}&port=${MT_PORT_DISPLAY}&secret=${MT_SECRET}"

 cat > "$HTML_FILE" <<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>RU Relay - Настройки</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
body{font-family:Arial,sans-serif;max-width:800px;margin:20px auto;padding:20px;background:#f5f5f5}
h1{color:#333;border-bottom:3px solid #0088cc;padding-bottom:10px}
.info-box{background:#fff;padding:20px;border-radius:8px;margin:20px 0;box-shadow:0 2px 4px rgba(0,0,0,0.1)}
.label{font-weight:bold;color:#555;display:inline-block;width:150px}
.value{font-family:monospace;background:#f9f9f9;padding:5px 10px;border-radius:4px;word-break:break-all}
.qr-container{text-align:center;margin:20px 0}
#qrcode{display:inline-block;padding:20px;background:#fff;border-radius:8px}
.btn{display:inline-block;background:#0088cc;color:#fff;padding:12px 24px;text-decoration:none;border-radius:6px;margin:10px 5px;font-weight:bold}
.btn:hover{background:#006699}
.copy-btn{background:#28a745;cursor:pointer;border:none;padding:8px 16px;border-radius:4px;color:#fff;margin-left:10px}
.copy-btn:hover{background:#218838}
table{width:100%;border-collapse:collapse;margin:20px 0}
th,td{padding:12px;text-align:left;border-bottom:1px solid #ddd}
th{background:#0088cc;color:#fff}
.warning{background:#fff3cd;border-left:4px solid #ffc107;padding:15px;margin:20px 0;border-radius:4px}
</style>
</head>
<body>
<h1>🇷🇺 RU Relay Server</h1>

<div class="info-box">
<p><span class="label">Режим:</span> <span class="value">${WORK_MODE}</span></p>
$([ "$WORK_MODE" = "domain" ] && echo "<p><span class='label'>Домен:</span> <span class='value'>${PROXY_DOMAIN}</span></p>")
<p><span class="label">RU IPv4:</span> <span class="value">${RU_IPV4}</span></p>
$([ -n "$RU_IPV6" ] && echo "<p><span class='label'>RU IPv6:</span> <span class='value'>${RU_IPV6}</span></p>")
<p><span class="label">EN IP:</span> <span class="value">${EN_SERVER_IP}</span></p>
<p><span class="label">Настроено:</span> <span class="value">$(date '+%Y-%m-%d %H:%M:%S')</span></p>
</div>

<h2>✈️ MTProto Proxy для Telegram</h2>

<div class="info-box">
<p><span class="label">Сервер:</span> <span class="value">${MT_SERVER}</span></p>
<p><span class="label">Порт:</span> <span class="value">${MT_PORT_DISPLAY}</span></p>
<p><span class="label">Secret:</span> <span class="value">${MT_SECRET}</span></p>

<div class="qr-container">
<div id="qrcode"></div>
<p><strong>Отсканируйте QR-код для добавления в Telegram</strong></p>
</div>

<a href="${MT_LINK}" class="btn">➕ Добавить в Telegram</a>

<p><strong>Или используйте ссылку:</strong></p>
<div class="value" id="mt-link">${MT_LINK}</div>
<button class="copy-btn" onclick="copyToClipboard('mt-link')">📋 Копировать ссылку</button>
</div>

<h2>⚙️ Маршрутизация</h2>

<div class="info-box">
<table>
<tr><th>Протокол</th><th>RU Порт</th><th>→ EN</th></tr>
<tr><td><strong>MTProto</strong></td><td>${RU_MT_PORT}</td><td>${EN_SERVER_IP}:${EN_MT_PORT}</td></tr>
$([ "$WORK_MODE" = "domain" ] && echo "<tr><td>HTTPS сайт</td><td>443</td><td>локально (Nginx)</td></tr>")
</table>
</div>

<div class="warning">
<h3>⚠️ Важно</h3>
$([ "$WORK_MODE" = "domain" ] && echo "<p><strong>MTProto:</strong> подключайтесь к <strong>${PROXY_DOMAIN}:8443</strong> (FakeTLS)</p><p><strong>HTTPS сайт:</strong> доступен на <strong>https://${PROXY_DOMAIN}</strong></p>" || echo "<p><strong>MTProto:</strong> подключайтесь к <strong>${RU_IPV4}:${RU_MT_PORT}</strong></p>")
</div>

<script>
new QRCode(document.getElementById("qrcode"), {
    text: "${MT_LINK}",
    width: 256,
    height: 256,
    colorDark: "#000000",
    colorLight: "#ffffff",
    correctLevel: QRCode.CorrectLevel.H
});

function copyToClipboard(elementId) {
    var text = document.getElementById(elementId).innerText;
    navigator.clipboard.writeText(text).then(() => alert('Скопировано: ' + text));
}
</script>

</body>
</html>
HTML

 echo -e "${GREEN}✓ HTML с QR-кодом сгенерирован: $HTML_FILE${NC}"
}

save_config() {
 cat > "$CONFIG_FILE" <<EOF
WORK_MODE="$WORK_MODE"
EN_SERVER_IP="$EN_SERVER_IP"
EN_MT_PORT="$EN_MT_PORT"
RU_MT_PORT="$RU_MT_PORT"
PROXY_DOMAIN="$PROXY_DOMAIN"
EOF
 echo -e "${GREEN}✓ Конфиг сохранён: $CONFIG_FILE${NC}"
}

full_install() {
 ask_mode || return 1
 ask_en_params || return 1
 ask_domain || return 1
 
 # ПРОВЕРКА ПОРТОВ ПЕРЕД УСТАНОВКОЙ
 check_all_ports "$WORK_MODE" "$RU_MT_PORT" || {
   echo -e "${RED}✗ Не удалось освободить необходимые порты${NC}"
   return 1
 }
 
 disable_ufw
 install_deps
 enable_forwarding
 
 if [ "$WORK_MODE" = "domain" ]; then
   setup_nginx || return 1
   setup_ssl || return 1
 fi
 
 setup_iptables
 setup_socat || return 1
 generate_html
 save_config
 
 # ФИНАЛЬНАЯ ПРОВЕРКА
 echo -e "\n${BLUE}═══ Финальная проверка ═══${NC}"
 echo -e "Порты:"
 ss -tuln | grep -E ":${RU_MT_PORT} |:443 |:80 " | awk '{print "  " $4 " - " $6}'
 
 echo -e "\n${GREEN}═══ ✅ Установка завершена ═══${NC}"
 echo -e "HTML-файл: ${YELLOW}$HTML_FILE${NC}"
 echo -e "Конфиг: ${YELLOW}$CONFIG_FILE${NC}"
}

menu() {
 while true; do
   echo -e "\n${BLUE}═══════════════════════════════════${NC}"
   echo -e "${BLUE}  RU Relay Server Management${NC}"
   echo -e "${BLUE}═══════════════════════════════════${NC}"
   echo " 1) 🚀 Полная установка"
   echo " 2) 🔄 Перезапуск сервисов"
   echo " 3) 📊 Статус сервисов"
   echo " 4) 🔍 Проверка портов"
   echo " 5) 📋 Показать настройки"
   echo " 6) 🗑️  Удалить relay"
   echo " 0) 🚪 Выход"
   echo -e "${BLUE}═══════════════════════════════════${NC}"
   read -rp "Выбор: " choice

   case $choice in
     1) full_install ;;
     2)
       [ ! -f "$CONFIG_FILE" ] && { echo -e "${RED}Конфиг не найден${NC}"; continue; }
       source "$CONFIG_FILE"
       systemctl restart relay-mtproto
       [ "$WORK_MODE" = "domain" ] && systemctl restart nginx
       echo -e "${GREEN}✓ Сервисы перезапущены${NC}"
       ;;
     3)
       echo -e "\n${BLUE}═══ Сервисы ═══${NC}"
       systemctl is-active --quiet relay-mtproto 2>/dev/null && echo -e "${GREEN} ✓ relay-mtproto${NC}" || echo -e "${RED} ✗ relay-mtproto${NC}"
       [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" && [ "$WORK_MODE" = "domain" ] && { systemctl is-active --quiet nginx 2>/dev/null && echo -e "${GREEN} ✓ nginx${NC}" || echo -e "${RED} ✗ nginx${NC}"; }
       ;;
     4)
       echo -e "\n${BLUE}═══ Проверка портов ═══${NC}"
       [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
       for port in 80 443 ${RU_MT_PORT:-8443}; do
         if check_port $port >/dev/null; then
           local info=$(ss -tulnp 2>/dev/null | grep ":${port} " | head -1)
           echo -e "  ${YELLOW}Порт $port занят:${NC} $info"
         else
           echo -e "  ${GREEN}Порт $port свободен${NC}"
         fi
       done
       ;;
     5)
       [ -f "$CONFIG_FILE" ] && { source "$CONFIG_FILE"; echo -e "${BLUE}Режим:${NC} $WORK_MODE"; echo -e "${BLUE}EN сервер:${NC} $EN_SERVER_IP"; echo -e "${BLUE}MTProto RU:${NC} $RU_MT_PORT"; echo -e "${BLUE}MTProto EN:${NC} $EN_MT_PORT"; [ -n "$PROXY_DOMAIN" ] && echo -e "${BLUE}Домен:${NC} $PROXY_DOMAIN"; echo -e "${YELLOW}HTML:${NC} $HTML_FILE"; } || echo -e "${RED}✗ Конфиг не найден${NC}"
       ;;
     6)
       read -rp "${RED}Удалить relay? (y/N): ${NC}" ans
       if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
         systemctl stop relay-mtproto nginx 2>/dev/null
         systemctl disable relay-mtproto nginx 2>/dev/null
         rm -f /etc/systemd/system/relay-*.service "$HTML_FILE" "$CONFIG_FILE"
         systemctl daemon-reload
         iptables -t nat -F 2>/dev/null
         mkdir -p /etc/iptables
         iptables-save > /etc/iptables/rules.v4 2>/dev/null
         echo -e "${GREEN}✅ Relay удалён${NC}"
       fi
       ;;
     0) echo "Выход..."; exit 0 ;;
     *) echo -e "${RED}Неверный выбор${NC}" ;;
   esac
   echo ""; read -rp "Нажмите Enter для возврата в меню..."
 done
}

menu