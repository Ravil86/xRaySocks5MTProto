# xRaySocks5MTProto


Скрипт автоматически перенаправляет на EN сервер (основной)
```bash

bash -c "$(curl -L https://raw.githubusercontent.com/xVRVx/autoXRAY/main/install_en_server.sh)"
```


Скрипт для RU сервера (relay)
```bash

bash -c "$(curl -L https://raw.githubusercontent.com/xVRVx/autoXRAY/main/install_ru_relay.sh)"
```


1. На EN сервере: 
```bash
chmod +x install_en_server.sh && ./install_en_server.sh
```
→ выберите 1

2. Скопируйте IP EN сервера из сгенерированного /root/proxy_settings.html

3. На RU сервере: 

```bash
chmod +x install_ru_relay.sh && ./install_ru_relay.sh
```
→ введите IP EN, выберите 1

4. В клиентах подключайтесь к IP RU сервера, используя параметры из EN HTML-файла.