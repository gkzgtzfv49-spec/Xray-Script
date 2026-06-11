#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG="/usr/local/etc/xray/config.json"
OUTFILE="/root/xray-client-links.txt"
CERT_DIR="/var/lib/xray/ssl"
SCRIPT_URL="https://raw.githubusercontent.com/gkzgtzfv49-spec/Xray-Script/main/xray.sh"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Запускай от root: sudo bash $0${NC}"
  exit 1
fi

# сохраняем себя на диск если запущены через curl
if [[ ! -f "/root/xray.sh" ]]; then
  curl -sSL "$SCRIPT_URL" -o /root/xray.sh
  chmod +x /root/xray.sh
fi
if [[ ! -f "/usr/local/bin/xray-manage" ]]; then
  ln -sf /root/xray.sh /usr/local/bin/xray-manage
  chmod +x /usr/local/bin/xray-manage
fi

TLS_CIPHERS="TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
XRAY_PORT=443

# ══════════════════════════════════════════════════
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ══════════════════════════════════════════════════

get_server_ip() {
  local IP=""
  for SVC in "ifconfig.me" "api.ipify.org" "ipecho.net/plain" "icanhazip.com"; do
    IP=$(curl -s --max-time 5 "$SVC" 2>/dev/null | tr -d '[:space:]')
    [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    IP=""
  done
  if [[ -z "$IP" ]]; then
    read -rp "  Введи IP сервера вручную: " IP
  fi
  echo "$IP"
}

ask_tls_cert() {
  local DOMAIN=$1
  local EMAIL=$2

  # валидация email
  while [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
    echo -e "  ${RED}Некорректный email: $EMAIL${NC}"
    echo -e "  Используй только латинские символы, например: user@gmail.com"
    read -rp "  Email: " EMAIL
  done

  # установка acme.sh
  if [[ ! -f "/root/.acme.sh/acme.sh" ]]; then
    curl -sSL https://get.acme.sh | sh -s email="$EMAIL"
    source /root/.bashrc 2>/dev/null || true
  fi
  export PATH="$PATH:/root/.acme.sh"
  mkdir -p "$CERT_DIR"

  # останавливаем всё что занимает порт 80
  systemctl stop xray 2>/dev/null || true
  fuser -k 80/tcp 2>/dev/null || true
  sleep 1

  # выпускаем сертификат
  echo -e "  Выпускаю сертификат для $DOMAIN..."
  ~/.acme.sh/acme.sh --issue -d "$DOMAIN"     --standalone --httpport 80     --force --server letsencrypt     --keylength ec-256 2>&1 | tail -8

  # проверяем что файлы появились
  local ACME_CERT="/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer"
  local ACME_KEY="/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"
  local ACME_CHAIN="/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer"

  # fallback для не-ecc
  if [[ ! -f "$ACME_CHAIN" ]]; then
    ACME_CERT="/root/.acme.sh/${DOMAIN}/${DOMAIN}.cer"
    ACME_KEY="/root/.acme.sh/${DOMAIN}/${DOMAIN}.key"
    ACME_CHAIN="/root/.acme.sh/${DOMAIN}/fullchain.cer"
  fi

  if [[ ! -f "$ACME_CHAIN" ]] || [[ ! -s "$ACME_CHAIN" ]]; then
    echo -e "  ${RED}Ошибка: сертификат не выпущен!${NC}"
    echo -e "  Проверь что домен $DOMAIN указывает на этот сервер"
    echo -e "  и порт 80 доступен снаружи."
    exit 1
  fi

  # копируем вручную напрямую (надёжнее чем --install-cert)
  cp "$ACME_CHAIN" "$CERT_DIR/cert.pem"
  cp "$ACME_KEY"   "$CERT_DIR/cert.key"

  # настраиваем авторенью
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN"     --key-file      "$CERT_DIR/cert.key"     --fullchain-file "$CERT_DIR/cert.pem"     --reloadcmd "systemctl restart xray" 2>&1 | tail -3

  chmod 700 "$CERT_DIR"
  chmod 600 "$CERT_DIR/cert.key"
  chmod 644 "$CERT_DIR/cert.pem"

  # проверка
  if [[ ! -s "$CERT_DIR/cert.pem" ]] || [[ ! -s "$CERT_DIR/cert.key" ]]; then
    echo -e "  ${RED}Ошибка: файлы сертификата пустые!${NC}"
    exit 1
  fi

  echo -e "  ✓ Сертификат успешно установлен ($(wc -c < "$CERT_DIR/cert.pem") байт)"

  # возвращаем xray (запустится после записи конфига)
}

ask_port() {
  echo ""
  read -rp "  Порт [443]: " INPUT_PORT
  INPUT_PORT=${INPUT_PORT:-443}
  if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || [[ "$INPUT_PORT" -lt 1 ]] || [[ "$INPUT_PORT" -gt 65535 ]]; then
    echo -e "  ${RED}Неверный порт, ставлю 443${NC}"
    INPUT_PORT=443
  fi
  XRAY_PORT=$INPUT_PORT

  # открываем порт в UFW
  ufw allow "$XRAY_PORT"/tcp >/dev/null 2>&1 || true
  echo -e "  ✓ Порт: ${GREEN}$XRAY_PORT${NC}"
}

ask_users() {
  local PROTO=$1
  echo ""
  echo -e "${BOLD}  Настройка пользователей:${NC}"
  echo ""
  read -rp "  Сколько создать? [1]: " CNT; CNT=${CNT:-1}
  if ! [[ "$CNT" =~ ^[0-9]+$ ]] || [[ "$CNT" -lt 1 ]]; then CNT=1; fi

  PASSWORDS=()
  USERNAMES=()
  for ((i=1; i<=CNT; i++)); do
    echo ""
    echo -e "  ${BOLD}Пользователь $i:${NC}"
    read -rp "  Имя (например: ivan, Enter=авто): " UNAME
    [[ -z "$UNAME" ]] && UNAME="user$(openssl rand -hex 2)"

    if [[ "$PROTO" == "trojan" ]]; then
      read -rp "  Пароль (Enter=авто): " PASS
      if [[ -z "$PASS" ]]; then
        PASS=$(openssl rand -hex 16)
        echo -e "  Авто-пароль: ${GREEN}$PASS${NC}"
      fi
    else
      read -rp "  UUID (Enter=авто): " PASS
      if [[ -z "$PASS" ]]; then
        PASS=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        echo -e "  Авто-UUID: ${GREEN}$PASS${NC}"
      fi
    fi
    PASSWORDS+=("$PASS")
    USERNAMES+=("$UNAME")
  done
}

make_clients_json() {
  local PROTO=$1
  local JSON=""
  local IDX=0
  for PASS in "${PASSWORDS[@]}"; do
    [[ -n "$JSON" ]] && JSON+=","
    local UNAME="${USERNAMES[$IDX]}"
    [[ -z "$UNAME" ]] && UNAME="user-${PASS:0:6}"
    if [[ "$PROTO" == "trojan" ]]; then
      JSON+="{\"password\":\"$PASS\",\"email\":\"${UNAME}@xray\"}"
    else
      JSON+="{\"id\":\"$PASS\",\"email\":\"${UNAME}@xray\"}"
    fi
    ((IDX++))
  done
  echo "$JSON"
}

make_link() {
  local PROTO=$1 PASS=$2 DOMAIN=$3 IP=$4
  case $PROTO in
    trojan-ws)
      echo "trojan://${PASS}@${DOMAIN}:${XRAY_PORT}?security=tls&sni=${DOMAIN}&type=ws&path=%2Fws#Trojan-WS-${PASS:0:6}"
      ;;
    trojan-tcp)
      echo "trojan://${PASS}@${DOMAIN}:${XRAY_PORT}?security=tls&sni=${DOMAIN}&type=tcp#Trojan-TCP-${PASS:0:6}"
      ;;
    vless-ws)
      echo "vless://${PASS}@${DOMAIN}:${XRAY_PORT}?security=tls&sni=${DOMAIN}&type=ws&path=%2Fws&encryption=none#VLESS-WS-${PASS:0:6}"
      ;;
    vless-tcp)
      echo "vless://${PASS}@${DOMAIN}:${XRAY_PORT}?security=tls&sni=${DOMAIN}&type=tcp&encryption=none#VLESS-TCP-${PASS:0:6}"
      ;;


  esac
}

print_links() {
  local PROTO=$1 DOMAIN=$2 IP=$3
  > "$OUTFILE"
  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Ссылки для подключения:${NC}"
  echo ""

  for PASS in "${PASSWORDS[@]}"; do
    LINK=$(make_link "$PROTO" "$PASS" "$DOMAIN" "$IP")
    echo -e "${BOLD}  ${PASS:0:8}...${NC}"
    echo "  $LINK"
    echo ""
    qrencode -t ANSIUTF8 "$LINK"
    echo "  ──────────────────────────────────────"
    { echo "=== ${PASS:0:8} ==="; echo "ССЫЛКА: $LINK"; echo ""; } >> "$OUTFILE"
  done

  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
  echo -e "  Сохранено: ${YELLOW}$OUTFILE${NC}"
}

write_config_tls() {
  local PROTO=$1 DOMAIN=$2 CLIENTS=$3 NETWORK=$4
  local TAG NET_SETTINGS
  if [[ "$PROTO" == "trojan" ]]; then
    TAG="TROJAN_${NETWORK^^}_TLS"
    PROTO_KEY="trojan"
    SETTINGS="\"clients\": [$CLIENTS]"
  else
    TAG="VLESS_${NETWORK^^}_TLS"
    PROTO_KEY="vless"
    SETTINGS="\"clients\": [$CLIENTS], \"decryption\": \"none\""
  fi

  if [[ "$NETWORK" == "ws" ]]; then
    NET_SETTINGS='"wsSettings": { "path": "/ws", "headers": {} }'
  else
    NET_SETTINGS='"tcpSettings": {}'
  fi

  cat > "$CONFIG" << EOF
{
  "log": { "loglevel": "none" },
  "dns": { "servers": ["1.1.1.1", "1.0.0.1"] },
  "inbounds": [{
    "tag": "$TAG", "port": $XRAY_PORT, "listen": "0.0.0.0",
    "protocol": "$PROTO_KEY",
    "settings": { $SETTINGS },
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] },
    "streamSettings": {
      "network": "$NETWORK", "security": "tls",
      $NET_SETTINGS,
      "tlsSettings": {
        "minVersion": "1.2",
        "certificates": [{ "keyFile": "$CERT_DIR/cert.key", "certificateFile": "$CERT_DIR/cert.pem" }],
        "cipherSuites": "$TLS_CIPHERS",
        "rejectUnknownSni": true
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "DIRECT" },{ "protocol": "blackhole", "tag": "BLOCK" }],
  "routing": { "rules": [
    { "ip": ["geoip:private"], "outboundTag": "BLOCK" },
    { "domain": ["geosite:private"], "outboundTag": "BLOCK" },
    { "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
  ]}
}
EOF
}

restart_xray() {
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  sleep 2
  STATUS=$(systemctl is-active xray)
  if [[ "$STATUS" == "active" ]]; then
    echo -e "  ✓ ${GREEN}Xray запущен${NC}"
  else
    echo -e "${RED}Xray не запустился! Лог:${NC}"
    journalctl -u xray -n 20 --no-pager
    exit 1
  fi
}

# ══════════════════════════════════════════════════
# УСТАНОВКА ПРОТОКОЛА
# ══════════════════════════════════════════════════
install_protocol() {
  clear
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════╗"
  echo "║        Xray — Добавить протокол            ║"
  echo "╚════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "${BOLD}Выбери протокол:${NC}"
  echo ""
  echo -e "  ${BOLD}1.${NC} Trojan + TLS"
  echo -e "  ${BOLD}2.${NC} VLESS + TLS"
  if [[ "${FIRST_INSTALL}" != "1" ]]; then
    echo -e "  ${BOLD}0.${NC} Пропустить (вернуться в меню)"
  fi
  echo ""
  read -rp "  Выбор: " PC

  DOMAIN="" EMAIL="" SERVER_IP="" PASSWORDS=()
  
  NETWORK="" LINK_PROTO=""

  case $PC in
    1|2)
      # ── выбор транспорта ──
      echo ""
      echo -e "  ${BOLD}Транспорт:${NC}"
      echo -e "  1. WS  (WebSocket поверх TLS)"
      echo -e "  2. TCP (низкий overhead)"
      read -rp "  Выбор [1]: " NT; NT=${NT:-1}
      [[ "$NT" == "2" ]] && NETWORK="tcp" || NETWORK="ws"

      echo ""
      read -rp "  Домен: " DOMAIN
      [[ -z "$DOMAIN" ]] && { echo -e "${RED}Домен пустой!${NC}"; return; }
      while true; do
        read -rp "  Email для Let's Encrypt (только латиница, например user@gmail.com): " EMAIL
        if [[ -z "$EMAIL" ]]; then
          echo -e "  ${RED}Email пустой!${NC}"
        elif [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
          echo -e "  ${RED}Некорректный email. Только латинские символы!${NC}"
        else
          break
        fi
      done

      ask_port
      [[ "$PC" == "1" ]] && ask_users "trojan" || ask_users "vless"

      echo ""
      echo -e "${YELLOW}  Получаю сертификат...${NC}"
      ask_tls_cert "$DOMAIN" "$EMAIL"
      echo -e "  ✓ Сертификат готов"

      echo -e "${YELLOW}  Записываю конфиг...${NC}"
      if [[ "$PC" == "1" ]]; then
        CLIENTS=$(make_clients_json "trojan")
        write_config_tls "trojan" "$DOMAIN" "$CLIENTS" "$NETWORK"
        LINK_PROTO="trojan-${NETWORK}"
      else
        CLIENTS=$(make_clients_json "vless")
        write_config_tls "vless" "$DOMAIN" "$CLIENTS" "$NETWORK"
        LINK_PROTO="vless-${NETWORK}"
      fi
      ;;



    0) [[ "${FIRST_INSTALL}" == "1" ]] && { echo -e "${RED}Сначала выбери протокол!${NC}"; sleep 1; install_protocol; return; } || return ;;
    *) echo -e "${RED}Неверный выбор${NC}"; sleep 1; return ;;
  esac

  echo -e "${YELLOW}  Перезапускаю Xray...${NC}"
  restart_xray

  print_links "$LINK_PROTO" "$DOMAIN" "$SERVER_IP"
  echo ""
  read -rp "  Enter..." _
}

# ══════════════════════════════════════════════════
# МЕНЮ ПОЛЬЗОВАТЕЛЕЙ
# ══════════════════════════════════════════════════
get_domain() {
  python3 -c "
import subprocess
try:
    r = subprocess.run(['/root/.acme.sh/acme.sh','--list'], capture_output=True, text=True)
    lines = [l for l in r.stdout.strip().split('\n') if l and not l.startswith('Main')]
    print(lines[0].split()[0])
except:
    print('')
" 2>/dev/null || true
}

count_users() {
  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
cl = c['inbounds'][0]['settings'].get('clients',[])
print(len(cl))
" 2>/dev/null || echo "0"
}

get_proto_tag() {
  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
print(c['inbounds'][0].get('tag','unknown'))
" 2>/dev/null || echo "unknown"
}

list_users() {
  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
clients = c['inbounds'][0]['settings'].get('clients',[])
for i,cl in enumerate(clients):
    key = cl.get('password', cl.get('id','?'))
    name = cl.get('email', '').replace('@xray','')
    print(f'{i+1}. {name}  [{key[:16]}...]')
" 2>/dev/null
}

add_user_menu() {
  local TAG=$(get_proto_tag)
  echo ""
  read -rp "  Имя пользователя (например: ivan): " USERNAME
  [[ -z "$USERNAME" ]] && USERNAME="user$(openssl rand -hex 2)"
  read -rp "  Пароль/UUID (Enter=авто): " PASS
  if [[ -z "$PASS" ]]; then
    if [[ "$TAG" == *"TROJAN"* ]]; then
      PASS=$(openssl rand -hex 16)
    else
      PASS=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    fi
    echo -e "  Авто: ${GREEN}$PASS${NC}"
  fi


  RESULT=$(python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
clients = c['inbounds'][0]['settings']['clients']
for cl in clients:
    key = cl.get('password', cl.get('id',''))
    if key == '$PASS':
        print('EXISTS'); exit()
tag = c['inbounds'][0].get('tag','')
if 'TROJAN' in tag:
    clients.append({'password':'$PASS','email':'$USERNAME@xray'})
else:
    clients.append({'id':'$PASS','email':'$USERNAME@xray'})
with open('$CONFIG','w') as f: json.dump(c,f,indent=2)
print('OK')
")

  [[ "$RESULT" == "EXISTS" ]] && { echo -e "  ${RED}Уже существует!${NC}"; return; }

  systemctl restart xray && sleep 1

  local DOMAIN=$(get_domain)
  local IP=$(get_server_ip)
  TAG=$(get_proto_tag)

  local LINK=""
  if [[ "$TAG" == *"TROJAN"* && "$TAG" == *"WS"* ]]; then
    LINK=$(make_link "trojan-ws" "$PASS" "$DOMAIN" "$IP")
  elif [[ "$TAG" == *"TROJAN"* ]]; then
    LINK=$(make_link "trojan-tcp" "$PASS" "$DOMAIN" "$IP")
  elif [[ "$TAG" == *"VLESS"* && "$TAG" == *"WS"* ]]; then
    LINK=$(make_link "vless-ws" "$PASS" "$DOMAIN" "$IP")
  elif [[ "$TAG" == *"VLESS"* && "$TAG" == *"TCP"* ]]; then
    LINK=$(make_link "vless-tcp" "$PASS" "$DOMAIN" "$IP")
  else
    echo -e "  ${YELLOW}Пользователь добавлен. Ссылку сгенерируй через меню 'Показать все ссылки'${NC}"
    return
  fi

  echo ""
  echo -e "${CYAN}══════════════════════════════════════${NC}"
  echo -e "${GREEN}  Добавлен!${NC}"
  echo "  $LINK"
  echo ""
  qrencode -t ANSIUTF8 "$LINK"
  echo -e "${CYAN}══════════════════════════════════════${NC}"
  { echo "=== ${PASS:0:8} ==="; echo "ССЫЛКА: $LINK"; echo ""; } >> "$OUTFILE"
}

remove_user_menu() {
  echo ""
  echo -e "${BOLD}  Пользователи:${NC}"
  list_users
  echo ""
  read -rp "  Номер для удаления: " NUM
  RESULT=$(python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
clients = c['inbounds'][0]['settings']['clients']
idx=int('$NUM')-1
if idx<0 or idx>=len(clients): print('ERROR'); exit()
removed=clients.pop(idx)
with open('$CONFIG','w') as f: json.dump(c,f,indent=2)
print(removed.get('password',removed.get('id','?')))
")
  if [[ "$RESULT" == "ERROR" ]]; then
    echo -e "  ${RED}Неверный номер!${NC}"
  else
    systemctl restart xray && sleep 1
    echo -e "  ${GREEN}Удалён: $RESULT${NC}"
  fi
}

get_link_for_user() {
  local PASS=$1 DOMAIN=$2 IP=$3 TAG=$4
  # читаем порт из конфига
  XRAY_PORT=$(python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
print(c['inbounds'][0].get('port', 443))
" 2>/dev/null || echo "443")
  if [[ "$TAG" == *"TROJAN"* && "$TAG" == *"WS"* ]]; then
    make_link "trojan-ws" "$PASS" "$DOMAIN" "$IP"
  elif [[ "$TAG" == *"TROJAN"* ]]; then
    make_link "trojan-tcp" "$PASS" "$DOMAIN" "$IP"
  elif [[ "$TAG" == *"VLESS"* && "$TAG" == *"WS"* ]]; then
    make_link "vless-ws" "$PASS" "$DOMAIN" "$IP"
  elif [[ "$TAG" == *"VLESS"* && "$TAG" == *"TCP"* ]]; then
    make_link "vless-tcp" "$PASS" "$DOMAIN" "$IP"

  fi
}

show_user_link() {
  local DOMAIN=$(get_domain)
  local IP=$(get_server_ip)
  local TAG=$(get_proto_tag)
  echo ""
  echo -e "${BOLD}  Пользователи:${NC}"
  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
clients = c['inbounds'][0]['settings'].get('clients',[])
for i,cl in enumerate(clients):
    key = cl.get('password', cl.get('id','?'))
    name = cl.get('email', key[:8])
    print(f'{i+1}. {name}  [{key[:12]}...]')
" 2>/dev/null
  echo ""
  read -rp "  Номер пользователя: " NUM
  local PASS
  PASS=$(python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
clients = c['inbounds'][0]['settings'].get('clients',[])
idx=int('$NUM')-1
if 0<=idx<len(clients):
    cl=clients[idx]
    print(cl.get('password',cl.get('id','')))
" 2>/dev/null)
  [[ -z "$PASS" ]] && { echo -e "  ${RED}Неверный номер${NC}"; return; }
  local LINK
  LINK=$(get_link_for_user "$PASS" "$DOMAIN" "$IP" "$TAG")
  if [[ -n "$LINK" ]]; then
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo "  $LINK"
    echo ""
    qrencode -t ANSIUTF8 "$LINK"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
  else
    echo -e "  ${RED}Не удалось сгенерировать ссылку${NC}"
  fi
}

show_all_links() {
  local DOMAIN=$(get_domain)
  local IP=$(get_server_ip)
  local TAG=$(get_proto_tag)
  echo ""
  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
clients = c['inbounds'][0]['settings'].get('clients',[])
for cl in clients:
    key = cl.get('password', cl.get('id','?'))
    name = cl.get('email', key[:8])
    print(f'{key}|{name}')
" 2>/dev/null | while IFS='|' read -r PASS NAME; do
    local LINK
    LINK=$(get_link_for_user "$PASS" "$DOMAIN" "$IP" "$TAG")
    if [[ -n "$LINK" ]]; then
      echo ""
      echo -e "${BOLD}  $NAME${NC}"
      echo "  $LINK"
      echo ""
      qrencode -t ANSIUTF8 "$LINK"
      echo "  ──────────────────────────────────────"
    fi
  done
}


# ══════════════════════════════════════════════════
# WARP
# ══════════════════════════════════════════════════
install_warp() {
  echo ""
  echo -e "${YELLOW}  Устанавливаю Cloudflare WARP...${NC}"

  # установка warp-cli
  if ! command -v warp-cli &>/dev/null; then
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main"       > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -qq
    apt-get install -y -qq cloudflare-warp
    echo -e "  ✓ WARP установлен"
  else
    echo -e "  WARP уже установлен"
  fi

  # регистрация и подключение
  warp-cli --accept-tos register 2>/dev/null || true
  warp-cli --accept-tos set-mode proxy 2>/dev/null || true
  warp-cli --accept-tos connect 2>/dev/null || true
  sleep 3

  STATUS=$(warp-cli status 2>/dev/null | grep -i "connected" || true)
  if [[ -n "$STATUS" ]]; then
    echo -e "  ✓ ${GREEN}WARP подключён${NC}"
  else
    echo -e "  ${YELLOW}WARP может ещё подключаться, проверь: warp-cli status${NC}"
  fi
}

warp_outbound_add() {
  # проверяем что WARP запущен
  if ! command -v warp-cli &>/dev/null; then
    echo ""
    echo -e "  ${RED}WARP не установлен.${NC}"
    read -rp "  Установить сейчас? [y/N]: " YN
    [[ "$YN" =~ ^[Yy]$ ]] || return
    install_warp
  fi

  # WARP socks5 proxy слушает на 127.0.0.1:40000
  WARP_PORT="40000"

  # проверяем уже есть ли warp outbound
  HAS_WARP=$(python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
tags = [o.get('tag','') for o in c.get('outbounds',[])]
print('yes' if 'WARP' in tags else 'no')
" 2>/dev/null || echo "no")

  if [[ "$HAS_WARP" == "yes" ]]; then
    echo -e "  ${YELLOW}WARP outbound уже добавлен в конфиг${NC}"
    echo ""
    echo -e "  ${BOLD}Что сделать?${NC}"
    echo -e "  1. Роутить весь трафик через WARP"
    echo -e "  2. Роутить только определённые домены через WARP"
    echo -e "  3. Удалить WARP outbound"
    echo -e "  0. Назад"
    read -rp "  Выбор: " WC
    case $WC in
      1) warp_route_all ;;
      2) warp_route_domains ;;
      3) warp_outbound_remove ;;
    esac
    return
  fi

  echo ""
  echo -e "${YELLOW}  Добавляю WARP outbound в конфиг...${NC}"

  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)

# добавляем outbound WARP (socks5 -> warp-cli proxy)
warp_ob = {
  'tag': 'WARP',
  'protocol': 'socks',
  'settings': {
    'servers': [{
      'address': '127.0.0.1',
      'port': $WARP_PORT
    }]
  }
}
c['outbounds'].append(warp_ob)

with open('$CONFIG', 'w') as f: json.dump(c, f, indent=2)
print('OK')
"
  echo -e "  ✓ WARP outbound добавлен (127.0.0.1:$WARP_PORT)"
  echo ""
  echo -e "  ${BOLD}Теперь выбери роутинг:${NC}"
  echo -e "  1. Весь трафик через WARP"
  echo -e "  2. Только определённые домены через WARP"
  echo -e "  0. Пропустить"
  read -rp "  Выбор: " WC
  case $WC in
    1) warp_route_all ;;
    2) warp_route_domains ;;
  esac

  systemctl restart xray && sleep 1
  echo -e "  ✓ ${GREEN}Xray перезапущен с WARP${NC}"
}

warp_route_all() {
  echo ""
  echo -e "${YELLOW}  Направляю весь трафик через WARP...${NC}"
  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)

rules = c.setdefault('routing', {}).setdefault('rules', [])
# удаляем старое правило WARP если есть
rules = [r for r in rules if r.get('outboundTag') != 'WARP']
# добавляем в начало — весь трафик на WARP кроме заблокированного
rules.insert(0, {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'WARP'})
c['routing']['rules'] = rules
with open('$CONFIG', 'w') as f: json.dump(c, f, indent=2)
print('OK')
"
  echo -e "  ✓ Весь трафик → WARP"
}

warp_route_domains() {
  echo ""
  read -rp "  Домены через WARP (через запятую, например: openai.com,netflix.com): " DOMAINS_INPUT
  [[ -z "$DOMAINS_INPUT" ]] && return

  IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS_INPUT"
  DOMAINS_JSON=$(python3 -c "
import json, sys
domains = [d.strip() for d in '$DOMAINS_INPUT'.split(',')]
print(json.dumps(domains))
")

  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
rules = c.setdefault('routing', {}).setdefault('rules', [])
rules = [r for r in rules if r.get('outboundTag') != 'WARP']
rules.insert(0, {'type': 'field', 'domain': $DOMAINS_JSON, 'outboundTag': 'WARP'})
c['routing']['rules'] = rules
with open('$CONFIG', 'w') as f: json.dump(c, f, indent=2)
print('OK')
"
  echo -e "  ✓ Домены направлены через WARP: $DOMAINS_INPUT"
}

warp_outbound_remove() {
  echo ""
  echo -e "${YELLOW}  Удаляю WARP из конфига...${NC}"
  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
c['outbounds'] = [o for o in c.get('outbounds',[]) if o.get('tag') != 'WARP']
rules = c.get('routing',{}).get('rules',[])
c['routing']['rules'] = [r for r in rules if r.get('outboundTag') != 'WARP']
with open('$CONFIG','w') as f: json.dump(c,f,indent=2)
print('OK')
"
  systemctl restart xray && sleep 1
  echo -e "  ✓ WARP удалён из конфига"
}

warp_menu() {
  clear
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════╗"
  echo "║              Xray — WARP                   ║"
  echo "╚════════════════════════════════════════════╝"
  echo -e "${NC}"

  HAS_WARP=$(python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
tags = [o.get('tag','') for o in c.get('outbounds',[])]
print('✓ подключён' if 'WARP' in tags else '✗ не настроен')
" 2>/dev/null || echo "✗ не настроен")

  WARP_STATUS=$(warp-cli status 2>/dev/null | head -1 || echo "не установлен")

  echo -e "  WARP в конфиге: ${GREEN}$HAS_WARP${NC}"
  echo -e "  WARP статус:    ${GREEN}$WARP_STATUS${NC}"
  echo ""
  echo -e "  ${BOLD}1.${NC} Установить WARP и добавить outbound"
  echo -e "  ${BOLD}2.${NC} Роутить весь трафик через WARP"
  echo -e "  ${BOLD}3.${NC} Роутить домены через WARP"
  echo -e "  ${BOLD}4.${NC} Удалить WARP из конфига"
  echo -e "  ${BOLD}5.${NC} Статус WARP"
  echo -e "  ${BOLD}0.${NC} Назад"
  echo ""
  read -rp "  Выбор: " WM

  case $WM in
    1) warp_outbound_add ;;
    2) warp_route_all;    systemctl restart xray; sleep 1; echo -e "  ✓ ${GREEN}Применено${NC}" ;;
    3) warp_route_domains; systemctl restart xray; sleep 1; echo -e "  ✓ ${GREEN}Применено${NC}" ;;
    4) warp_outbound_remove ;;
    5) echo ""; warp-cli status 2>/dev/null || echo "WARP не установлен"; echo "" ;;
    0) return ;;
  esac
  echo ""
  read -rp "  Enter..." _
}


# ══════════════════════════════════════════════════
# MULTIHOP
# ══════════════════════════════════════════════════
multihop_menu() {
  clear
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════╗"
  echo "║          Xray — Multihop (цепочка)         ║"
  echo "╚════════════════════════════════════════════╝"
  echo -e "${NC}"

  # текущий статус
  HAS_MULTIHOP=$(python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
tags = [o.get('tag','') for o in c.get('outbounds',[])]
print('✓ настроен' if 'MULTIHOP' in tags else '✗ не настроен')
" 2>/dev/null || echo "✗ не настроен")

  echo -e "  Статус multihop: ${GREEN}$HAS_MULTIHOP${NC}"
  echo ""
  echo -e "  ${BOLD}1.${NC} Настроить multihop (добавить Сервер 2)"
  echo -e "  ${BOLD}2.${NC} Показать данные для подключения цепочки"
  echo -e "  ${BOLD}3.${NC} Удалить multihop"
  echo -e "  ${BOLD}0.${NC} Назад"
  echo ""
  read -rp "  Выбор: " MC

  case $MC in
    1) multihop_setup ;;
    2) multihop_show_data ;;
    3) multihop_remove ;;
    0) return ;;
  esac
  echo ""
  read -rp "  Enter..." _
}

multihop_setup() {
  echo ""
  echo -e "${BOLD}  Данные Сервера 2 (куда форвардить трафик):${NC}"
  echo ""
  read -rp "  IP или домен Сервера 2: " S2_HOST
  [[ -z "$S2_HOST" ]] && { echo -e "  ${RED}Не может быть пустым!${NC}"; return; }

  read -rp "  Порт [443]: " S2_PORT
  S2_PORT=${S2_PORT:-443}

  echo ""
  echo -e "  Протокол Сервера 2:"
  echo -e "  1. Trojan + WS + TLS"
  echo -e "  2. Trojan + TCP + TLS"
  echo -e "  3. VLESS + WS + TLS"
  echo -e "  4. VLESS + TCP + TLS"
  read -rp "  Выбор [1]: " S2_PROTO_NUM
  S2_PROTO_NUM=${S2_PROTO_NUM:-1}

  echo ""
  read -rp "  Пароль/UUID пользователя на Сервере 2: " S2_PASS
  [[ -z "$S2_PASS" ]] && { echo -e "  ${RED}Не может быть пустым!${NC}"; return; }

  # SNI = домен сервера 2 (для TLS это просто хост)
  S2_SNI="$S2_HOST"

  # путь WS только если выбран WS транспорт
  S2_WS_PATH="/ws"
  if [[ "$S2_PROTO_NUM" == "1" || "$S2_PROTO_NUM" == "3" ]]; then
    read -rp "  WS путь [/ws]: " S2_WS_PATH
    S2_WS_PATH=${S2_WS_PATH:-/ws}
  fi

  echo ""
  echo -e "${YELLOW}  Добавляю multihop outbound...${NC}"

  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)

proto_num = '$S2_PROTO_NUM'
s2_host    = '$S2_HOST'
s2_port    = int('$S2_PORT')
s2_pass    = '$S2_PASS'
s2_sni     = '$S2_SNI'
s2_ws_path = '$S2_WS_PATH'

# определяем протокол и транспорт
if proto_num in ('1','2'):
    proto = 'trojan'
    network = 'ws' if proto_num == '1' else 'tcp'
    client_settings = {'servers': [{'address': s2_host, 'port': s2_port, 'password': s2_pass}]}
else:
    proto = 'vless'
    network = 'ws' if proto_num == '3' else 'tcp'
    client_settings = {'vnext': [{'address': s2_host, 'port': s2_port, 'users': [{'id': s2_pass, 'encryption': 'none'}]}]}

# stream settings
stream = {
    'network': network,
    'security': 'tls',
    'tlsSettings': {'serverName': s2_sni, 'allowInsecure': False}
}
if network == 'ws':
    stream['wsSettings'] = {'path': s2_ws_path, 'headers': {'Host': s2_sni}}

# удаляем старый MULTIHOP если есть
outbounds = [o for o in c.get('outbounds',[]) if o.get('tag') != 'MULTIHOP']

# добавляем новый
outbounds.insert(0, {
    'tag': 'MULTIHOP',
    'protocol': proto,
    'settings': client_settings,
    'streamSettings': stream
})
c['outbounds'] = outbounds

# роутинг — весь трафик через MULTIHOP
rules = c.setdefault('routing', {}).setdefault('rules', [])
rules = [r for r in rules if r.get('outboundTag') not in ('MULTIHOP', 'DIRECT')]
# блокировки оставляем, добавляем дефолтный роут на MULTIHOP
rules.append({'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'MULTIHOP'})
c['routing']['rules'] = rules

with open('$CONFIG', 'w') as f: json.dump(c, f, indent=2)
print('OK')
"

  # роутинг
  echo ""
  echo -e "  ${BOLD}Роутинг трафика:${NC}"
  echo -e "  1. Весь трафик через Сервер 2"
  echo -e "  2. РФ домены/IP через Сервер 1 (прямо), остальное через Сервер 2 (рекомендуется)"
  read -rp "  Выбор [2]: " ROUTE_MODE
  ROUTE_MODE=${ROUTE_MODE:-2}

  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)

route_mode = '$ROUTE_MODE'
rules = c.setdefault('routing', {}).setdefault('rules', [])

# убираем старые правила MULTIHOP и DIRECT (кроме блокировок)
rules = [r for r in rules if r.get('outboundTag') not in ('MULTIHOP', 'DIRECT')]

if route_mode == '2':
    # РФ IP и домены — напрямую через Сервер 1
    rules.append({
        'type': 'field',
        'ip': ['geoip:ru', 'geoip:private'],
        'outboundTag': 'DIRECT'
    })
    rules.append({
        'type': 'field',
        'domain': ['geosite:ru', 'geosite:category-ru'],
        'outboundTag': 'DIRECT'
    })
    # всё остальное — через Сервер 2
    rules.append({
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': 'MULTIHOP'
    })
else:
    # весь трафик через Сервер 2
    rules.append({
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': 'MULTIHOP'
    })

c['routing']['rules'] = rules
with open('$CONFIG', 'w') as f: json.dump(c, f, indent=2)
print('OK')
"

  systemctl restart xray && sleep 1
  if systemctl is-active xray | grep -q active; then
    if [[ "$ROUTE_MODE" == "2" ]]; then
      echo -e "  ✓ ${GREEN}Multihop настроен!${NC}"
      echo -e "  ${CYAN}  РФ трафик → Сервер 1 (прямо)${NC}"
      echo -e "  ${CYAN}  Остальное → Сервер 2 ($S2_HOST)${NC}"
    else
      echo -e "  ✓ ${GREEN}Multihop настроен! Весь трафик → Сервер 2 ($S2_HOST)${NC}"
    fi
  else
    echo -e "  ${RED}Xray не запустился, проверь данные:${NC}"
    journalctl -u xray -n 10 --no-pager
  fi
}

multihop_show_data() {
  echo ""
  echo -e "${BOLD}  Выбери пользователя для multihop:${NC}"
  echo ""
  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
clients = c['inbounds'][0]['settings'].get('clients',[])
for i,cl in enumerate(clients):
    key = cl.get('password', cl.get('id','?'))
    name = cl.get('email','').replace('@xray','')
    print(f'{i+1}. {name}  [{key[:16]}...]')
" 2>/dev/null
  echo ""
  read -rp "  Номер пользователя: " NUM

  DATA=$(python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
clients = c['inbounds'][0]['settings'].get('clients',[])
idx = int('$NUM') - 1
if idx < 0 or idx >= len(clients):
    print('ERROR'); exit()
cl = clients[idx]
tag  = c['inbounds'][0].get('tag','')
port = c['inbounds'][0].get('port', 443)
ss   = c['inbounds'][0].get('streamSettings',{})
net  = ss.get('network','ws')
key  = cl.get('password', cl.get('id','?'))
name = cl.get('email','').replace('@xray','')

if 'TROJAN' in tag:
    proto = 'trojan'
else:
    proto = 'vless'

if 'WS' in tag:
    transport = 'ws'
elif 'TCP' in tag:
    transport = 'tcp'
else:
    transport = net

print(f'NAME={name}')
print(f'PROTO={proto}')
print(f'TRANSPORT={transport}')
print(f'PORT={port}')
print(f'PASS={key}')
" 2>/dev/null)

  if echo "$DATA" | grep -q "ERROR"; then
    echo -e "  ${RED}Неверный номер!${NC}"
    return
  fi

  eval "$DATA"

  # получаем домен и IP
  local DOMAIN=$(get_domain)
  local IP=$(get_server_ip)
  local HOST="${DOMAIN:-$IP}"

  # определяем номер протокола для multihop меню
  if [[ "$PROTO" == "trojan" && "$TRANSPORT" == "ws" ]]; then
    PROTO_NUM="1 (Trojan + WS + TLS)"
  elif [[ "$PROTO" == "trojan" && "$TRANSPORT" == "tcp" ]]; then
    PROTO_NUM="2 (Trojan + TCP + TLS)"
  elif [[ "$PROTO" == "vless" && "$TRANSPORT" == "ws" ]]; then
    PROTO_NUM="3 (VLESS + WS + TLS)"
  else
    PROTO_NUM="4 (VLESS + TCP + TLS)"
  fi

  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Данные для настройки Multihop на Сервере 1:${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Пользователь:  ${BOLD}$NAME${NC}"
  echo -e "  IP / Домен:    ${GREEN}$HOST${NC}"
  echo -e "  Порт:          ${GREEN}$PORT${NC}"
  echo -e "  Протокол:      ${GREEN}$PROTO_NUM${NC}"
  echo -e "  Пароль/UUID:   ${GREEN}$PASS${NC}"
  if [[ "$TRANSPORT" == "ws" ]]; then
    local WS_PATH
    WS_PATH=$(python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
ws = c['inbounds'][0].get('streamSettings',{}).get('wsSettings',{})
print(ws.get('path','/ws'))
" 2>/dev/null || echo "/ws")
    echo -e "  WS путь:       ${GREEN}$WS_PATH${NC}"
  fi
  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Вводи эти данные в меню ${BOLD}Multihop → Настроить${NC} на Сервере 1"
}

multihop_remove() {
  echo ""
  echo -e "${YELLOW}  Удаляю multihop...${NC}"
  python3 -c "
import json
with open('$CONFIG') as f: c=json.load(f)
c['outbounds'] = [o for o in c.get('outbounds',[]) if o.get('tag') != 'MULTIHOP']
rules = c.get('routing',{}).get('rules',[])
c['routing']['rules'] = [r for r in rules if r.get('outboundTag') != 'MULTIHOP']
with open('$CONFIG','w') as f: json.dump(c,f,indent=2)
print('OK')
"
  systemctl restart xray && sleep 1
  echo -e "  ✓ ${GREEN}Multihop удалён, прямое подключение восстановлено${NC}"
}

menu() {
  set +e
  local DOMAIN=$(get_domain)
  [[ -z "$DOMAIN" ]] && DOMAIN="(не определён)"

  while true; do
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════╗"
    echo "║           Xray — Панель управления         ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Домен:         ${GREEN}$DOMAIN${NC}"
    echo -e "  Протокол:      ${GREEN}$(get_proto_tag)${NC}"
    echo -e "  Пользователей: ${GREEN}$(count_users)${NC}"
    echo -e "  Статус Xray:   ${GREEN}$(systemctl is-active xray)${NC}"
    echo ""
    echo -e "  ${BOLD}── Пользователи ──${NC}"
    echo -e "  ${BOLD}1.${NC} Показать всех"
    echo -e "  ${BOLD}2.${NC} Добавить пользователя"
    echo -e "  ${BOLD}3.${NC} Удалить пользователя"
    echo -e "  ${BOLD}4.${NC} Ссылка и QR одного пользователя"
    echo -e "  ${BOLD}5.${NC} Показать все ссылки и QR"
    echo ""
    echo -e "  ${BOLD}── Протокол ──${NC}"
    echo -e "  ${BOLD}6.${NC} Установить или переустановить протокол"
    echo ""
    echo -e "  ${BOLD}── Дополнительно ──${NC}"
    echo -e "  ${BOLD}7.${NC} WARP (обход блокировок)"
    echo -e "  ${BOLD}8.${NC} Multihop (цепочка серверов)"
    echo ""
    echo -e "  ${BOLD}── Система ──${NC}"
    echo -e "  ${BOLD}9.${NC} Перезапустить Xray"
    echo -e "  ${BOLD}10.${NC} Статус и логи"
    echo -e "  ${BOLD}11.${NC} Обновить скрипт"
    echo -e "  ${BOLD}0.${NC} Выйти"
    echo ""
    read -rp "  Выбор: " CHOICE

    case $CHOICE in
      1) echo ""; list_users; echo ""; read -rp "  Enter..." _ ;;
      2) add_user_menu; echo ""; read -rp "  Enter..." _ ;;
      3) remove_user_menu; echo ""; read -rp "  Enter..." _ ;;
      4) show_user_link; echo ""; read -rp "  Enter..." _ ;;
      5) show_all_links; echo ""; read -rp "  Enter..." _ ;;
      6) install_protocol ;;
      7) warp_menu ;;
      8) multihop_menu ;;
      9) systemctl restart xray; echo -e "  ${GREEN}✓ Перезапущен${NC}"; sleep 1 ;;
      10)
        echo ""
        systemctl status xray --no-pager
        echo ""
        journalctl -u xray -n 20 --no-pager
        echo ""
        read -rp "  Enter..." _
        ;;
      11)
        curl -sSL "$SCRIPT_URL" -o /root/xray.sh
        chmod +x /root/xray.sh
        echo -e "  ${GREEN}✓ Скрипт обновлён${NC}"
        sleep 1
        exec bash /root/xray.sh
        ;;
      0) echo "Выход."; exit 0 ;;
      *) echo -e "  ${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
  done
}

# ══════════════════════════════════════════════════
# ТОЧКА ВХОДА
# ══════════════════════════════════════════════════
if [[ -f "$CONFIG" ]]; then
  menu
  exit 0
fi

# ── Первая установка ──
clear
echo -e "${CYAN}"
echo "╔════════════════════════════════════════════╗"
echo "║        Xray — Первая установка             ║"
echo "╚════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}[1/4] Подготовка системы...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y -qq curl wget unzip openssl qrencode ca-certificates ufw socat cron python3
timedatectl set-ntp true 2>/dev/null || true
echo -e "  ✓ Готово"

echo -e "${YELLOW}[2/4] Настройка UFW...${NC}"
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow 22/tcp  >/dev/null 2>&1
ufw allow 80/tcp  >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
echo -e "  ✓ SSH(22), HTTP(80), HTTPS(443) открыты"

echo -e "${YELLOW}[3/4] Устанавливаю Xray-core...${NC}"
if command -v xray &>/dev/null; then
  echo -e "  Уже установлен: $(xray version 2>/dev/null | head -1)"
else
  bash -c "$(curl -sSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  echo -e "  ✓ Xray установлен"
fi

echo -e "${YELLOW}[4/4] Настройка прав сервиса...${NC}"
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/override.conf << 'EOF'
[Service]
User=root
EOF
systemctl daemon-reload
echo -e "  ✓ Готово"

ln -sf /root/xray.sh /usr/local/bin/xray-manage 2>/dev/null || true
chmod +x /usr/local/bin/xray-manage 2>/dev/null || true

echo ""
echo -e "${GREEN}  Система готова! Выбери протокол:${NC}"
FIRST_INSTALL=1
install_protocol

echo ""
echo -e "${GREEN}  Для управления в любой момент: ${CYAN}xray-manage${NC}"
echo ""
