
# NaiveProxy — Пошаговый гайд по установке

**Сервер:** Ubuntu (22.04 и выше) или Debian (11 и выше)

**Системные требования:**
- 1 CPU
- 1 GB RAM
- 10 GB диска

 **Что нужно заранее:**
- VPS с Ubuntu/Debian
- Поддомен, который указывает на IP сервера
- Клиент вроде V2RayN, NekoBox, Karing или аналогичный

---

## Обновление системы и установка базовых утилит


```bash
apt update && apt upgrade -y

apt install -y curl wget git openssl ufw
```

---

## Автоматический способ настройки сервера:

Cкрипт установки в одну команду. Рекомендуется ознакомиться с его содержимым перед выполнением.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/RedDevBook/naiveproxy-server-setup/main/install.sh)
```

Просмотреть зарегистрированных пользователей после выполнения скрипта:

```bash
cat /root/naiveproxy-users.txt
```

---

## Настройка сервера вручную:

## Включение BBR

BBR — это алгоритм, который держит интернет на максимальной скорости, не снижая её из-за мелких потерь пакетов.

```bash
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

sysctl -p
```

Проверяем:
```bash
sysctl net.ipv4.tcp_congestion_control
# Должно показать: net.ipv4.tcp_congestion_control = bbr
```

---

## Настройка файерволла

Открываем только необходимые порты: 22 для SSH, 80 для получения сертификатов Let’s Encrypt и 443 для работы NaiveProxy. Остальные порты закрыты.

```bash
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp

ufw enable

ufw status
```

---

## Установка Go

Go используется только для того, чтобы собрать Caddy с нужным плагином. Стандартный Caddy не включает naive-функции, поэтому его приходится собирать самостоятельно. После этого Go серверу больше не нужен.

```bash
GO_VERSION=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)

wget "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz

rm -rf /usr/local/go

tar -C /usr/local -xzf /tmp/go.tar.gz

echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.profile
echo 'export PATH=$PATH:/root/go/bin' >> /root/.profile

source /root/.profile
```

Проверка того, что go установлен:
```bash
go version
```

---

## Сборка Caddy с naive-плагином

Caddy — это веб-сервер, который автоматически настраивает HTTPS (TLS).  
С добавленным плагином forwardproxy с naive-функциональностью он может работать как прокси и маскировать трафик под обычный Chrome-браузер.  
Сборка обычно занимает 5–7 минут.

```bash
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

mkdir -p /root/tmp

export TMPDIR=/root/tmp

cd /root

~/go/bin/xcaddy build \
  --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive

mv /root/caddy /usr/bin/caddy

chmod +x /usr/bin/caddy
```

Проверка того, что caddy установален:
```bash
caddy version
```

---

## Генерация логина и пароля

На этом этапе генерируем криптографически случайные данные для доступа. Результат нужно копировать и сохранить, чтобы использовать его для настройки клиента на Android и IOS.

```bash
echo "Логин:  $(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 16)"
echo "Пароль: $(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)"
```

---

## Страница заглушка

Создаём простую HTML-заглушку, которая может быть любой. Это нужно для того, чтобы при открытии домена в браузере отображался обычный сайт. Затем настраиваем сервер: подставляем в Caddyfile свой привязанный домен, почту, логин и пароль, которые мы генерировали ранее.

```bash
mkdir -p /var/www/html /etc/caddy

cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title><style>body{background:linear-gradient(135deg,#0f172a,#1e293b);height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.spinner{width:40px;height:40px;border-radius:50%;border:3px solid rgba(255,255,255,0.12);border-top-color:#38bdf8;animation:spin 0.8s linear infinite;margin-bottom:25px;box-shadow:0 0 18px rgba(56,189,248,0.25)}@keyframes spin{to{transform:rotate(360deg)}}.t{color:#cbd5e1;font-size:13px;letter-spacing:3px;font-weight:600}</style></head><body><div class="spinner"></div><div class="t">CONNECTING</div></body></html>
EOF
```

Создаём Caddyfile, в котором необходимо заменить значения на свои. Обратите внимание на пробелы:

```bash
cat > /etc/caddy/Caddyfile << 'EOF'
{
  order forward_proxy before file_server
}

:443, your.domain.com {
  tls your@email.com

  forward_proxy {
    basic_auth YOUR_LOGIN YOUR_PASSWORD
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
EOF
```

Проверяем, что все записалось корректно:

```bash
cat /etc/caddy/Caddyfile
```

---

## Создание Systemd сервиса

systemd обеспечивает автозапуск Caddy при перезагрузке сервера и автоматический перезапуск если процесс упал. После этого шага сервер полностью автономен.

```bash
cat > /etc/systemd/system/caddy.service << 'EOF'
[Unit]
Description=Caddy with NaiveProxy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
```

Активируем:
```bash
systemctl daemon-reload

systemctl enable caddy

systemctl start caddy
```

Проверяем работу:
```bash
systemctl status caddy
```

В логах должно появиться `certificate obtained successfully` — TLS сертификат получен, всё работает корректно.

---

## Настройка клиентов на Android и iOS:

В данный шаблон нам нужно подставить свои собственные значения. Вместо `YOUR_LOGIN` ваше логин, вместо `YOUR_PASSWORD ` ваш пароль и вместо `your.domain.com` ваш привязанный домен.

```
naive+https://YOUR_LOGIN:YOUR_PASSWORD@your.domain.com:443
```

Далее мы копируем уже готовый вариант и выбираем в клиенте "импортировать из буфера обмена". Для NekoBox необходимо заранее загрузить и установить плагин с официальной страницы GitHub разработчика.

---

## Список всех клиентов

| Платформа | Клиенты | Ссылка                                                              |
| --------- | ------- | ------------------------------------------------------------------- |
| iOS       | Karing  | App Store                                                           |
| Android   | NekoBox | [GitHub](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) |
| Android   | Karing  | [GitHub](https://github.com/KaringX/karing/releases/)               |
| Windows   | Hiddify | [GitHub](https://github.com/hiddify/hiddify-app/releases)           |
| Windows   | NekoRay | [GitHub](https://github.com/MatsuriDayo/nekoray/releases)           |
| Windows   | V2RayN  | [GitHub](https://github.com/2dust/v2rayN/releases)                  |

---

## Полезные команды

```bash
# Статус сервиса
systemctl status caddy

# Логи в реальном времени
journalctl -u caddy -f

# Перезапуск после изменений конфига
systemctl restart caddy

# Мягкая перезагрузка без обрыва соединений
caddy reload --config /etc/caddy/Caddyfile

# Проверка синтаксиса конфига
caddy validate --config /etc/caddy/Caddyfile

# Проверить что порт 443 слушается
ss -tlnp | grep 443

# Шаблон ссылки для нового пользователя
echo "naive+https://LOGIN:PASSWORD@your.domain.com:443"
```

---

## Добавление второго пользователя

В `/etc/caddy/Caddyfile` нужно добавить строку `basic_auth` рядом с первой:

```
forward_proxy {
  basic_auth LOGIN_1 PASSWORD_1
  basic_auth LOGIN_2 PASSWORD_2
  hide_ip
  hide_via
  probe_resistance
}
```

Затем мягкая перезагрузка без обрыва соединений:

```bash
caddy reload --config /etc/caddy/Caddyfile
```

Или полный перезапуск если что-то пошло не так:

```bash
systemctl restart caddy
```

> Один логин можно использовать на любом количестве устройств одновременно — ограничений нет.