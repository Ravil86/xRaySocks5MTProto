#!/usr/bin/env bash
echo "=== ДИАГНОСТИКА ==="
echo "1. Проверка xray:"
which xray
xray version 2>&1 | head -3

echo ""
echo "2. Генерация ключей x25519:"
xray x25519 2>&1

echo ""
echo "3. Проверка UUID:"
cat /proc/sys/kernel/random/uuid

echo ""
echo "4. Текущий конфиг Xray (если есть):"
cat /usr/local/etc/xray/config.json 2>/dev/null | head -30 || echo "Конфига нет"

echo ""
echo "5. Тест конфига:"
xray run -test -config /usr/local/etc/xray/config.json 2>&1 | head -10 || echo "Конфиг невалиден или отсутствует"

echo ""
echo "6. Статус xray:"
systemctl status xray --no-pager 2>&1 | head -10

echo ""
echo "7. Логи xray:"
journalctl -u xray -n 20 --no-pager 2>&1