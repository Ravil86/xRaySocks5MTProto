#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}Ошибка: Запустите от имени root (sudo -i)${NC}"; exit 1; }

CONFIG_FILE="/root/.relay_config"
HTML_FILE="/root/relay_info.html"

load_config() { [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" && return 0; return 1; }
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
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

ask_params() {
    if load_config; then
        echo -e "${YELLOW}Найдена конфигурация для EN: ${EN_SERVER_IP}${NC}"
        read -rp "Использовать текущие параметры? (y/N): " use
        [ "$use" = "y" ] && return 0
    fi
    read -rp "IP EN сервера: " EN_SERVER_IP
    read -rp "Порт VLESS EN [443]: " EN_VLESS_PORT; EN_VLESS_PORT=${EN_VLESS_PORT:-443}
    read -rp "Порт SOCKS EN [10808]: " EN_SOCKS_PORT; EN_SOCKS_PORT=${EN_SOCKS_PORT:-10808}
    read -rp "Порт MTProto EN [8888]: " EN_MT_PORT; EN_MT_PORT=${EN_MT_PORT:-8888}
    RU_VLESS_PORT=443; RU_SOCKS_PORT=10808; RU_MT_PORT=8888
}

ask_method() {
    echo -e "${YELLOW}Метод relay: 1) iptables (быстрее) 2) socat (стабильнее) 3) оба${NC}"
    read -rp "Выбор [1]: " m
    case $m in
        2) RELAY_METHOD="socat" ;;
        3) RELAY_METHOD="both" ;;
        *) RELAY_METHOD="iptables" ;;
    esac
}

install_deps() { apt-get update -y; apt-get install -y iptables iptables-persistent socat ufw; }

setup_iptables() {
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    iptables -t nat -F
    iptables -t nat -A PREROUTING -p tcp --dport $RU_VLESS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_VLESS_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_VLESS_PORT} -j MASQUERADE
    iptables -t nat -A PREROUTING -p tcp --dport $RU_SOCKS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_SOCKS_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_SOCKS_PORT} -j MASQUERADE
    iptables -t nat -A PREROUTING -p udp --dport $RU_SOCKS_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_SOCKS_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p udp --dport ${EN_SOCKS_PORT} -j MASQUERADE
    iptables -t nat -A PREROUTING -p tcp --dport $RU_MT_PORT -j DNAT --to-destination ${EN_SERVER_IP}:${EN_MT_PORT}
    iptables -t nat -A POSTROUTING -d ${EN_SERVER_IP} -p tcp --dport ${EN_MT_PORT} -j MASQUERADE
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
}

setup_socat() {
    for proto in vless socks mtproto; do
        eval "RU_PORT=\$RU_${proto^^}_PORT"
        eval "EN_PORT=\$EN_${proto^^}_PORT"
        cat > /etc/systemd/system/relay-${proto}.service <<SV
[Unit]
Description=${proto^^} Relay
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${RU_PORT},reuseaddr,fork TCP:${EN_SERVER_IP}:${EN_PORT}
Restart=always
[Install]
WantedBy=multi-user.target
SV
    done
    systemctl daemon-reload
    systemctl enable --now relay-vless relay-socks relay-mtproto
}

setup_fw() { ufw allow 443/tcp; ufw allow 10808/tcp; ufw allow 10808/udp; ufw allow 8888/tcp; ufw --force enable; }

generate_html() {
    RU_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)
    cat > "$HTML_FILE" <<HTML
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><title>RU Relay</title>
<style>body{font-family:system-ui;max-width:800px;margin:40px auto;padding:20px;background:#f8f9fa}
.card{background:#fff;padding:20px;border-radius:10px;margin:15px 0;box-shadow:0 2px 8px rgba(0,0,0,.1)}
table{width:100%;border-collapse:collapse} th,td{padding:10px;text-align:left;border-bottom:1px solid #e2e8f0}
th{background:#3182ce;color:#fff} .warn{background:#fffbeb;border-left:4px solid #d69e2e;padding:15px;margin:20px 0}</style>
</head><body><h1>🇷🇺 RU Relay Server</h1>
<p><strong>RU IP:</strong> ${RU_IP} | <strong>EN IP:</strong> ${EN_SERVER_IP} | <strong>Метод:</strong> ${RELAY_METHOD}</p>
<div class="card"><table><tr><th>Протокол</th><th>RU Порт</th><th>→ EN</th><th>Статус</th></tr>
<tr><td>VLESS</td><td>${RU_VLESS_PORT}</td><td>${EN_SERVER_IP}:${EN_VLESS_PORT}</td><td>✅</td></tr>
<tr><td>SOCKS5</td><td>${RU_SOCKS_PORT}</td><td>${EN_SERVER_IP}:${EN_SOCKS_PORT}</td><td>✅</td></tr>
<tr><td>MTProto</td><td>${RU_MT_PORT}</td><td>${EN_SERVER_IP}:${EN_MT_PORT}</td><td>✅</td></tr></table></div>
<div class="warn"><strong>⚠️ Важно:</strong> В клиентах используйте IP RU сервера <strong>${RU_IP}</strong>. Остальные настройки (UUID, ключи, пароли) берите из EN сервера.</div>
<div class="card"><p><code>systemctl restart relay-vless relay-socks relay-mtproto</code></p><p><code>iptables -t nat -L -n -v</code></p></div>
</body></html>
HTML
}

menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              RU Relay Manager                         ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}\n"
    load_config 2>/dev/null && echo -e "${GREEN}✓ Конфиг загружен: ${EN_SERVER_IP}${NC}\n" || echo -e "${YELLOW}⚠ Конфиг не найден${NC}\n"
    echo -e "${YELLOW}Действия:${NC}"
    echo "1) Полная настройка"
    echo "2) Перезапустить relay"
    echo "3) Изменить EN сервер/порты"
    echo "4) Статус и правила"
    echo "5) Удалить relay"
    echo "0) Выход"
    read -rp "Номер: " ch
    case $ch in
        1) ask_params; ask_method; install_deps; [[ "$RELAY_METHOD" =~ (iptables|both) ]] && setup_iptables; [[ "$RELAY_METHOD" =~ (socat|both) ]] && setup_socat; setup_fw; save_config; generate_html; echo -e "${GREEN}✅ Готово. HTML: $HTML_FILE${NC}";;
        2) load_config || exit 1; [[ "$RELAY_METHOD" =~ (socat|both) ]] && systemctl restart relay-vless relay-socks relay-mtproto; [[ "$RELAY_METHOD" =~ (iptables|both) ]] && setup_iptables; echo -e "${GREEN}✅ Перезапущено${NC}";;
        3) ask_params; ask_method; [[ "$RELAY_METHOD" =~ (iptables|both) ]] && setup_iptables; [[ "$RELAY_METHOD" =~ (socat|both) ]] && setup_socat; save_config; generate_html; echo -e "${GREEN}✅ Обновлено${NC}";;
        4) load_config || exit 1; echo -e "\n📡 iptables NAT:"; iptables -t nat -L -n -v; echo -e "\n🔹 socat статус:"; systemctl status relay-vless relay-socks relay-mtproto --no-pager 2>/dev/null || echo "Не активен";;
        5) read -rp "Удалить? (y/N): " a; [ "$a" = "y" ] && { systemctl stop relay-vless relay-socks relay-mtproto 2>/dev/null; systemctl disable relay-vless relay-socks relay-mtproto 2>/dev/null; rm -f /etc/systemd/system/relay-*.service "$HTML_FILE" "$CONFIG_FILE"; iptables -t nat -F; iptables-save > /etc/iptables/rules.v4 2>/dev/null || true; systemctl daemon-reload; echo "✅ Удалено"; };;
        0) exit 0;;
        *) echo "Неверно"; sleep 1; menu;;
    esac
    read -rp "Enter для меню..."
    menu
}

menu