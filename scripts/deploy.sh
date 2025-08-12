#!/usr/bin/env bash
set -euo pipefail

# community.haqnow.com deployment script (non-docker, modeled after haqnow)
# Usage: scripts/deploy.sh [SERVER_IP]
# - If SERVER_IP is not provided, it is read from Terraform output

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TF_DIR="$PROJECT_ROOT/terraform"
SERVER_IP="${1:-}"

log() { echo -e "[deploy] $*"; }

if [[ -z "${SERVER_IP}" ]]; then
  if command -v terraform >/dev/null 2>&1; then
    log "Resolving server IP from Terraform outputs..."
    SERVER_IP=$(terraform -chdir="$TF_DIR" output -raw instance_ip)
  else
    echo "Error: SERVER_IP not provided and terraform not installed to resolve it." >&2
    exit 1
  fi
fi

if [[ -z "${SERVER_IP}" ]]; then
  echo "Error: Could not determine SERVER_IP" >&2
  exit 1
fi

log "Target server IP: ${SERVER_IP}"

# Ensure required local files
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  echo "Error: .env not found at $PROJECT_ROOT/.env" >&2
  exit 1
fi

# Copy .env and site to server
log "Copying .env and static site to server..."
ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" 'mkdir -p /opt/foi-archive /opt/foi-archive/site'
scp -o StrictHostKeyChecking=no "$PROJECT_ROOT/.env" root@"$SERVER_IP":/opt/foi-archive/.env || true
rsync -az --delete "$PROJECT_ROOT/site/" root@"$SERVER_IP":/opt/foi-archive/site/

# Remote setup and deployment (non-docker)
log "Deploying on server (non-docker model)..."
ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" bash -s <<'REMOTE_EOF'
set -euo pipefail

log() { echo -e "[remote] $*"; }

# Base dirs
mkdir -p /opt/foi-archive /var/log/foi /var/www/community
cd /opt/foi-archive

# Install prerequisites
log "Installing system prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y \
  ca-certificates curl gnupg \
  python3 python3-venv python3-pip \
  tesseract-ocr poppler-utils libgl1 libglib2.0-0 \
  nginx git >/dev/null || true
apt-get -y --fix-broken install >/dev/null || true

# Install Node.js 20 LTS via NodeSource (for potential future frontend builds)
if ! command -v node >/dev/null 2>&1 || ! node -v | grep -q '^v20'; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y >/dev/null || true
  apt-get install -y nodejs >/dev/null || true
  apt-get -y --fix-broken install >/dev/null || true
fi

# Clone or update application source (backend only)
if [[ ! -d appsrc/.git ]]; then
  log "Cloning baseline app source (haqnow backend)..."
  rm -rf appsrc
  git clone --depth 1 https://github.com/main-salman/haqnow appsrc
else
  log "Updating baseline app source..."
  (cd appsrc && git fetch --depth 1 origin main && git reset --hard origin/main)
fi

# Export environment from .env for child processes
if [[ -f /opt/foi-archive/.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /opt/foi-archive/.env
  set +a
fi

# Backend setup
cd /opt/foi-archive/appsrc/backend
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip >/dev/null
python -m pip install --upgrade setuptools wheel >/dev/null 2>&1 || true

# Install backend dependencies using our toolchain (no build isolation)
export PIP_NO_BUILD_ISOLATION=1
if ! pip install -r requirements.txt >/dev/null; then
  log "Install failed even without build isolation; printing pip debug"
  pip -vvv install -r requirements.txt || true
fi

# Create RAG tables (best-effort)
python create_rag_tables.py || true

# Start backend (uvicorn)
log "Starting backend (uvicorn)..."
nohup python -m uvicorn main:app --host 0.0.0.0 --port 8000 >/var/log/foi/backend.out 2>&1 &

# Serve static site
rsync -az --delete /opt/foi-archive/site/ /var/www/community/
chown -R www-data:www-data /var/www/community

# Nginx reverse proxy
log "Configuring nginx..."
cat > /etc/nginx/sites-available/community-haqnow <<'NGINX'
server {
    listen 80;
    server_name community.haqnow.com;
    client_max_body_size 200M;

    location / {
        root /var/www/community;
        try_files $uri /index.html;
    }

    location /api/ {
        proxy_pass http://localhost:8000/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/community-haqnow /etc/nginx/sites-enabled/community-haqnow
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl enable nginx || true
systemctl restart nginx || true

# Health checks
sleep 3
log "Health checks:"
(set -x; curl -sf http://localhost/api/health || true)
(set -x; curl -sf http://localhost || true)

# If health failing, show backend logs tail
if ! curl -sf http://localhost/api/health >/dev/null; then
  echo "--- backend logs (last 200 lines) ---"
  tail -n 200 /var/log/foi/backend.out || true
fi
REMOTE_EOF

log "Deployment completed."

echo ""
echo "Application:  http://${SERVER_IP}"
echo "API health:   http://${SERVER_IP}/api/health"
