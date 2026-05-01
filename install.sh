#!/usr/bin/env bash
set -Eeuo pipefail

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

trap 'die "Ошибка на строке $LINENO. Смотри вывод выше."' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root."
}

check_os() {
  [[ -r /etc/os-release ]] || die "Не удалось определить ОС."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      warn "Скрипт рассчитан на Debian/Ubuntu. Сейчас: ${ID:-unknown} ${VERSION_ID:-unknown}"
      ;;
  esac
}

check_arch() {
  case "$(uname -m)" in
    x86_64) GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    *)
      die "Неподдерживаемая архитектура: $(uname -m)"
      ;;
  esac
}

check_ports_free() {
  for port in 80 443; do
    if ss -tln "( sport = :$port )" 2>/dev/null | tail -n +2 | grep -q .; then
      die "Порт $port уже занят. Освободи его и запусти скрипт снова."
    fi
  done
}

prompt_inputs() {
  while true; do
    read -r -p "Введите домен или поддомен (например, proxy.example.com): " DOMAIN
    [[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] && break
    warn "Домен выглядит некорректно."
  done

  while true; do
    read -r -p "Введите email для TLS (например, admin@example.com): " EMAIL
    [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
    warn "Email выглядит некорректно."
  done

  while true; do
    read -r -p "Сколько пользователей создать? " USERS
    [[ "$USERS" =~ ^[1-9][0-9]*$ ]] && break
    warn "Нужно целое число от 1."
  done
}

gen_token() {
  local len="$1"
  local token=""

  while [[ ${#token} -lt "$len" ]]; do
    token+="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | tr -d '\n')"
  done

  printf '%s' "${token:0:$len}"
}

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    local backup="${path}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "$backup"
    log "Сделана резервная копия: $backup"
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget openssl ca-certificates ufw iproute2 tar
}

enable_bbr() {
  local sysctl_file="/etc/sysctl.d/99-naiveproxy-bbr.conf"
  cat > "$sysctl_file" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    log "BBR включён."
  else
    warn "BBR не подтвердился. На некоторых ядрах он может быть недоступен."
  fi
}

configure_firewall() {
  ufw allow 22/tcp >/dev/null || true
  ufw allow 80/tcp >/dev/null || true
  ufw allow 443/tcp >/dev/null || true
  ufw --force enable >/dev/null || true
  log "UFW настроен."
}

install_go() {
  log "Установка Go..."
  local go_version
  go_version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
  [[ "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Не удалось получить версию Go."

  local go_tar="/tmp/${go_version}.linux-${GO_ARCH}.tar.gz"
  wget -q "https://go.dev/dl/${go_version}.linux-${GO_ARCH}.tar.gz" -O "$go_tar"

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$go_tar"

  export PATH="$PATH:/usr/local/go/bin:/root/go/bin"
  go version
}

build_caddy() {
  export PATH="$PATH:/usr/local/go/bin:/root/go/bin"
  export TMPDIR=/root/tmp
  mkdir -p /root/tmp

  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

  cd /root
  rm -f /root/caddy

  /root/go/bin/xcaddy build \
    --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive

  install -m 0755 /root/caddy /usr/bin/caddy
  /usr/bin/caddy version
}

create_web_root() {
  mkdir -p /var/www/html /etc/caddy

  cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Loading</title>
  <style>
    body{background:linear-gradient(135deg,#0f172a,#1e293b);height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}
    .spinner{width:40px;height:40px;border-radius:50%;border:3px solid rgba(255,255,255,0.12);border-top-color:#38bdf8;animation:spin 0.8s linear infinite;margin-bottom:25px;box-shadow:0 0 18px rgba(56,189,248,0.25)}
    @keyframes spin{to{transform:rotate(360deg)}}
    .t{color:#cbd5e1;font-size:13px;letter-spacing:3px;font-weight:600}
  </style>
</head>
<body>
  <div class="spinner"></div>
  <div class="t">CONNECTING</div>
</body>
</html>
EOF
}

generate_users() {
  USERS_FILE="/root/naiveproxy-users.txt"
  : > "$USERS_FILE"
  chmod 600 "$USERS_FILE"

  BASIC_AUTH_LINES=""

  for ((i=1; i<=USERS; i++)); do
    login="u${i}_$(gen_token 6)"
    password="$(gen_token 24)"

    BASIC_AUTH_LINES+=$'    basic_auth '"$login"' '"$password"$'\n'

    link="naive+https://${login}:${password}@${DOMAIN}:443"
    printf 'User %d\n  login: %s\n  password: %s\n  link: %s\n\n' \
      "$i" "$login" "$password" "$link" | tee -a "$USERS_FILE" >/dev/null
  done
}

create_caddyfile() {
  backup_if_exists /etc/caddy/Caddyfile

  cat > /etc/caddy/Caddyfile <<EOF
{
  order forward_proxy before file_server
}

:443, ${DOMAIN} {
  tls ${EMAIL}

  forward_proxy {
${BASIC_AUTH_LINES}    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
EOF

  chmod 644 /etc/caddy/Caddyfile
  log "Caddyfile создан."
}

create_systemd_unit() {
  backup_if_exists /etc/systemd/system/caddy.service

  cat > /etc/systemd/system/caddy.service <<'EOF'
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

  systemctl daemon-reload
}

start_service() {
  /usr/bin/caddy validate --config /etc/caddy/Caddyfile
  systemctl enable caddy
  systemctl restart caddy
  systemctl --no-pager --full status caddy || true
}

main() {
  require_root
  check_os
  check_arch
  check_ports_free
  prompt_inputs
  install_packages
  enable_bbr
  configure_firewall
  install_go
  build_caddy
  create_web_root
  generate_users
  create_caddyfile
  create_systemd_unit
  start_service

  log "Готово."
  echo
  echo "Файл с учётными данными: /root/naiveproxy-users.txt"
  echo "Готовая ссылка формата:"
  echo "  naive+https://LOGIN:PASSWORD@${DOMAIN}:443"
  echo
  echo "Проверка логов:"
  echo "  journalctl -u caddy -f"
}

main "$@"