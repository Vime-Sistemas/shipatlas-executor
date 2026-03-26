#!/usr/bin/env bash
set -euo pipefail

# ShipAtlas Executor — install script
# Run as root: sudo bash install.sh

SERVICE_USER="${SERVICE_USER:-shipatlas}"
SERVICE_NAME="shipatlas-executor"
NODE_MIN_VERSION=20

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[install]${NC} $*"; }
warn()    { echo -e "${YELLOW}[install]${NC} $*"; }
error()   { echo -e "${RED}[install]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${CYAN}──────────────────────────────────────${NC}"; echo -e "${CYAN}$*${NC}"; echo -e "${CYAN}──────────────────────────────────────${NC}"; }
ask()     { read -rp "$(echo -e "${YELLOW}  → ${NC}$* ")" REPLY; echo "$REPLY"; }
askpass() { read -rsp "$(echo -e "${YELLOW}  → ${NC}$* ")" REPLY; echo; echo "$REPLY"; }

# ── Root check ────────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
  error "Run as root: sudo bash install.sh"
fi

echo ""
echo -e "${CYAN}  ShipAtlas Executor — Setup Wizard${NC}"
echo ""

# ── Step 1: Dependencies ──────────────────────────────────────────────────────

step "Step 1/6 — Checking dependencies"

for cmd in git node npm systemctl curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    error "'$cmd' is not installed. Please install it and re-run."
  fi
done

NODE_VERSION=$(node -e "process.stdout.write(process.versions.node.split('.')[0])")
if [ "$NODE_VERSION" -lt "$NODE_MIN_VERSION" ]; then
  error "Node.js $NODE_MIN_VERSION+ required (found $NODE_VERSION)"
fi

info "Node.js $NODE_VERSION, git $(git --version | cut -d' ' -f3) — OK"

# ── Step 2: Redis ─────────────────────────────────────────────────────────────

step "Step 2/6 — Redis"

if ! command -v redis-cli &>/dev/null; then
  error "'redis-cli' is not installed. Install Redis and re-run."
fi

REDIS_URL=$(ask "Redis URL [redis://localhost:6379]:")
REDIS_URL="${REDIS_URL:-redis://localhost:6379}"

if ! redis-cli -u "$REDIS_URL" ping &>/dev/null; then
  error "Redis is not reachable at $REDIS_URL"
fi

info "Redis OK at $REDIS_URL"

# ── Step 3: Source code ───────────────────────────────────────────────────────

step "Step 3/6 — Source code"

echo "  How is the ShipAtlas code available on this server?"
echo "  [1] Already cloned — I have the code at a local path"
echo "  [2] Clone now from a public GitHub repository"
echo ""
SOURCE_CHOICE=$(ask "Choose [1/2]:")

if [ "$SOURCE_CHOICE" = "1" ]; then
  INSTALL_DIR=$(ask "Full path to the ShipAtlas repo (the directory that contains executor/, runbooks/, etc.):")
  if [ ! -d "$INSTALL_DIR/executor" ]; then
    error "Directory '$INSTALL_DIR/executor' not found. Make sure the path is correct."
  fi
  info "Using existing code at $INSTALL_DIR"
else
  INSTALL_DIR=$(ask "Where to clone to [/opt/shipatlas]:")
  INSTALL_DIR="${INSTALL_DIR:-/opt/shipatlas}"
  REPO_URL=$(ask "Repository URL (HTTPS public, e.g. https://github.com/org/shipatlas):")
  if [ -z "$REPO_URL" ]; then
    error "Repository URL is required."
  fi
  info "Cloning $REPO_URL → $INSTALL_DIR..."
  git clone "$REPO_URL" "$INSTALL_DIR"
  if [ ! -d "$INSTALL_DIR/executor" ]; then
    error "Cloned repo does not contain an 'executor/' directory."
  fi
fi

# ── Step 4: Build ─────────────────────────────────────────────────────────────

step "Step 4/6 — Build"

info "Installing executor dependencies..."
cd "$INSTALL_DIR/executor"
npm ci --omit=dev

info "Setting runbook permissions..."
chmod +x "$INSTALL_DIR/runbooks/"*.sh

# System user
if ! id "$SERVICE_USER" &>/dev/null; then
  info "Creating system user '$SERVICE_USER'..."
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# ── Step 5: Configuration ─────────────────────────────────────────────────────

step "Step 5/6 — Configuration"

CONFIG_FILE="$INSTALL_DIR/executor/config.json"

if [ -f "$CONFIG_FILE" ]; then
  warn "config.json already exists — skipping runbook setup."
else
  echo ""
  echo "  Available built-in runbooks:"
  ls "$INSTALL_DIR/runbooks/"*.sh | xargs -I{} basename {} | sed 's/^/    /'
  echo ""

  ALLOWED=$(ask "Which runbooks to allow? (comma-separated, e.g. deploy_node_app.sh,healthcheck.sh):")
  if [ -z "$ALLOWED" ]; then
    error "At least one runbook must be allowed."
  fi

  CUSTOM_DIR=$(ask "Custom runbooks directory? (full path, leave blank to skip):")

  RUNBOOKS_JSON=$(echo "$ALLOWED" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | jq -R . | jq -s .)

  if [ -n "$CUSTOM_DIR" ]; then
    jq -n --argjson r "$RUNBOOKS_JSON" --arg d "$CUSTOM_DIR" \
      '{"allowed_runbooks": $r, "custom_runbooks_dir": $d}' > "$CONFIG_FILE"
  else
    jq -n --argjson r "$RUNBOOKS_JSON" \
      '{"allowed_runbooks": $r}' > "$CONFIG_FILE"
  fi

  info "config.json created."
fi

ENV_FILE="$INSTALL_DIR/executor/.env"

if [ -f "$ENV_FILE" ]; then
  warn ".env already exists — skipping secrets setup."
else
  echo ""
  echo "  Application settings (used by the runbooks):"
  APP_DIR=$(ask "APP_DIR — full path to the application to be deployed (e.g. /var/www/flow-v2):")
  if [ -z "$APP_DIR" ]; then error "APP_DIR is required."; fi
  if [ ! -d "$APP_DIR" ]; then warn "Directory '$APP_DIR' does not exist yet — make sure it exists before the first deploy."; fi

  APP_SERVICE=$(ask "SERVICE_NAME — systemd or pm2 service name to restart (e.g. flow-v2):")
  if [ -z "$APP_SERVICE" ]; then error "SERVICE_NAME is required."; fi

  PROCESS_MANAGER=$(ask "PROCESS_MANAGER — how the service is managed [systemd/pm2] [systemd]:")
  PROCESS_MANAGER="${PROCESS_MANAGER:-systemd}"

  echo ""
  echo "  Executor secrets (from Cloudflare worker):"
  SHARED_SECRET=$(askpass "EXECUTOR_SHARED_SECRET:")
  HMAC_KEY=$(askpass "EXECUTOR_HMAC_KEY:")
  PORT=$(ask "Port to listen on [9000]:")
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
  info ".env created."
fi

# ── Step 6: Systemd ───────────────────────────────────────────────────────────

step "Step 6/6 — Systemd service"

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ShipAtlas Executor
After=network.target redis.service

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR/executor
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

# ── Done ──────────────────────────────────────────────────────────────────────

PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<server-ip>")
PORT=$(grep PORT "$ENV_FILE" | cut -d= -f2)

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Service:      $SERVICE_NAME"
echo "  Status:       $(systemctl is-active $SERVICE_NAME)"
echo "  Logs:         journalctl -u $SERVICE_NAME -f"
echo ""
echo -e "${YELLOW}  Next step — set this in ShipAtlas project:${NC}"
echo -e "${CYAN}  executor_url = http://$PUBLIC_IP:$PORT${NC}"
echo ""
warn "Make sure port $PORT is open for Cloudflare IP ranges."
