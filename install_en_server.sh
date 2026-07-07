#!/usr/bin/env bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}Запустите от root: sudo -i${NC}"; exit 1; }

CONFIG_FILE="/root/.proxy_config"
HTML_FILE="/root/proxy_settings.html"
MT_DIR="/opt/MTProxy"
MT_CONF="/etc/mtproto"

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ПРОСТАЯ УСТАНОВКА EN СЕРВЕРА         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"

# 1. Отключение UFW
echo -e "\n${YELLOW}[1/8] Отключение UFW...${NC}"
if command -v ufw &>/dev/null; then
    ufw disable 2>/dev/null || true
    systemctl stop ufw 2>/dev/null || true
    systemctl disable ufw 2>/dev/null || true
    echo -e "${GREEN}✓ UFW отключён${NC}"
else
    echo -e "${GREEN}✓ UFW не установлен${NC}"
fi

# 2. Зависимости
echo -e "\n${YELLOW}[2/8] Установка зависимостей...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y curl wget jq openssl git build-essential cmake libssl-dev zlib1g-dev iptables >/dev/null 2>&1
echo -e "${GREEN}✓ Зависимости установлены${NC}"

# 3. Установка Xray
echo -e "\n${YELLOW}[3/8] Установка Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>&1 | tail -5

XRAY_BIN=$(which xray 2>/dev/null || echo "/usr/local/bin/xray")
echo -e "  Xray binary: $XRAY_BIN"

XRAY_CFG=""
for path in "/usr/local/etc/xray/config.json" "/etc/xray/config.json" "/usr/local/share/xray/config.json"; do
    dir=$(dirname "$path")
    if [ -d "$dir" ] || [ -f "$path" ]; then
        XRAY_CFG="$path"
        echo -e "  Найден путь конфига: $XRAY_CFG"
        break
    fi
done

if [ -z "$XRAY_CFG" ]; then
    echo -e "  ${YELLOW}Путь конфига не найден, создаём /usr/local/etc/xray/...${NC}"
    mkdir -p /usr/local/etc/xray
    XRAY_CFG="/usr/local/etc/xray/config.json"
fi

XRAY_DIR=$(dirname "$XRAY_CFG")
[ ! -d "$XRAY_DIR" ] && mkdir -p "$XRAY_DIR"
chmod 755 "$XRAY_DIR"

echo -e "${GREEN}✓ Xray установлен. Путь конфига: $XRAY_CFG${NC}"

# 4. Генерация параметров
echo -e "\n${YELLOW}[4/8] Генерация параметров...${NC}"
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ipinfo.io/ip)
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
SOCKS_USER=$(openssl rand -hex 4)          # КОРОТКИЙ ЛОГИН (8 символов)
SOCKS_PASS=$(openssl rand -hex 8)          # КОРОТКИЙ ПАРОЛЬ (16 символов)
MT_SECRET="dd$(openssl rand -hex 16)"
MT_TAG="ee$(openssl rand -hex 8)"
VLESS_PORT=443
SOCKS_PORT=10808
MT_PORT=8888

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
    exit 1
fi

echo -e "${GREEN}✓ Параметры сгенерированы:${NC}"
echo -e "  IP: $SERVER_IP"
echo -e "  UUID: $VLESS_UUID"
echo -e "  SOCKS логин: $SOCKS_USER (короткий)"
echo -e "  SOCKS пароль: $SOCKS_PASS (короткий)"
echo -e "  Private Key: ${PRIVATE_KEY:0:20}..."
echo -e "  Public Key: ${PUBLIC_KEY:0:20}..."

# 5. Создание конфига Xray
echo -e "\n${YELLOW}[5/8] Создание конфигурации Xray...${NC}"
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
          "dest": "www.microsoft.com:443",
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

[ ! -f "$XRAY_CFG" ] && { echo -e "${RED}✗ Файл конфига не создан!${NC}"; exit 1; }
echo -e "  ✓ Файл создан: $(ls -lh "$XRAY_CFG" | awk '{print $5, $9}')"

TEST_OUT=$("$XRAY_BIN" run -test -config "$XRAY_CFG" 2>&1)
if echo "$TEST_OUT" | grep -qi "ok\|valid\|success"; then
    echo -e "${GREEN}✓ Конфиг валиден${NC}"
else
    echo -e "${YELLOW}⚠ Вывод проверки:${NC}"
    echo "$TEST_OUT" | sed 's/^/    /'
fi

if [ -f "/etc/systemd/system/xray.service" ]; then
    sed -i "s|/usr/local/etc/xray/config.json|$XRAY_CFG|g" /etc/systemd/system/xray.service 2>/dev/null || true
    sed -i "s|/etc/xray/config.json|$XRAY_CFG|g" /etc/systemd/system/xray.service 2>/dev/null || true
    systemctl daemon-reload
fi

systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ Xray запущен${NC}"
else
    echo -e "${RED}✗ Xray не запустился!${NC}"
    journalctl -u xray -n 20 --no-pager 2>&1
    exit 1
fi

# 6. MTProto
echo -e "\n${YELLOW}[6/8] Компиляция MTProto Proxy...${NC}"
[ ! -d "$MT_DIR" ] && { cd /opt && git clone https://github.com/TelegramMessenger/MTProxy.git >/dev/null 2>&1; }
cd "$MT_DIR"
make clean >/dev/null 2>&1
make -j$(nproc) >/dev/null 2>&1
[ ! -f "$MT_DIR/objs/bin/mtproto-proxy" ] && { echo -e "${RED}✗ Ошибка компиляции MTProto${NC}"; exit 1; }
echo -e "${GREEN}✓ MTProto скомпилирован${NC}"

mkdir -p "$MT_CONF"
cd "$MT_CONF"
curl -s https://core.telegram.org/getProxySecret -o proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf

cat > /etc/systemd/system/mtproto-proxy.service <<MT
[Unit]
Description=MTProto Proxy
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
systemctl is-active --quiet mtproto-proxy && echo -e "${GREEN}✓ MTProto запущен на порту ${MT_PORT}${NC}" || echo -e "${YELLOW}⚠ MTProto не запустился (не критично)${NC}"

# 7. iptables
echo -e "\n${YELLOW}[7/8] Настройка iptables...${NC}"
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
echo -e "${GREEN}✓ iptables настроен (SSH:${SSH_PORT}, прокси-порты открыты)${NC}"

# 8. Сохранение и HTML
echo -e "\n${YELLOW}[8/8] Сохранение конфига и генерация HTML...${NC}"
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
XRAY_CFG="${XRAY_CFG}"
CONF
chmod 600 "$CONFIG_FILE"

VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=&type=tcp&flow=xtls-rprx-vision#EN_VLESS"
SOCKS_LINK="socks5://${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${SOCKS_PORT}#EN_SOCKS5"
MT_LINK="tg://proxy?server=${SERVER_IP}&port=${MT_PORT}&secret=${MT_SECRET}${MT_TAG}"

# HTML с кнопками копирования для КАЖДОГО значения
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
.row{display:flex;align-items:center;gap:8px;margin:8px 0}
.box{background:#edf2f7;padding:12px;border-radius:6px;word-break:break-all;font-family:monospace;font-size:14px;flex:1;min-width:0}
.lbl{font-weight:600;color:#2d3748;display:block;margin-top:12px}
.btn{background:#3182ce;color:#fff;border:none;padding:6px 12px;border-radius:4px;cursor:pointer;white-space:nowrap;flex-shrink:0}
.btn:hover{background:#2c5282}
.btn.ok{background:#38a169}
.info{background:#ebf8ff;border-left:4px solid #3182ce;padding:15px;margin:20px 0}
</style>
</head>
<body>
<h1>🌐 EN Server - Настройки прокси</h1>
<div class="info"><strong>IP:</strong> ${SERVER_IP}<br><strong>Дата:</strong> $(date '+%Y-%m-%d %H:%M:%S')</div>

<div class="card">
<h2>🔐 VLESS + REALITY</h2>
<span class="lbl">UUID:</span>
<div class="row"><div class="box">${VLESS_UUID}</div><button class="btn" onclick="cp(this,'${VLESS_UUID}')">📋 Копировать</button></div>
<span class="lbl">Public Key:</span>
<div class="row"><div class="box">${PUBLIC_KEY}</div><button class="btn" onclick="cp(this,'${PUBLIC_KEY}')">📋 Копировать</button></div>
<span class="lbl">SNI:</span>
<div class="row"><div class="box">www.microsoft.com</div><button class="btn" onclick="cp(this,'www.microsoft.com')">📋 Копировать</button></div>
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
<span class="lbl">Secret:</span>
<div class="row"><div class="box">${MT_SECRET}${MT_TAG}</div><button class="btn" onclick="cp(this,'${MT_SECRET}${MT_TAG}')">📋 Копировать</button></div>
<span class="lbl">Порт:</span>
<div class="row"><div class="box">${MT_PORT}</div><button class="btn" onclick="cp(this,'${MT_PORT}')">📋 Копировать</button></div>
<span class="lbl">IP сервера:</span>
<div class="row"><div class="box">${SERVER_IP}</div><button class="btn" onclick="cp(this,'${SERVER_IP}')">📋 Копировать</button></div>
<span class="lbl">Ссылка для Telegram:</span>
<div class="row"><div class="box">${MT_LINK}</div><button class="btn" onclick="cp(this,'${MT_LINK}')">📋 Копировать</button></div>
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

echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      ✅ УСТАНОВКА ЗАВЕРШЕНА              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo -e "HTML-файл: ${YELLOW}$HTML_FILE${NC}"
echo -e "Конфиг:    ${YELLOW}$CONFIG_FILE${NC}"
echo -e "Xray конфиг: ${YELLOW}$XRAY_CFG${NC}"
echo -e ""
echo -e "${BLUE}Статус сервисов:${NC}"
systemctl is-active xray mtproto-proxy 2>/dev/null | awk '{print "  " $0}'
echo -e ""
echo -e "${BLUE}Открытые порты:${NC}"
ss -tlnp | grep -E ":(443|10808|8888)" | awk '{print "  " $4}'