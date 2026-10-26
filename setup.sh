#!/usr/bin/env bash
set -euo pipefail

XRAY_VERSION="v26.10.21"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="${XRAY_CONF_DIR}/config.json"
XRAY_LOG="/var/log/xray.log"

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

# ---------- 1. Dependencies ----------
echo "[1/6] Checking dependencies..."
for pkg in curl unzip; do
  command -v "$pkg" >/dev/null 2>&1 || { apt-get update -y && apt-get install -y "$pkg"; }
done
command -v nginx >/dev/null 2>&1 || { apt-get update -y && apt-get install -y nginx; }

# ---------- 2. Install Xray ----------
echo "[2/6] Installing Xray ${XRAY_VERSION}..."
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

curl -L "$XRAY_URL" --output xray.zip
unzip -o xray.zip
install -m 755 xray /usr/local/bin/xray

# Optional geo files (Xray looks for these next to the binary or in its asset dir)
mkdir -p /usr/local/share/xray
install -m 644 geoip.dat geosite.dat /usr/local/share/xray/ 2>/dev/null || true

# ---------- 3. Xray config ----------
echo "[3/6] Generating UUID and Xray config..."
mkdir -p "$XRAY_CONF_DIR"
UUID="$(xray uuid)"

cat > "$XRAY_CONF" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "port": 10001,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless" } }
    },
    {
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "port": 10002,
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "$UUID" } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess" } }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF

xray run -test -c "$XRAY_CONF"

# ---------- 4. Nginx: remove defaults, add config ----------
echo "[4/6] Configuring nginx..."
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

cat > /etc/nginx/sites-enabled/xray.conf << 'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name _;

    # VLESS over WebSocket -> 127.0.0.1:10001
    location /vless {
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    # VMess over WebSocket -> 127.0.0.1:10002
    location /vmess {
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    # Everything else -> local web app on 8080
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

nginx -t

# ---------- 5. Start services ----------
echo "[5/6] Starting services..."

# Restart nginx cleanly (handles the case where it's already running)
service nginx restart || service nginx start

# Stop any previous Xray instance, then start with --config
pkill -x xray 2>/dev/null || true
sleep 1
nohup xray --config "$XRAY_CONF" > "$XRAY_LOG" 2>&1 &
sleep 2

# ---------- 6. Verify ----------
echo "[6/6] Verifying..."
ss -tulnp | grep -E 'xray|nginx' || true
echo
echo "curl /vless -> HTTP $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/vless)  (400 = proxy path works)"
echo "curl /vmess -> HTTP $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/vmess)  (400 = proxy path works)"
echo "curl /      -> HTTP $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/)  (502 = nothing on port 8080 yet)"

echo
echo "=============================================="
echo " Setup complete"
echo " UUID : $UUID"
echo " VLESS: ws, port 80, path /vless, tls off"
echo " VMess: ws, port 80, path /vmess, tls off"
echo " Xray log: $XRAY_LOG"
echo "=============================================="
