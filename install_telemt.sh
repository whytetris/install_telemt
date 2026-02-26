#!/usr/bin/env bash
set -e

SERVICE_NAME="telemt"
PORT="443"
WORKDIR="/opt/telemt"
COMPOSE_FILE="${WORKDIR}/docker-compose.yml"
CONF_FILE="${WORKDIR}/telemt.toml"

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
  echo "[-] Docker Compose не установлен. Убедись, что установлен пакет docker-compose-plugin."
  exit 1
fi

echo "[*] Проверка порта ${PORT}..."
if ss -tulnp | grep -q ":${PORT} "; then
  echo "[!] Порт ${PORT} занят."

  # Получаем PID и команду процесса
  PORT_INFO=$(ss -tulnp | grep ":${PORT} ")
  PID=$(echo "$PORT_INFO" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
  PROC_NAME=$(ps -p "$PID" -o comm= 2>/dev/null || echo "unknown")

  echo "[!] Порт занят процессом:"
  echo "    PID:  $PID"
  echo "    NAME: $PROC_NAME"

  # Проверяем, наш ли это контейнер
  if docker ps --format '{{.Names}}' | grep -qx "${SERVICE_NAME}"; then
    echo "[*] Это контейнер ${SERVICE_NAME}."

    read -r -p "Переустановить сервис? [y/N]: " REINSTALL
    if [[ "${REINSTALL}" =~ ^[Yy]$ ]]; then
      echo "[*] Останавливаю и удаляю контейнер..."
      docker rm -f "${SERVICE_NAME}" >/dev/null 2>&1 || true
    else
      echo "[*] Отмена."
      exit 0
    fi

  else
    echo "[!] Это НЕ telemt. Нужно освободить порт."

    read -r -p "Остановить процесс PID ${PID}? [y/N]: " KILL_PROC
    if [[ "${KILL_PROC}" =~ ^[Yy]$ ]]; then
      echo "[*] Останавливаю процесс..."
      kill -9 "$PID" || true
    else
      echo "[*] Отмена."
      exit 1
    fi

    # Проверяем systemd unit
    UNIT=$(systemctl status "$PROC_NAME" 2>/dev/null | grep "Loaded:" | awk '{print $2}' || true)

    if [[ -n "$UNIT" ]]; then
      echo "[*] Обнаружена systemd-служба: $UNIT"

      read -r -p "Отключить автозапуск и остановить службу $UNIT? [y/N]: " DISABLE_UNIT
      if [[ "${DISABLE_UNIT}" =~ ^[Yy]$ ]]; then
        systemctl stop "$UNIT" || true
        systemctl disable "$UNIT" || true
        echo "[+] Служба $UNIT остановлена и отключена."
      else
        echo "[*] Служба не отключена. Порт может снова заняться."
      fi
    fi
  fi
fi


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
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 256M
EOF

echo "[*] Запускаю сервис..."
docker compose up -d

echo "[*] Жду запуск..."
sleep 5

echo "[*] Ищу ссылку tg://proxy..."
LINK=$(docker logs "${SERVICE_NAME}" --tail=300 2>/dev/null | grep -Eo 'tg://proxy[^ ]+' | tail -n1 || true)

if [[ -n "${LINK}" ]]; then
  echo "[+] Готово! Твоя ссылка:"
  echo "${LINK}"
else
  echo "[!] Не удалось автоматически найти ссылку."
  echo "Проверь вручную:"
  echo "  docker logs ${SERVICE_NAME} --tail=300 | grep -Eo 'tg://proxy[^ ]+'"
fi
