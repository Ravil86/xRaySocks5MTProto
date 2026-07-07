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

CONFIG_FILE="/root/.relay_config"

# Проверка установленных компонентов
check_installed() {
    echo -e "${BLUE}=== Проверка установленных компонентов ===${NC}"
    
    if command -v socat &> /dev/null; then
        echo -e "${GREEN}✓ Socat установлен${NC}"
    else
        echo -e "${RED}✗ Socat не установлен${NC}"
    fi
    
    if command -v iptables &> /dev/null; then
        echo -e "${GREEN}✓ Iptables установлен${NC}"
    else
        echo -e "${RED}✗ Iptables не установлен${NC}"
    fi
    
    if systemctl is-active --quiet relay-vless 2>/dev/null; then
        echo -e "${GREEN}✓ VLESS relay запущен${NC}"
    else
        echo -e "${YELLOW}⚠ VLESS relay не запущен${NC}"
    fi
    
    if systemctl is-active --quiet relay-socks 2>/dev/null; then
        echo -e "${GREEN}✓ SOCKS relay запущен${NC}"
    else
        echo -e "${YELLOW}⚠ SOCKS relay не запущен${NC}"
    fi
    
    if systemctl is-active --quiet relay-mtproto 2>/dev/null; then
        echo -e "${GREEN}✓ MTProto relay запущен${NC}"
    else
        echo -e "${YELLOW}⚠ MTProto relay не запущен${NC}"
    fi
    
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${GREEN}✓ Конфигурация найдена${NC}"
    else
        echo -e "${YELLOW}⚠ Конфигурация не найдена${NC}"
    fi
    
    echo ""
}

# Загрузка конфигурации
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# Сохранение конфигурации
save_config() {
    cat > "$CONFIG_FILE" <<EOF
EN_SERVER_IP="$EN_SERVER_IP"
EN_VLESS_PORT="$EN_VLESS_PORT"
EN_SOCKS_PORT="$EN_SOCKS_PORT"
EN_MT_PORT="$EN_MT_PORT"
RU_VLESS_PORT="$RU_VLESS_PORT"
RU_SOCKS_PORT="$RU_SOCKS_PORT"
RU_MT_PORT="$RU_MT_PORT"
RELAY_METHOD="$RELAY_METHOD"
EOF
    chmod 600 "$CONFIG_FILE"
}

# Запрос параметров EN сервера
ask_en_params() {
    if [ -f "$CONFIG_FILE" ]; then
        load_config
        echo -e "${YELLOW}Обнаружена существующая конфигурация:${NC}"
        echo "EN Server: $EN_SERVER_IP"
        echo "VLESS: $EN_VLESS_PORT → $RU_VLESS_PORT"
        echo "SOCKS: $EN_SOCKS_PORT → $RU_SOCKS_PORT"
        echo "MTProto: $EN_MT_PORT → $RU_MT_PORT"
        echo ""
        echo -e "${YELLOW}Использовать эти параметры? (y/n)${NC}"
        read -p "> " USE_OLD
        
        if [ "$USE_OLD" = "y" ]; then
            return 0
        fi
    fi
    
    read -p "Введите IP EN сервера: " EN_SERVER_IP
    read -p "Введите порт VLESS EN сервера (по умолчанию 443): " EN_VLESS_PORT
    read -p "Введите порт SOCKS5 EN сервера (по умолчанию 10808): " EN_SOCKS_PORT
    read -p "Введите порт MTProto EN сервера (по умолчанию 8888): " EN_MT_PORT
    
    EN_VLESS_PORT=${EN_VLESS_PORT:-443}
    EN_SOCKS_PORT=${EN_SOCKS_PORT:-10808}
    EN_MT_PORT=${EN_MT_PORT:-8888}
    
    RU_VLESS_PORT=443
    RU_SOCKS_PORT=10808
    RU_MT_PORT=8888
}

# Выбор метода relay
ask_relay_method() {
    echo -e "${YELLOW}Выберите метод relay:${NC}"
    echo "1) iptables (прозрачный, быстрее)"
    echo "2) socat (более надежный, виден в процессах)"
    echo "3) Оба метода"
    read -p "Введите номер (по умолчанию 1): " METHOD_CHOICE
    
    case $METHOD_CHOICE in
        2) RELAY_METHOD="socat" ;;
        3) RELAY_METHOD="both" ;;
        *) RELAY_METHOD="iptables" ;;
    esac
}

# Установка зависимостей
install_dependencies() {
    echo -e "${YELLOW}[1/5] Установка зависимостей...${NC}"
    apt-get update -y
    
    if ! command -v iptables &> /dev/null; then
        apt-get install -y iptables iptables-persistent
    fi
    
    if ! command -v socat &> /dev/null; then
        apt-get install -y socat
    fi
    
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi
}

# Настройка iptables
configure_iptables() {
    echo -e "${YELLOW}[iptables] Настройка правил...${NC}"
    
    # Включение IP forwarding
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p
    
    # Очистка старых правил
    iptables -t nat -F
    
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
    
    # Сохранение правил
    apt-get install -y iptables-persistent
    iptables-save > /etc/iptables/rules.v4
}

# Настройка socat сервисов
configure_socat() {
    echo -e "${YELLOW}[socat] Создание systemd сервисов...${NC}"
    
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
    systemctl enable relay-vless relay-socks relay-mtproto
    systemctl restart relay-vless relay-socks relay-mtproto
}

# Настройка файрвола
configure_firewall() {
    echo -e "${YELLOW}[UFW] Настройка файрвола...${NC}"
    ufw allow $RU_VLESS_PORT/tcp
    ufw allow $RU_SOCKS_PORT/tcp
    ufw allow $RU_SOCKS_PORT/udp
    ufw allow $RU_MT_PORT/tcp
    ufw --force enable
}

# Генерация HTML
generate_html() {
    echo -e "${YELLOW}[HTML] Генерация информационного файла...${NC}"
    
    RU_SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)
    
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
        h2 { color: #3498db; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        .info { background: #d5edf8; border-left: 4px solid #3498db; padding: 15px; margin: 20px 0; }
        .warning { background: #fcf8e3; border-left: 4px solid #f0ad4e; padding: 15px; margin: 20px 0; }
        .success { background: #d4edda; border-left: 4px solid #28a745; padding: 15px; margin: 20px 0; }
        code { background: #ecf0f1; padding: 2px 6px; border-radius: 3px; }
        table { width: 100%; border-collapse: collapse; margin: 15px 0; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #3498db; color: white; }
    </style>
</head>
<body>
    <h1>🇷🇺 RU Relay Server</h1>
    
    <div class="info">
        <strong>RU Server IP:</strong> ${RU_SERVER_IP}<br>
        <strong>EN Server IP:</strong> ${EN_SERVER_IP}<br>
        <strong>Метод relay:</strong> ${RELAY_METHOD}<br>
        <strong>Дата настройки:</strong> $(date '+%Y-%m-%d %H:%M:%S')
    </div>

    <div class="card">
        <h2>⚙️ Маршрутизация портов</h2>
        <table>
            <tr>
                <th>Протокол</th>
                <th>RU Порт</th>
                <th>EN Порт</th>
                <th>Статус</th>
            </tr>
            <tr>
                <td>VLESS</td>
                <td>${RU_VLESS_PORT}</td>
                <td>${EN_SERVER_IP}:${EN_VLESS_PORT}</td>
                <td>✓</td>
            </tr>
            <tr>
                <td>SOCKS5</td>
                <td>${RU_SOCKS_PORT}</td>
                <td>${EN_SERVER_IP}:${EN_SOCKS_PORT}</td>
                <td>✓</td>
            </tr>
            <tr>
                <td>MTProto</td>
                <td>${RU_MT_PORT}</td>
                <td>${EN_SERVER_IP}:${EN_MT_PORT}</td>
                <td>✓</td>
            </tr>
        </table>
    </div>

    <div class="warning">
        <h3>⚠️ Важно для клиентов:</h3>
        <p>Используйте <strong>IP RU сервера (${RU_SERVER_IP})</strong> вместо IP EN сервера в настройках клиентов!</p>
        <p>Все остальные параметры (UUID, ключи, пароли) остаются такими же, как на EN сервере.</p>
    </div>

    <div class="card">
        <h2>🔧 Управление relay</h2>
        <p><strong>Статус сервисов:</strong></p>
        <code>systemctl status relay-vless relay-socks relay-mtproto</code>
        
        <p style="margin-top: 15px;"><strong>Перезапуск:</strong></p>
        <code>systemctl restart relay-vless relay-socks relay-mtproto</code>
        
        <p style="margin-top: 15px;"><strong>Просмотр iptables:</strong></p>
        <code>iptables -t nat -L -n -v</code>
        
        <p style="margin-top: 15px;"><strong>Логи socat:</strong></p>
        <code>journalctl -u relay-vless -f</code>
    </div>

    <div class="success">
        <h3>✓ Настройка завершена</h3>
        <p>RU relay сервер готов к работе. Используйте IP <strong>${RU_SERVER_IP}</strong> в клиентах.</p>
    </div>
</body>
</html>
EOF
}

# Полная установка
full_install() {
    echo -e "${GREEN}=== Полная установка RU relay ===${NC}"
    
    ask_en_params
    ask_relay_method
    
    install_dependencies
    
    case $RELAY_METHOD in
        "iptables")
            configure_iptables
            ;;
        "socat")
            configure_socat
            ;;
        "both")
            configure_iptables
            configure_socat
            ;;
    esac
    
    configure_firewall
    save_config
    generate_html
    
    echo -e "${GREEN}=== Установка завершена! ===${NC}"
    echo -e "${GREEN}HTML файл: /root/relay_info.html${NC}"
}

# Перезапуск всех сервисов
restart_all() {
    echo -e "${GREEN}=== Перезапуск всех сервисов ===${NC}"
    
    if [ -f "$CONFIG_FILE" ]; then
        load_config
        
        if [ "$RELAY_METHOD" = "socat" ] || [ "$RELAY_METHOD" = "both" ]; then
            systemctl restart relay-vless relay-socks relay-mtproto
        fi
        
        if [ "$RELAY_METHOD" = "iptables" ] || [ "$RELAY_METHOD" = "both" ]; then
            configure_iptables
        fi
        
        echo -e "${GREEN}✓ Сервисы перезапущены${NC}"
    else
        echo -e "${RED}✗ Конфигурация не найдена${NC}"
    fi
}

# Обновление конфигурации
update_config() {
    echo -e "${GREEN}=== Обновление конфигурации ===${NC}"
    
    ask_en_params
    ask_relay_method
    
    case $RELAY_METHOD in
        "iptables")
            configure_iptables
            ;;
        "socat")
            configure_socat
            ;;
        "both")
            configure_iptables
            configure_socat
            ;;
    esac
    
    save_config
    generate_html
    
    echo -e "${GREEN}✓ Конфигурация обновлена${NC}"
}

# Удаление
uninstall_all() {
    echo -e "${RED}=== Удаление всех компонентов ===${NC}"
    echo -e "${YELLOW}Вы уверены? (y/n)${NC}"
    read -p "> " CONFIRM
    
    if [ "$CONFIRM" = "y" ]; then
        systemctl stop relay-vless relay-socks relay-mtproto 2>/dev/null
        systemctl disable relay-vless relay-socks relay-mtproto 2>/dev/null
        
        rm -f /etc/systemd/system/relay-*.service
        rm -f /root/relay_info.html
        rm -f "$CONFIG_FILE"
        
        # Очистка iptables
        iptables -t nat -F
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        
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
    echo -e "${BLUE}║         RU Relay Server - Управление прокси          ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_installed
    
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo "1) Полная установка (с нуля)"
    echo "2) Перезапустить все сервисы"
    echo "3) Обновить конфигурацию (изменить EN сервер)"
    echo "4) Показать статус сервисов"
    echo "5) Показать текущие настройки"
    echo "6) Удалить все компоненты"
    echo "0) Выход"
    echo ""
    read -p "Введите номер: " CHOICE
    
    case $CHOICE in
        1) full_install ;;
        2) restart_all ;;
        3) update_config ;;
        4)
            echo -e "${BLUE}=== Статус сервисов ===${NC}"
            if systemctl is-active --quiet relay-vless 2>/dev/null; then
                systemctl status relay-vless --no-pager
            fi
            if systemctl is-active --quiet relay-socks 2>/dev/null; then
                systemctl status relay-socks --no-pager
            fi
            if systemctl is-active --quiet relay-mtproto 2>/dev/null; then
                systemctl status relay-mtproto --no-pager
            fi
            echo ""
            echo -e "${BLUE}=== iptables правила ===${NC}"
            iptables -t nat -L -n -v
            read -p "Нажмите Enter для продолжения..."
            show_menu
            ;;
        5)
            if [ -f "$CONFIG_FILE" ]; then
                load_config
                echo -e "${BLUE}=== Текущие настройки ===${NC}"
                echo "EN Server: $EN_SERVER_IP"
                echo "VLESS: $RU_VLESS_PORT → $EN_SERVER_IP:$EN_VLESS_PORT"
                echo "SOCKS: $RU_SOCKS_PORT → $EN_SERVER_IP:$EN_SOCKS_PORT"
                echo "MTProto: $RU_MT_PORT → $EN_SERVER_IP:$EN_MT_PORT"
                echo "Метод: $RELAY_METHOD"
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