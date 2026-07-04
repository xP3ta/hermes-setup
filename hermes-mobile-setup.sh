#!/bin/sh
# Hermes Console — setup movil todo-en-uno.
# Alojado en el repo publico xP3ta/hermes-setup para que la app entregue un
# comando CORTO:
#   curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh
# Instala Hermes (si falta), arranca gateway + dashboard + bridge y pinta el QR.
# El programa del bridge se descarga del MISMO repo (una sola fuente de verdad).
# FUENTE: este archivo vive en la app (scripts/hermes-mobile-setup.sh); el repo
# hermes-setup aloja una copia que hay que actualizar junto con el asset del
# bridge (assets/bridge/hermes_bridge.py).
set -e

# URL RAW del repo (rama/tag). Debe apuntar al repo PUBLICO donde vive esto.
REPO_RAW="${HERMES_REPO_RAW:-https://raw.githubusercontent.com/xP3ta/hermes-setup/main}"

HH="${HERMES_HOME:-$HOME/.hermes}"
mkdir -p "$HH"

# 0a) gestor de servicios de usuario ANTES de systemctl --user
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
loginctl enable-linger "$(id -un)" 2>/dev/null || true
i=0; while [ $i -lt 10 ]; do [ -S "$XDG_RUNTIME_DIR/bus" ] && break; sleep 1; i=$((i+1)); done

# 0) Hermes si falta (sin asistente, sin navegador)
HB="$HH/hermes-agent/venv/bin/hermes"
if [ ! -x "$HB" ] && ! command -v hermes >/dev/null 2>&1; then
  echo "Instalando Hermes Agent..."
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --non-interactive --skip-browser
fi
[ -x "$HB" ] || HB="$(command -v hermes 2>/dev/null || echo hermes)"

# 1) token
KEY="$(grep -E '^API_SERVER_KEY=' "$HH/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
[ -n "$KEY" ] || { KEY="$(openssl rand -hex 32)"; printf 'API_SERVER_KEY=%s\n' "$KEY" >> "$HH/.env"; }

# 2) host alcanzable, por orden de preferencia:
#    mesh (Tailscale via CLI; NetBird/Tailscale/etc. via rango CGNAT
#    100.64.0.0/10) > LAN privada (RFC1918, cubre ZeroTier y VPN clasicas) >
#    IP publica directa (VPS pelado — funciona, pero se avisa de la
#    exposicion) > loopback (ultimo recurso, solo util en el propio equipo).
IPS="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.')"
HOST="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$HOST" ] || HOST="$(echo "$IPS" | grep -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' | head -1)"
[ -n "$HOST" ] || HOST="$(echo "$IPS" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -1)"
PUBLIC=""
if [ -z "$HOST" ]; then
  HOST="$(echo "$IPS" | head -1)"
  if [ -n "$HOST" ]; then PUBLIC=1; else HOST="127.0.0.1"; fi
fi

VP="$HH/hermes-agent/venv/bin/python3"; [ -x "$VP" ] || VP="$(command -v python3)"
mkdir -p "$HOME/.config/systemd/user"

# 3) gateway 8642
if ! (ss -tlnH 2>/dev/null | grep -q ':8642 '); then
  printf '[Unit]\nDescription=Hermes Gateway API\nAfter=network.target\n[Service]\nEnvironment=API_SERVER_HOST=0.0.0.0\nEnvironment=API_SERVER_PORT=8642\nExecStart=%s gateway run\nWorkingDirectory=%s\nRestart=on-failure\n[Install]\nWantedBy=default.target\n' "$HB" "$HH" > "$HOME/.config/systemd/user/hermes-gateway.service"
  systemctl --user daemon-reload; systemctl --user enable --now hermes-gateway && sleep 4 && echo "Gateway 8642 OK" || echo "AVISO gateway"
fi

# 3b) dashboard 9119 (solo crear; se arranca al fijarle la clave via bridge)
if ! (ss -tlnH 2>/dev/null | grep -q ':9119 '); then
  printf '[Unit]\nDescription=Hermes Dashboard\nAfter=network.target\n[Service]\nExecStart=%s dashboard --host 0.0.0.0 --port 9119 --no-open\nWorkingDirectory=%s\nRestart=on-failure\n[Install]\nWantedBy=default.target\n' "$HB" "$HH" > "$HOME/.config/systemd/user/hermes-dashboard.service"
  systemctl --user daemon-reload; systemctl --user enable hermes-dashboard 2>/dev/null || true
fi

# 4) bridge: descargar del repo (misma fuente de verdad que la app) + flag
curl -fsSL "$REPO_RAW/hermes_bridge.py" -o "$HH/hermes_bridge.py"
printf 'BRIDGE_HOST=0.0.0.0\nBRIDGE_PORT=9131\nBRIDGE_SCOPES=read,memory,soul,skills,cron,config,command\nBRIDGE_READ_ONLY=false\nBRIDGE_TOKEN=%s\n' "$KEY" > "$HH/bridge.env"
printf '[Unit]\nDescription=Hermes Mobile Bridge\nAfter=network.target\n[Service]\nEnvironmentFile=%s/bridge.env\nExecStart=%s %s/hermes_bridge.py --i-know-what-im-doing\nWorkingDirectory=%s\nRestart=on-failure\n[Install]\nWantedBy=default.target\n' "$HH" "$VP" "$HH" "$HH" > "$HOME/.config/systemd/user/hermes-bridge.service"
# enable + restart (NO `enable --now`): --now no reinicia un servicio YA
# activo, y este script tambien es el camino de ACTUALIZACION del bridge —
# sin restart, el proceso viejo seguia sirviendo la version anterior.
systemctl --user daemon-reload; systemctl --user enable hermes-bridge >/dev/null 2>&1; systemctl --user restart hermes-bridge; sleep 3
systemctl --user is-active hermes-bridge >/dev/null && echo "Bridge 9131 OK" || echo "AVISO bridge"

# 5) dashboard: fijar clave inicial via bridge para que bindee (la app la rota)
DASH=""
if ! (ss -tlnH 2>/dev/null | grep -q ':9119 '); then
  curl -sS -m15 -X POST "http://127.0.0.1:9131/bridge/dashboard/credentials" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "{\"password\":\"$(openssl rand -hex 16)\"}" >/dev/null 2>&1 || true
  i=0; while [ $i -lt 20 ]; do ss -tlnH 2>/dev/null | grep -q ':9119 ' && break; sleep 2; i=$((i+1)); done
fi
ss -tlnH 2>/dev/null | grep -q ':9119 ' && DASH="&dashboard=http://$HOST:9119"

# 6) QR + enlace
LINK="hermes://pair?host=$HOST&port=8642&token=$KEY$DASH"
echo ""; echo "== ESCANEA ESTE QR CON LA APP (o copia el enlace) =="; echo ""
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 "$LINK"
else
  UV="$HH/bin/uv"; [ -x "$UV" ] || UV="$(command -v uv 2>/dev/null || echo uv)"
  "$UV" run --with qrcode python -c "import qrcode,sys;q=qrcode.QRCode(border=1);q.add_data(sys.argv[1]);q.make();q.print_ascii(invert=True)" "$LINK" 2>/dev/null || echo "(instala qrencode para ver el QR)"
fi
echo ""; echo "Enlace: $LINK"
if [ -n "$PUBLIC" ]; then
  echo ""
  echo "ATENCION: no hay red privada (VPN mesh o LAN); el enlace usa la IP publica $HOST."
  echo "Gateway (8642), dashboard (9119) y bridge (9131) quedan expuestos a internet,"
  echo "protegidos solo por el token. Recomendado: Tailscale/NetBird o un firewall que"
  echo "limite esos puertos a tus dispositivos."
fi
if [ "$HOST" = "127.0.0.1" ]; then
  echo ""
  echo "ATENCION: no se encontro ninguna IP de red; el enlace solo funciona desde este equipo."
fi
