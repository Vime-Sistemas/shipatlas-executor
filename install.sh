#!/usr/bin/env bash
set -euo pipefail

# ShipAtlas Executor — install script
# Run as root: sudo bash install.sh

SHIPATLAS_REPO="https://github.com/Vime-Sistemas/shipatlas-executor"
RUNBOOKS_REPO="https://github.com/Vime-Sistemas/shipatlas-runbooks"
RUNBOOKS_DIR="$INSTALL_DIR/runbooks"
INSTALL_DIR="/opt/shipatlas"
SERVICE_USER="shipatlas"
SERVICE_NAME="shipatlas-executor"
NODE_MIN_VERSION=20

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[shipatlas]${NC} $*"; }
warn()    { echo -e "${YELLOW}[shipatlas]${NC} $*"; }
error()   { echo -e "${RED}[shipatlas]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${CYAN}── $* ${NC}"; }
ask()     { read -rp "$(echo -e "  ${YELLOW}→${NC} $* ")" REPLY; echo "$REPLY"; }
askpass() { read -rsp "$(echo -e "  ${YELLOW}→${NC} $* ")" REPLY; echo; echo "$REPLY"; }

# ── Root ──────────────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
  error "Run as root: sudo bash install.sh"
fi

echo ""
echo -e "${CYAN}  ShipAtlas Executor — Setup${NC}"
echo ""

# ── Step 1: Dependencies ──────────────────────────────────────────────────────

step "1/5  Checking dependencies"

MISSING=()
for cmd in git node npm redis-cli systemctl curl jq; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  error "Missing: ${MISSING[*]}. Install them and re-run."
fi

NODE_VERSION=$(node -e "process.stdout.write(process.versions.node.split('.')[0])")
if [ "$NODE_VERSION" -lt "$NODE_MIN_VERSION" ]; then
  error "Node.js $NODE_MIN_VERSION+ required (found $NODE_VERSION)"
fi

info "OK"

# ── Step 2: Redis ─────────────────────────────────────────────────────────────

step "2/5  Redis"

REDIS_URL_INPUT=$(ask "Redis URL [redis://localhost:6379]:")
REDIS_URL="${REDIS_URL_INPUT:-redis://localhost:6379}"

redis-cli -u "$REDIS_URL" ping &>/dev/null || error "Redis not reachable at $REDIS_URL"
info "Connected"

# ── Step 3: Install code ──────────────────────────────────────────────────────

step "3/5  Installing code to $INSTALL_DIR"

if [ -d "$INSTALL_DIR/.git" ]; then
  info "Already installed — pulling latest..."
  git config --global --add safe.directory "$INSTALL_DIR"
  git -C "$INSTALL_DIR" pull --ff-only
else
  info "Cloning..."
  git clone "$SHIPATLAS_REPO" "$INSTALL_DIR"
fi

# Create service user before chown
if ! id "$SERVICE_USER" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# Verify access
if ! su -s /bin/sh "$SERVICE_USER" -c "test -r '$INSTALL_DIR/dist/index.js'" 2>/dev/null; then
  error "Service user cannot read $INSTALL_DIR/dist/index.js — check permissions."
fi

info "Installing Node dependencies..."
cd "$INSTALL_DIR"
npm ci --omit=dev

# Clone or update runbooks repo
if [ -d "$RUNBOOKS_DIR/.git" ]; then
  info "Updating runbooks..."
  git config --global --add safe.directory "$RUNBOOKS_DIR"
  git -C "$RUNBOOKS_DIR" pull --ff-only
else
  info "Cloning runbooks..."
  git clone "$RUNBOOKS_REPO" "$RUNBOOKS_DIR"
fi
chmod +x "$RUNBOOKS_DIR/"*.sh
chown -R "$SERVICE_USER:$SERVICE_USER" "$RUNBOOKS_DIR"

info "Done"

# ── Step 4: Configuration ─────────────────────────────────────────────────────

step "4/5  Configuration"

CONFIG_FILE="$INSTALL_DIR/config.json"
ENV_FILE="$INSTALL_DIR/.env"

# config.json
if [ -f "$CONFIG_FILE" ]; then
  warn "config.json exists — skipping. Edit $CONFIG_FILE to change allowed runbooks."
else
  echo ""
  echo "  Available runbooks:"
  ls "$INSTALL_DIR/runbooks/"*.sh 2>/dev/null | xargs -I{} basename {} | sed 's/^/    /'
  echo ""

  ALLOWED=$(ask "Runbooks to allow (comma-separated, e.g. deploy_node_app.sh,healthcheck.sh):")
  [ -z "$ALLOWED" ] && error "At least one runbook is required."

  CUSTOM_DIR=$(ask "Custom runbooks directory? (full path, or leave blank):")

  RUNBOOKS_JSON=$(echo "$ALLOWED" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | jq -R . | jq -s .)

  if [ -n "$CUSTOM_DIR" ]; then
    jq -n --argjson r "$RUNBOOKS_JSON" --arg d "$CUSTOM_DIR" \
      '{"allowed_runbooks":$r,"custom_runbooks_dir":$d}' > "$CONFIG_FILE"
  else
    jq -n --argjson r "$RUNBOOKS_JSON" '{"allowed_runbooks":$r}' > "$CONFIG_FILE"
  fi
  info "config.json created"
fi

# .env
if [ -f "$ENV_FILE" ]; then
  warn ".env exists — skipping. Edit $ENV_FILE to change secrets or app settings."
else
  echo ""
  echo "  Application (where the runbook will operate):"
  APP_DIR=$(ask "APP_DIR — path of the application to deploy (e.g. /var/www/my-app):")
  [ -z "$APP_DIR" ] && error "APP_DIR is required."
  [ ! -d "$APP_DIR" ] && warn "'$APP_DIR' does not exist yet — create it before the first deploy."

  APP_SERVICE=$(ask "SERVICE_NAME — systemd or pm2 service to restart (e.g. my-app):")
  [ -z "$APP_SERVICE" ] && error "SERVICE_NAME is required."

  PROCESS_MANAGER=$(ask "PROCESS_MANAGER — systemd or pm2 [systemd]:")
  PROCESS_MANAGER="${PROCESS_MANAGER:-systemd}"

  echo ""
  echo "  Executor secrets (copy from Cloudflare Worker secrets):"
  SHARED_SECRET=$(askpass "EXECUTOR_SHARED_SECRET:")
  HMAC_KEY=$(askpass "EXECUTOR_HMAC_KEY:")

  PORT=$(ask "Port [9000]:")
  PORT="${PORT:-9000}"

  cat > "$ENV_FILE" <<EOF
PORT=$PORT
REDIS_URL=$REDIS_URL
EXECUTOR_SHARED_SECRET=$SHARED_SECRET
EXECUTOR_HMAC_KEY=$HMAC_KEY
EXECUTOR_CONFIG=$CONFIG_FILE
APP_DIR=$APP_DIR
SERVICE_NAME=$APP_SERVICE
PROCESS_MANAGER=$PROCESS_MANAGER
EOF

  chmod 600 "$ENV_FILE"
  chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
  info ".env created"
fi

# ── Step 5: Systemd ───────────────────────────────────────────────────────────

step "5/5  Systemd service"

cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=ShipAtlas Executor
After=network.target redis.service

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$(which node) dist/index.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 2
STATUS=$(systemctl is-active "$SERVICE_NAME")

# ── Done ──────────────────────────────────────────────────────────────────────

PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<server-ip>")
PORT=$(grep ^PORT "$ENV_FILE" | cut -d= -f2)

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Done!${NC}  Service status: ${STATUS}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Logs:     journalctl -u $SERVICE_NAME -f"
echo "  Config:   $CONFIG_FILE"
echo "  Env:      $ENV_FILE"
echo ""
echo -e "${YELLOW}  Set this in ShipAtlas → project → executor_url:${NC}"
echo -e "${CYAN}  http://$PUBLIC_IP:$PORT${NC}"
echo ""
