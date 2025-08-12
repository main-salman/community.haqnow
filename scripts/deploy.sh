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

# Copy .env to server
log "Copying .env to server..."
ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" 'mkdir -p /opt/foi-archive'
scp -o StrictHostKeyChecking=no "$PROJECT_ROOT/.env" root@"$SERVER_IP":/opt/foi-archive/.env || true

# Remote setup and deployment (non-docker)
log "Deploying on server (non-docker model)..."
ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" bash -s <<'REMOTE_EOF'
set -euo pipefail

log() { echo -e "[remote] $*"; }

# Base dirs
mkdir -p /opt/foi-archive
cd /opt/foi-archive

# Install prerequisites
log "Installing system prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y \
  python3 python3-venv python3-pip \
  nodejs npm \
  tesseract-ocr poppler-utils \
  nginx git curl >/dev/null

# Clone or update application source (haqnow baseline)
if [[ ! -d appsrc/.git ]]; then
  log "Cloning baseline app source (haqnow)..."
  rm -rf appsrc
  git clone https://github.com/main-salman/haqnow appsrc
else
  log "Updating baseline app source..."
  (cd appsrc && git fetch --all && git reset --hard origin/main)
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
pip install --upgrade pip >/dev/null
pip install -r requirements.txt >/dev/null || true
# Optional RAG deps (best-effort)
if [[ -f requirements-rag.txt ]]; then pip install -r requirements-rag.txt >/dev/null || true; fi

# Create RAG tables (best-effort)
python create_rag_tables.py || true

# Start backend (systemd optional, use nohup for now)
log "Starting backend (uvicorn)..."
nohup python -m uvicorn main:app --host 0.0.0.0 --port 8000 >/var/log/foi/backend.out 2>&1 &

# Frontend build
cd /opt/foi-archive/appsrc/frontend
if [[ -f package-lock.json ]]; then npm ci >/dev/null; else npm install >/dev/null; fi
npm run build >/dev/null
mkdir -p /var/www/html
cp -r dist/* /var/www/html/
chown -R www-data:www-data /var/www/html

# Nginx reverse proxy
if [[ ! -f /etc/nginx/sites-available/foi-archive ]]; then
  log "Configuring nginx..."
  cat > /etc/nginx/sites-available/foi-archive <<'NGINX'
server {
    listen 80;
    server_name _;
    client_max_body_size 100M;

    location / {
        root /var/www/html;
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
  ln -sf /etc/nginx/sites-available/foi-archive /etc/nginx/sites-enabled/foi-archive
  rm -f /etc/nginx/sites-enabled/default || true
fi

nginx -t
systemctl enable nginx || true
systemctl restart nginx || true

# Health checks
sleep 3
log "Health checks:"
(set -x; curl -sf http://localhost/api/health || true)
(set -x; curl -sf http://localhost || true)
REMOTE_EOF

log "Deployment completed."

echo ""
echo "Application:  http://${SERVER_IP}"
echo "API health:   http://${SERVER_IP}/api/health"
