#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="mtg"
IMAGE="nineseconds/mtg:2"
PORT="443"
WORKDIR="/opt/mtg"
COMPOSE_FILE="${WORKDIR}/docker-compose.yml"
CONF_FILE="${WORKDIR}/mtg.toml"
UPSTREAM_REPO_URL="https://github.com/9seconds/mtg"

EXTERNAL_IP="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || curl -4 -fsSL https://ifconfig.me 2>/dev/null || true)"

print_port_status() {
  echo "=========== PROVERKA PORTA ==========="
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN || echo "Port ${PORT} svoboden"
  else
    ss -tulnp | grep -q ":${PORT} " && ss -tulnp | grep ":${PORT} " || echo "Port ${PORT} svoboden"
  fi
  echo "======================================"
}

menu() {
  echo "=============== MTG ==============="
  echo " 1 - Ustanovit servis"
  echo " 2 - Polnostyu udalit servis"
  echo " 3 - Pokazat ssylki"
  echo " 4 - Dobavit VPN DNAT-fix"
  echo "==================================="
  read -r -p "Vyberite deystvie: " ACTION
}

remove_service() {
  echo "[*] Polnoe udalenie servisa..."

  docker rm -f "${SERVICE_NAME}" 2>/dev/null || true
  if [[ -f "${COMPOSE_FILE}" ]]; then
    docker compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
  fi

  docker network rm mtg_default 2>/dev/null || true

  PROXIES="$(ps aux | grep docker-proxy | grep ":${PORT}" | awk '{print $2}' || true)"
  for proxy_pid in ${PROXIES}; do
    kill -9 "${proxy_pid}" 2>/dev/null || true
  done

  rm -rf "${WORKDIR}"

  echo "[+] Servis polnostyu udalen."
  exit 0
}

print_access_links() {
  local access_output tg_links tme_links

  echo "[*] Poluchayu ssylki iz mtg access..."
  access_output="$(docker exec "${SERVICE_NAME}" /mtg access /config.toml 2>/dev/null || true)"

  if [[ -z "${access_output}" ]]; then
    echo "[-] Ne udalos poluchit ssylki. Vozmozhno, konteyner ne zapushchen."
    return 1
  fi

  tg_links="$(printf '%s\n' "${access_output}" | grep -Eo 'tg://proxy[^"]+' | awk '!seen[$0]++' || true)"
  tme_links="$(printf '%s\n' "${access_output}" | grep -Eo 'https://t\.me/proxy[^"]+' | awk '!seen[$0]++' || true)"

  echo ""
  echo "================= SSYLKI ================="
  if [[ -n "${tg_links}" ]]; then
    echo "tg://proxy"
    printf '%s\n' "${tg_links}"
    echo ""
  fi
  if [[ -n "${tme_links}" ]]; then
    echo "https://t.me/proxy"
    printf '%s\n' "${tme_links}"
    echo ""
  fi

  echo "JSON ot mtg access:"
  printf '%s\n' "${access_output}"
  echo "=========================================="
  return 0
}

vpn_fix() {
  if [[ -z "${EXTERNAL_IP}" ]]; then
    echo "[-] Ne udalos opredelit vneshniy IPv4 adres."
    exit 1
  fi

  echo "[*] Nastroyka DNAT dlya raboty MTG pri aktivnom VPN..."
  echo "[*] Vneshniy IP: ${EXTERNAL_IP}"
  echo "[*] Port: ${PORT}"

  iptables -t nat -C OUTPUT -d "${EXTERNAL_IP}" -p tcp --dport "${PORT}" -j DNAT --to-destination 127.0.0.1:${PORT} 2>/dev/null || \
    iptables -t nat -A OUTPUT -d "${EXTERNAL_IP}" -p tcp --dport "${PORT}" -j DNAT --to-destination 127.0.0.1:${PORT}

  echo "[+] Pravilo DNAT dobavleno."
  echo "[+] Trafik na ${EXTERNAL_IP}:${PORT} budet zavorachivatsya v lokalnyy MTG."
  exit 0
}

free_port() {
  while ss -tulnp | grep -q ":${PORT} "; do
    local port_info pid proc_name kill_proc

    port_info="$(ss -tulnp | grep ":${PORT} ")"
    pid="$(echo "${port_info}" | grep -oP 'pid=\K[0-9]+' | head -n1 || true)"

    if [[ -z "${pid}" ]]; then
      echo "[-] Ne udalos opredelit PID protsessa:"
      echo "${port_info}"
      exit 1
    fi

    proc_name="$(ps -p "${pid}" -o comm= 2>/dev/null || echo "unknown")"

    echo "[!] Port ${PORT} zanyat:"
    echo "    PID:  ${pid}"
    echo "    NAME: ${proc_name}"

    read -r -p "Ostanovit protsess PID ${pid}? [y/N]: " kill_proc
    if [[ "${kill_proc}" =~ ^[Yy]$ ]]; then
      kill -9 "${pid}" 2>/dev/null || true
      sleep 1
    else
      echo "[-] Ustanovka nevozmozhna."
      exit 1
    fi
  done
}

write_config() {
  echo "[*] Sozdayu mtg.toml..."
  cat > "${CONF_FILE}" <<EOF
secret = "${USER_SECRET}"
bind-to = "0.0.0.0:${PORT}"
prefer-ip = "prefer-ipv4"
EOF

  if [[ -n "${EXTERNAL_IP}" ]]; then
    printf 'public-ipv4 = "%s"\n' "${EXTERNAL_IP}" >> "${CONF_FILE}"
  fi
}

write_compose() {
  echo "[*] Sozdayu docker-compose.yml..."
  cat > "${COMPOSE_FILE}" <<EOF
services:
  mtg:
    image: ${IMAGE}
    container_name: ${SERVICE_NAME}
    command: ["run", "/config.toml"]
    restart: unless-stopped
    volumes:
      - ./mtg.toml:/config.toml:ro
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
}

print_port_status
menu

if [[ "${ACTION}" == "2" ]]; then
  remove_service
fi

if [[ "${ACTION}" == "3" ]]; then
  print_access_links
  exit $?
fi

if [[ "${ACTION}" == "4" ]]; then
  vpn_fix
fi

echo "[*] Proverka prav..."
if [[ "${EUID}" -ne 0 ]]; then
  echo "[-] Zapustite skript cherez sudo ili ot root."
  exit 1
fi

echo "[*] Obnovlenie paketov..."
apt update -y

echo "[*] Proverka Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "[*] Docker ne nayden. Ustanavlivayu..."
  apt install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

echo "[*] Proverka docker compose..."
if ! docker compose version >/dev/null 2>&1; then
  echo "[-] Docker Compose ne ustanovlen."
  exit 1
fi

echo "[*] Proverka porta ${PORT}..."
free_port

echo "[*] Sozdayu rabochuyu direktoriyu: ${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "[*] Ukazhite domen dlya FakeTLS (primer: cdn.example.com)"
read -r TLS_DOMAIN
if [[ -z "${TLS_DOMAIN}" ]]; then
  echo "[-] Domen ne mozhet byt pustym."
  exit 1
fi

echo "[*] Podtyagivayu obraz ${IMAGE}..."
docker pull "${IMAGE}"

echo "[*] Generiruyu secret cherez ofitsialnyy mtg..."
USER_SECRET="$(docker run --rm "${IMAGE}" generate-secret --hex "${TLS_DOMAIN}")"

write_config
write_compose

echo "[*] Zapuskayu servis..."
docker compose up -d

echo "[*] Zhdu zapusk..."
sleep 5

echo "[*] Proveryayu dostup k ssylkam..."
if ! print_access_links; then
  echo "[!] Ssylki ne poluchilos vyvesti avtomaticheski. Proverte logi konteynera vruchnuyu."
fi

echo "[*] Upstream proekt: ${UPSTREAM_REPO_URL}"
