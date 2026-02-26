#!/usr/bin/env bash
echo "=========== ПРОВЕРКА ПОРТОВ ==========="
sudo lsof -nP -iTCP:443 -sTCP:LISTEN || echo "Порт 443 свободен"
echo "========================================"

set -e

SERVICE_NAME="telemt"
PORT="443"
WORKDIR="/opt/telemt"
COMPOSE_FILE="${WORKDIR}/docker-compose.yml"
CONF_FILE="${WORKDIR}/telemt.toml"

EXTERNAL_IP=$(curl -4 -s https://api.ipify.org || curl -s ifconfig.me)

menu() {
  echo "=============v3================="
  echo " 1 - Установить сервис"
  echo " 2 - Полностью удалить сервис"
  echo "=============================="
  read -r -p "Выберите действие: " ACTION
}

remove_service() {
  echo "[*] Полное удаление сервиса..."

  docker rm -f "${SERVICE_NAME}" 2>/dev/null || true
  docker compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true

  # Удаляем сеть telemt_default, если осталась
  docker network rm telemt_default 2>/dev/null || true

  # Убиваем docker-proxy, если остался
  PROXIES=$(ps aux | grep docker-proxy | grep ":${PORT}" | awk '{print $2}')
  for P in $PROXIES; do
    kill -9 "$P" 2>/dev/null || true
  done

  rm -rf "${WORKDIR}"

  echo "[+] Сервис полностью удалён."
  exit 0
}

menu

if [[ "$ACTION" == "2" ]]; then
  remove_service
fi

echo "[*] Проверка прав..."
if [[ $EUID -ne 0 ]]; then
  echo "[-] Запусти скрипт через sudo или от root."
  exit 1
fi

echo "[*] Обновление пакетов..."
apt update -y

echo "[*] Проверка Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "[*] Docker не найден. Устанавливаю..."
  apt install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

echo "[*] Проверка docker compose..."
if ! docker compose version >/dev/null 2>&1; then
  echo "[-] Docker Compose не установлен."
  exit 1
fi

echo "[*] Проверка порта ${PORT}..."

free_port() {
  while ss -tulnp | grep -q ":${PORT} "; do
    PORT_INFO=$(ss -tulnp | grep ":${PORT} ")
    PID=$(echo "$PORT_INFO" | grep -oP 'pid=\K[0-9]+')

    if [[ -z "$PID" ]]; then
      echo "[-] Не удалось определить PID процесса:"
      echo "$PORT_INFO"
      exit 1
    fi

    PROC_NAME=$(ps -p "$PID" -o comm= 2>/dev/null || echo "unknown")

    echo "[!] Порт ${PORT} занят:"
    echo "    PID:  $PID"
    echo "    NAME: $PROC_NAME"

    read -r -p "Остановить процесс PID ${PID}? [y/N]: " KILL_PROC
    if [[ "${KILL_PROC}" =~ ^[Yy]$ ]]; then
      kill -9 "$PID" 2>/dev/null || true
      sleep 1
    else
      echo "[-] Установка невозможна."
      exit 1
    fi
  done
}

free_port

echo "[*] Создаю рабочую директорию: ${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "[*] Введи домен (SNI), например: сайт.ru"
read -r TLS_DOMAIN
if [[ -z "${TLS_DOMAIN}" ]]; then
  echo "[-] Домен не может быть пустым."
  exit 1
fi

echo "[*] Генерирую секрет пользователя..."
USER_SECRET=$(openssl rand -hex 16)

echo "[*] Создаю telemt.toml..."
cat > "${CONF_FILE}" <<EOF
show_link = ["user1"]

[general]
prefer_ipv6 = false
fast_mode = true
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${PORT}
listen_addr_ipv4 = "0.0.0.0"
listen_addr_ipv6 = "::"

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
mask_port = ${PORT}
fake_cert_len = 2048

[access.users]
user1 = "${USER_SECRET}"

[[upstreams]]
type = "direct"
enabled = true
weight = 10
EOF

echo "[*] Создаю docker-compose.yml..."
cat > "${COMPOSE_FILE}" <<EOF
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
    ports:
      - "${PORT}:${PORT}/tcp"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
EOF

echo "[*] Запускаю сервис..."
docker compose up -d

echo "[*] Жду запуск..."
sleep 5

echo "[*] Ищу ссылку tg://proxy..."
RAW_LINK=$(docker logs "${SERVICE_NAME}" --tail=300 2>/dev/null | grep -Eo 'tg://proxy[^ ]+' | tail -n1 || true)

# IPv6 внешний
EXTERNAL_IPv6=$(curl -6 -s https://ifconfig.co || echo "")

if [[ -n "${RAW_LINK}" ]]; then
  # IPv4
  FIXED_LINK4=$(echo "$RAW_LINK" | sed -E "s/server=[^&]+/server=${EXTERNAL_IP}/")

  # IPv6 (если есть)
  if [[ -n "$EXTERNAL_IPv6" ]]; then
    FIXED_LINK6=$(echo "$RAW_LINK" | sed -E "s/server=[^&]+/server=

\[${EXTERNAL_IPv6}\]

/")
  else
    FIXED_LINK6="IPv6 адрес не найден"
  fi

  echo ""
  echo "================= ССЫЛКИ ================="
  echo "IPv4:"
  echo "$FIXED_LINK4"
  echo ""
  echo "IPv6:"
  echo "$FIXED_LINK6"
  echo "==========================================="
else
  echo "[!] Не удалось автоматически найти ссылку."
  echo "Проверь вручную:"
  echo "  docker logs ${SERVICE_NAME} --tail=300 | grep -Eo 'tg://proxy[^ ]+'"
fi

