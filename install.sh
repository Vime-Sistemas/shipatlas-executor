#!/usr/bin/env bash
set -euo pipefail

# ShipAtlas Executor — install script
# Run as root or a user with sudo access
#
# Usage (code already on server):
#   sudo INSTALL_DIR=/path/to/shipatlas bash install.sh
#
# Usage (clone from remote):
#   sudo REPO_URL=https://github.com/org/shipatlas bash install.sh

REPO_URL="${REPO_URL:-}"
INSTALL_DIR="${INSTALL_DIR:-}"
SERVICE_USER="${SERVICE_USER:-shipatlas}"
SERVICE_NAME="shipatlas-executor"
NODE_MIN_VERSION=20

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[install]${NC} $*"; }
warn()    { echo -e "${YELLOW}[install]${NC} $*"; }
error()   { echo -e "${RED}[install]${NC} $*" >&2; exit 1; }
ask()     { read -rp "$(echo -e "${YELLOW}[?]${NC} $* ")" REPLY; echo "$REPLY"; }
askpass() { read -rsp "$(echo -e "${YELLOW}[?]${NC} $* ")" REPLY; echo; echo "$REPLY"; }

# ── Checks ───────────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
  error "Run as root: sudo bash install.sh"
fi

info "Checking dependencies..."

for cmd in git node npm redis-cli systemctl curl; do
  if ! command -v "$cmd" &>/dev/null; then
    error "'$cmd' is not installed. Please install it and re-run."
  fi
done

NODE_VERSION=$(node -e "process.stdout.write(process.versions.node.split('.')[0])")
if [ "$NODE_VERSION" -lt "$NODE_MIN_VERSION" ]; then
  error "Node.js $NODE_MIN_VERSION+ required (found $NODE_VERSION)"
fi

# Check Redis is reachable
REDIS_URL="${REDIS_URL:-redis://localhost:6379}"
if ! redis-cli -u "$REDIS_URL" ping &>/dev/null; then
  error "Redis is not reachable at $REDIS_URL. Start Redis or set REDIS_URL and re-run."
fi

info "All dependencies OK."

# ── Resolve install directory ─────────────────────────────────────────────────

if [ -n "$INSTALL_DIR" ] && [ -d "$INSTALL_DIR/executor" ]; then
  # Code already present at the given path — use it as-is
  info "Using existing code at $INSTALL_DIR"
else
  # Need to clone
  if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR=$(ask "Path where code should be installed [/opt/shipatlas-executor]:")
    INSTALL_DIR="${INSTALL_DIR:-/opt/shipatlas-executor}"
  fi

  if [ -z "$REPO_URL" ]; then
    REPO_URL=$(ask "Git repository URL (SSH or HTTPS):")
  fi

  if [ -d "$INSTALL_DIR/.git" ]; then
    info "Repository already exists at $INSTALL_DIR — pulling latest..."
    git -C "$INSTALL_DIR" pull
  else
    info "Cloning repository to $INSTALL_DIR..."
    git clone "$REPO_URL" "$INSTALL_DIR"
  fi
fi

# ── Install Node deps ─────────────────────────────────────────────────────────

info "Installing executor dependencies..."
cd "$INSTALL_DIR/executor"
npm ci --omit=dev

info "Building executor..."
npm run build

# ── Make runbooks executable ──────────────────────────────────────────────────

info "Setting runbook permissions..."
chmod +x "$INSTALL_DIR/runbooks/"*.sh

# ── System user ──────────────────────────────────────────────────────────────

if ! id "$SERVICE_USER" &>/dev/null; then
  info "Creating system user '$SERVICE_USER'..."
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# ── config.json ───────────────────────────────────────────────────────────────

CONFIG_FILE="$INSTALL_DIR/executor/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  info "Creating config.json..."
  echo "Available built-in runbooks:"
  ls "$INSTALL_DIR/runbooks/"*.sh | xargs -I{} basename {}

  ALLOWED=$(ask "Which runbooks to allow? (comma-separated, e.g. deploy_node_app.sh,healthcheck.sh):")
  CUSTOM_DIR=$(ask "Custom runbooks directory? (leave blank to skip):")

  # Build JSON array from comma-separated input
  RUNBOOKS_JSON=$(echo "$ALLOWED" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | jq -R . | jq -s .)

  if [ -n "$CUSTOM_DIR" ]; then
    jq -n --argjson r "$RUNBOOKS_JSON" --arg d "$CUSTOM_DIR" \
      '{"allowed_runbooks": $r, "custom_runbooks_dir": $d}' > "$CONFIG_FILE"
  else
    jq -n --argjson r "$RUNBOOKS_JSON" \
      '{"allowed_runbooks": $r}' > "$CONFIG_FILE"
  fi

  info "config.json created."
else
  warn "config.json already exists — skipping."
fi

# ── .env ─────────────────────────────────────────────────────────────────────

ENV_FILE="$INSTALL_DIR/executor/.env"

if [ ! -f "$ENV_FILE" ]; then
  info "Configuring environment..."

  SHARED_SECRET=$(askpass "EXECUTOR_SHARED_SECRET (from Cloudflare worker secrets):")
  HMAC_KEY=$(askpass "EXECUTOR_HMAC_KEY (from Cloudflare worker secrets):")
  PORT=$(ask "Port to listen on [9000]:")
  PORT="${PORT:-9000}"

  cat > "$ENV_FILE" <<EOF
PORT=$PORT
REDIS_URL=$REDIS_URL
EXECUTOR_SHARED_SECRET=$SHARED_SECRET
EXECUTOR_HMAC_KEY=$HMAC_KEY
EXECUTOR_CONFIG=$INSTALL_DIR/executor/config.json
EOF

  chmod 600 "$ENV_FILE"
  chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
  info ".env created."
else
  warn ".env already exists — skipping."
fi

# ── systemd service ───────────────────────────────────────────────────────────

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

info "Creating systemd service..."
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

echo ""
info "Installation complete!"
echo ""
echo "  Service:  $SERVICE_NAME"
echo "  Status:   $(systemctl is-active $SERVICE_NAME)"
echo "  Logs:     journalctl -u $SERVICE_NAME -f"
echo "  Config:   $CONFIG_FILE"
echo "  Port:     $(grep PORT $ENV_FILE | cut -d= -f2)"
echo ""
warn "Make sure port $(grep PORT $ENV_FILE | cut -d= -f2) is accessible from the Cloudflare worker IP ranges."
warn "Set executor_url in ShipAtlas to: http://$(curl -s ifconfig.me):$(grep PORT $ENV_FILE | cut -d= -f2)"
