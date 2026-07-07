#!/usr/bin/env bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}Запустите от root: sudo -i${NC}"; exit 1; }

CONFIG_FILE="/root/.relay_config"
HTML_FILE="/root/relay_info.html"

disable_ufw() {
    if command -v ufw &>/dev/null; then
        echo -e "${YELLOW}→ Отключение UFW...${NC}"
        ufw disable 2>/dev/null || true
        systemctl stop ufw 2>/dev/null || true
        systemctl disable ufw 2>/dev/null || true
        echo -e "${GREEN}✓ UFW отключён${NC}"
    fi
}

ask_en_params() {
    echo -e "\n${BLUE}═══ Параметры EN сервера ═══${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${YELLOW}Найдена предыдущая конфигурация:${NC}"
        echo "  EN IP: $EN_SERVER_IP"
        echo "  VLESS: $RU_VLESS_PORT → $EN_SERVER_IP:$EN_VLESS_PORT"
        echo "  SOCKS: $RU_SOCKS_PORT → $EN_SERVER_IP:$EN_SOCKS_PORT"
        echo "  MTProto: $RU_MT_PORT → $EN_SERVER_IP:$EN_MT_PORT"
        echo "  Метод: $RELAY_METHOD"
        echo ""
        read -rp "Использовать эти параметры? (Y/n): " use
        [ "$use" != "n" ] && [ "$use" != "N" ] && return 0
    fi
    
    read -rp "IP EN сервера: " EN_SERVER_IP
    [ -z "$EN_SERVER_IP" ] && { echo -e "${RED}IP не может быть пустым${NC}"; return 1; }
    
    read -rp "Порт VLESS на EN [443]: " input; EN_VLESS_PORT=${input:-443}
    read -rp "Порт SOCKS на EN [10808]: " input; EN_SOCKS_PORT=${input:-10808}
    read -rp "Порт MTProto на EN [8888]: " input; EN_MT_PORT=${input:-8888}
    
    RU_VLESS_PORT=443
    RU_SOCKS_PORT=10808
    RU_MT_PORT=8888
}

ask_relay_method() {
    echo -e "\n${BLUE}═══ Метод relay ═══${NC}"
    echo "  1) iptables (прозрачный, быстрее)"
    echo "  2) socat (стабильнее, виден в процессах)"
    echo "  3) Оба метода (резервирование)"
    read -rp "Выбор [1]: " m
    case $m in
        2) RELAY_METHOD="socat" ;;
        3) RELAY_METHOD="both" ;;
        *) RELAY_METHOD="iptables" ;;
    esac
    echo -e "${GREEN}✓ Выбран метод: $RELAY_METHOD${NC}"
}

install_deps() {
    echo -e "\n${YELLOW}→ Установка зависимостей...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y iptables iptables-persistent socat curl openssl >/dev/null 2>&1
    echo -e "${GREEN}✓ Зависимости установлены${NC}"
}

setup_iptables() {
    echo -e "\n${YELLOW}→ Настройка iptables (DNAT)...${NC}"
    
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    SSH_PORT=${SSH_PORT:-22}
    
    iptables -C INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p tcp --dport $SSH_PORT -j ACCEPT
    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -i lo -j ACCEPT
    iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    for port in $RU_VLESS_PORT $RU_SOCKS_PORT $RU_MT_PORT; do
        iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    iptables -C INPUT -p udp --dport $RU_SOCKS_PORT -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p udp --dport $RU_SOCKS_PORT -j ACCEPT
    
    iptables -t nat -F 2>/dev/null
    
    iptables -t nat -A PREROUTING -p tcp --dport $RU_VLESS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_VLESS_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_VLESS_PORT} -j MASQUERADE
    
    iptables -t nat -A PREROUTING -p tcp --dport $RU_SOCKS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_SOCKS_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_SOCKS_PORT} -j MASQUERADE
    iptables -t nat -A PREROUTING -p udp --dport $RU_SOCKS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_SOCKS_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p udp --dport ${EN_SOCKS_PORT} -j MASQUERADE
    
    iptables -t nat -A PREROUTING -p tcp --dport $RU_MT_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_MT_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_MT_PORT} -j MASQUERADE
    
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    
    if ! dpkg -l | grep -q iptables-persistent; then
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        apt-get install -y iptables-persistent >/dev/null 2>&1
    fi
    
    echo -e "${GREEN}✓ iptables настроен (SSH:${SSH_PORT} + relay порты)${NC}"
}

setup_socat() {
    echo -e "\n${YELLOW}→ Создание systemd сервисов socat...${NC}"
    
    for proto in vless socks mtproto; do
        case $proto in
            vless)   RP=$RU_VLESS_PORT; EP=$EN_VLESS_PORT ;;
            socks)   RP=$RU_SOCKS_PORT; EP=$EN_SOCKS_PORT ;;
            mtproto) RP=$RU_MT_PORT;    EP=$EN_MT_PORT ;;
        esac
        
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
    systemctl enable relay-vless relay-socks relay-mtproto >/dev/null 2>&1
    systemctl restart relay-vless relay-socks relay-mtproto
    sleep 1
    
    local ok=0
    for s in relay-vless relay-socks relay-mtproto; do
        systemctl is-active --quiet $s && ok=$((ok+1))
    done
    echo -e "${GREEN}✓ socat настроен (запущено $ok/3 сервисов)${NC}"
}

# --- Генерация HTML с кнопкой "Добавить в Telegram" ---
generate_html() {
    echo -e "\n${YELLOW}→ Генерация HTML-файла...${NC}"
    RU_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ipinfo.io/ip)
    [ -z "$RU_IP" ] && RU_IP="unknown"
    
    # Спрашиваем параметры MTProto для кнопки в Telegram
    echo -e "\n${BLUE}═══ Параметры MTProto для Telegram ═══${NC}"
    echo "  Эти данные нужны для кнопки 'Добавить в Telegram'."
    echo "  Возьмите их из HTML-файла EN сервера."
    echo ""
    read -rp "MTProto secret EN сервера: " MT_SECRET
    [ -z "$MT_SECRET" ] && MT_SECRET="ВСТАВЬТЕ_SECRET_ИЗ_EN_СЕРВЕРА"
    
    MT_LINK="tg://proxy?server=${RU_IP}&port=${RU_MT_PORT}&secret=${MT_SECRET}"
    
    cat > "$HTML_FILE" <<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>RU Relay - Информация</title>
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
.btn.tg{background:#0088cc;font-size:16px;padding:12px 24px}
.btn.tg:hover{background:#006699}
.warn{background:#fffbeb;border-left:4px solid #d69e2e;padding:15px;margin:20px 0}
.ok-box{background:#d4edda;border-left:4px solid #28a745;padding:15px;margin:20px 0}
code{background:#edf2f7;padding:2px 6px;border-radius:3px;font-size:13px}
.tg-section{background:#e3f2fd;border:2px solid #0088cc;border-radius:10px;padding:20px;margin:20px 0;text-align:center}
.tg-section h2{color:#0088cc;border:none}
</style>
</head>
<body>
<h1>🇷🇺 RU Relay Server</h1>
<div class="ok-box"><strong>RU IP:</strong> ${RU_IP}<br><strong>EN IP:</strong> ${EN_SERVER_IP}<br><strong>Метод:</strong> ${RELAY_METHOD}<br><strong>Настроено:</strong> $(date '+%Y-%m-%d %H:%M:%S')</div>

<div class="tg-section">
<h2>✈️ MTProto Proxy через RU сервер</h2>
<p style="font-size:16px;margin:15px 0">Нажмите кнопку ниже, чтобы добавить прокси в Telegram:</p>
<a href="${MT_LINK}" class="btn tg">➕ Добавить в Telegram</a>
<p style="margin-top:15px;font-size:13px;color:#666">
Или откройте ссылку вручную:<br>
<code>${MT_LINK}</code>
</p>
</div>

<div class="card">
<h2>⚙️ Маршрутизация</h2>
<table>
<tr><th>Протокол</th><th>RU Порт</th><th>→ EN</th><th>Статус</th></tr>
<tr><td>VLESS</td><td>${RU_VLESS_PORT}</td><td>${EN_SERVER_IP}:${EN_VLESS_PORT}</td><td>✅</td></tr>
<tr><td>SOCKS5</td><td>${RU_SOCKS_PORT}</td><td>${EN_SERVER_IP}:${EN_SOCKS_PORT}</td><td>✅</td></tr>
<tr><td>MTProto</td><td>${RU_MT_PORT}</td><td>${EN_SERVER_IP}:${EN_MT_PORT}</td><td>✅</td></tr>
</table>
</div>

<div class="card">
<h2>📋 Данные для подключения</h2>
<span class="lbl">IP RU сервера (используйте в клиентах):</span>
<div class="row"><div class="box">${RU_IP}</div><button class="btn" onclick="cp(this,'${RU_IP}')">📋 Копировать</button></div>

<span class="lbl">EN сервер (куда идёт трафик):</span>
<div class="row"><div class="box">${EN_SERVER_IP}</div><button class="btn" onclick="cp(this,'${EN_SERVER_IP}')">📋 Копировать</button></div>

<span class="lbl">VLESS порт (RU → EN):</span>
<div class="row"><div class="box">${RU_VLESS_PORT} → ${EN_SERVER_IP}:${EN_VLESS_PORT}</div><button class="btn" onclick="cp(this,'${RU_VLESS_PORT}')">📋 Копировать порт</button></div>

<span class="lbl">SOCKS порт (RU → EN):</span>
<div class="row"><div class="box">${RU_SOCKS_PORT} → ${EN_SERVER_IP}:${EN_SOCKS_PORT}</div><button class="btn" onclick="cp(this,'${RU_SOCKS_PORT}')">📋 Копировать порт</button></div>

<span class="lbl">MTProto порт (RU → EN):</span>
<div class="row"><div class="box">${RU_MT_PORT} → ${EN_SERVER_IP}:${EN_MT_PORT}</div><button class="btn" onclick="cp(this,'${RU_MT_PORT}')">📋 Копировать порт</button></div>

<span class="lbl">MTProto secret:</span>
<div class="row"><div class="box">${MT_SECRET}</div><button class="btn" onclick="cp(this,'${MT_SECRET}')">📋 Копировать</button></div>

<span class="lbl">Ссылка для Telegram:</span>
<div class="row"><div class="box">${MT_LINK}</div><button class="btn" onclick="cp(this,'${MT_LINK}')">📋 Копировать</button></div>
</div>

<div class="warn">
<h3>⚠️ Важно для клиентов</h3>
<p>Используйте <strong>IP RU сервера (${RU_IP})</strong> вместо EN. Все остальные параметры (UUID, ключи, пароли) — из HTML-файла EN сервера.</p>
</div>

<div class="card">
<h2>🔧 Управление</h2>
<span class="lbl">Перезапуск relay:</span>
<div class="row"><div class="box">systemctl restart relay-vless relay-socks relay-mtproto</div><button class="btn" onclick="cp(this,'systemctl restart relay-vless relay-socks relay-mtproto')">📋 Копировать</button></div>

<span class="lbl">Статус сервисов:</span>
<div class="row"><div class="box">systemctl status relay-vless relay-socks relay-mtproto</div><button class="btn" onclick="cp(this,'systemctl status relay-vless relay-socks relay-mtproto')">📋 Копировать</button></div>

<span class="lbl">Просмотр iptables:</span>
<div class="row"><div class="box">iptables -t nat -L -n -v</div><button class="btn" onclick="cp(this,'iptables -t nat -L -n -v')">📋 Копировать</button></div>

<span class="lbl">Логи:</span>
<div class="row"><div class="box">journalctl -u relay-vless -f</div><button class="btn" onclick="cp(this,'journalctl -u relay-vless -f')">📋 Копировать</button></div>
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
    echo -e "${YELLOW}  Откройте его на телефоне и нажмите 'Добавить в Telegram'${NC}"
}

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
CONF
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}✓ Конфигурация сохранена в $CONFIG_FILE${NC}"
}

menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║              RU Relay Manager                         ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
            echo -e "${GREEN}✓ Конфиг загружен: ${EN_SERVER_IP} (метод: ${RELAY_METHOD})${NC}"
        else
            echo -e "${YELLOW}⚠ Конфигурация не найдена — выполните п.1${NC}"
        fi
        echo ""
        
        echo -e "${YELLOW}Выберите действие:${NC}"
        echo "  1) 🚀 Полная настройка relay"
        echo "  2) 🔄 Перезапустить relay"
        echo "  3) ✏️  Изменить EN сервер/порты"
        echo "  4) 📊 Показать статус"
        echo "  5) 📋 Показать текущие настройки"
        echo "  6) 🗑️  Удалить relay"
        echo "  0) 🚪 Выход"
        echo ""
        read -rp "Введите номер: " choice
        
        case $choice in
            1)
                disable_ufw
                ask_en_params || { read -rp "Enter..."; continue; }
                ask_relay_method
                install_deps
                case $RELAY_METHOD in
                    iptables) setup_iptables ;;
                    socat)    setup_socat ;;
                    both)     setup_iptables; setup_socat ;;
                esac
                save_config
                generate_html
                echo -e "\n${GREEN}✅ НАСТРОЙКА RU RELAY ЗАВЕРШЕНА${NC}"
                echo -e "HTML-файл: ${YELLOW}$HTML_FILE${NC}"
                ;;
            2)
                if [ ! -f "$CONFIG_FILE" ]; then
                    echo -e "${RED}✗ Конфиг не найден${NC}"
                else
                    source "$CONFIG_FILE"
                    if [ "$RELAY_METHOD" = "socat" ] || [ "$RELAY_METHOD" = "both" ]; then
                        systemctl restart relay-vless relay-socks relay-mtproto
                        sleep 1
                        for s in relay-vless relay-socks relay-mtproto; do
                            systemctl is-active --quiet $s && echo -e "${GREEN}✓ $s${NC}" || echo -e "${RED}✗ $s${NC}"
                        done
                    fi
                    [ "$RELAY_METHOD" = "iptables" ] || [ "$RELAY_METHOD" = "both" ] && setup_iptables
                    echo -e "${GREEN}✅ Перезапуск завершён${NC}"
                fi
                ;;
            3)
                ask_en_params || { read -rp "Enter..."; continue; }
                ask_relay_method
                case $RELAY_METHOD in
                    iptables) setup_iptables ;;
                    socat)    setup_socat ;;
                    both)     setup_iptables; setup_socat ;;
                esac
                save_config
                generate_html
                echo -e "${GREEN}✅ Конфигурация обновлена${NC}"
                ;;
            4)
                if [ -f "$CONFIG_FILE" ]; then
                    source "$CONFIG_FILE"
                    echo -e "${BLUE}EN сервер:${NC} $EN_SERVER_IP"
                    echo -e "${BLUE}Метод:${NC}     $RELAY_METHOD"
                fi
                echo -e "\n${BLUE}═══ iptables NAT ═══${NC}"
                iptables -t nat -L -n -v 2>&1 | grep -E "(Chain|DNAT|MASQUERADE)" || echo "Правил нет"
                echo -e "\n${BLUE}═══ socat сервисы ═══${NC}"
                for s in relay-vless relay-socks relay-mtproto; do
                    systemctl is-active --quiet $s 2>/dev/null && echo -e "${GREEN}  ✓ $s${NC}" || echo -e "${RED}  ✗ $s${NC}"
                done
                ;;
            5)
                if [ -f "$CONFIG_FILE" ]; then
                    source "$CONFIG_FILE"
                    echo -e "${BLUE}EN сервер:${NC}     $EN_SERVER_IP"
                    echo -e "${BLUE}VLESS:${NC}         $RU_VLESS_PORT → $EN_SERVER_IP:$EN_VLESS_PORT"
                    echo -e "${BLUE}SOCKS:${NC}         $RU_SOCKS_PORT → $EN_SERVER_IP:$EN_SOCKS_PORT"
                    echo -e "${BLUE}MTProto:${NC}       $RU_MT_PORT → $EN_SERVER_IP:$EN_MT_PORT"
                    echo -e "${BLUE}Метод:${NC}         $RELAY_METHOD"
                    echo -e "${YELLOW}HTML-файл:${NC} $HTML_FILE"
                else
                    echo -e "${RED}✗ Конфигурация не найдена${NC}"
                fi
                ;;
            6)
                read -rp "${RED}Удалить relay? (y/N): ${NC}" ans
                if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
                    systemctl stop relay-vless relay-socks relay-mtproto 2>/dev/null
                    systemctl disable relay-vless relay-socks relay-mtproto 2>/dev/null
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
        
        echo ""
        read -rp "Нажмите Enter для возврата в меню..."
    done
}

menu