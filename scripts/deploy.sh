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

# Ensure repo is committed and pushed before remote pulls
if command -v git >/dev/null 2>&1; then
  BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
  REPO_URL=$(git -C "$PROJECT_ROOT" remote get-url --push origin)
  if [[ -z "$REPO_URL" ]]; then
    echo "Error: no git remote 'origin' configured for $PROJECT_ROOT" >&2; exit 1
  fi
  log "Committing local changes (if any) and pushing to origin/$BRANCH..."
  git -C "$PROJECT_ROOT" add -A
  if ! git -C "$PROJECT_ROOT" diff --cached --quiet || ! git -C "$PROJECT_ROOT" diff --quiet; then
    git -C "$PROJECT_ROOT" commit -m "deploy: $(date -u +'%Y-%m-%dT%H:%M:%SZ') via scripts/deploy.sh" || true
  fi
  git -C "$PROJECT_ROOT" push origin "$BRANCH"
else
  echo "Error: git is required to push changes before deployment." >&2; exit 1
fi

# Ensure required local files
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  echo "Error: .env not found at $PROJECT_ROOT/.env" >&2
  exit 1
fi

# Copy only .env; code will be pulled from GitHub on the server
log "Copying .env to server (code will be pulled from Git)..."
ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" 'mkdir -p /opt/foi-archive /opt/foi-archive/site /opt/foi-archive/backend_simple /opt/foi-archive/src'
scp -o StrictHostKeyChecking=no "$PROJECT_ROOT/.env" root@"$SERVER_IP":/opt/foi-archive/.env || true

# Remote setup and deployment (non-docker)
log "Provisioning Seafile + OnlyOffice + API docker-compose stack..."
ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" env REPO_URL="$REPO_URL" BRANCH="$BRANCH" bash -s <<'REMOTE3'
set -euo pipefail
log() { echo -e "[remote] $*"; }

mkdir -p /opt/foi-archive
cd /opt/foi-archive

# Ensure docker-compose installed
if ! command -v docker-compose >/dev/null 2>&1; then
  apt-get update -y >/dev/null
  apt-get install -y docker-compose >/dev/null || true
fi

# Ensure git installed and pull latest code from GitHub
apt-get install -y git >/dev/null 2>&1 || true
REPO_URL="${REPO_URL:-}"
BRANCH="${BRANCH:-main}"
if [[ ! -d /opt/foi-archive/src/.git ]]; then
  log "Cloning repo $REPO_URL (branch $BRANCH)..."
  rm -rf /opt/foi-archive/src
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" /opt/foi-archive/src
else
  log "Fetching latest from $REPO_URL (branch $BRANCH)..."
  git -C /opt/foi-archive/src remote set-url origin "$REPO_URL" || true
  git -C /opt/foi-archive/src fetch origin "$BRANCH" --depth 1
  git -C /opt/foi-archive/src reset --hard "origin/$BRANCH"
fi

# Sync code from repo checkout into runtime directories
rsync -az --delete /opt/foi-archive/src/site/ /opt/foi-archive/site/
rsync -az --delete /opt/foi-archive/src/backend_simple/ /opt/foi-archive/backend_simple/

# Prepare API Dockerfile (build once; faster restarts)
  cat > /opt/foi-archive/backend_simple/Dockerfile.api <<'EOF'
FROM python:3.11-slim
ENV PIP_NO_CACHE_DIR=1 PYTHONDONTWRITEBYTECODE=1
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tesseract-ocr tesseract-ocr-ara tesseract-ocr-rus tesseract-ocr-fra \
      poppler-utils libgl1 libglib2.0-0 curl libreoffice fonts-dejavu-core xz-utils && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt && \
    pip install --index-url https://download.pytorch.org/whl/cpu torch
COPY . /app
EXPOSE 8000
CMD ["python","-m","uvicorn","app:app","--host","0.0.0.0","--port","8000"]
EOF
# Ensure requirements.txt exists for reproducible installs (prefer repo version; fallback to baseline)
if [[ ! -f /opt/foi-archive/backend_simple/requirements.txt ]]; then
  cat > /opt/foi-archive/backend_simple/requirements.txt <<'EOF'
fastapi
uvicorn
pillow
pytesseract
langdetect
PyJWT
bcrypt
email-validator
python-multipart
PyPDF2
pymupdf
numpy
sentence-transformers
psycopg2-binary
pyotp
requests
argostranslate
EOF
fi

# Write docker-compose.yml for Seafile stack
cat > /opt/foi-archive/docker-compose.yml <<'EOF'
version: '3.8'
services:
  seafile:
    image: seafileltd/seafile-mc:latest
    container_name: seafile
    restart: unless-stopped
    ports:
      - "9002:80"
    environment:
      - SEAFILE_SERVER_HOSTNAME=${SEAFILE_DOMAIN:-community.haqnow.com}
      - SEAFILE_ADMIN_EMAIL=${admin_email}
      - SEAFILE_ADMIN_PASSWORD=${admin_password}
      - DB_HOST=mysql
      - DB_ROOT_PASSWD=${MYSQL_ROOT_PASSWORD:-rootpass}
      - SEAFILE_FILESYSTEM_PROVIDER=s3
      - S3_USE_HTTPS=true
      - S3_ACCESS_KEY_ID=${EXOSCALE_S3_ACCESS_KEY}
      - S3_SECRET_ACCESS_KEY=${EXOSCALE_S3_SECRET_KEY}
      - S3_ENDPOINT=${EXOSCALE_S3_ENDPOINT}
      - S3_BUCKET=${EXOSCALE_BUCKET:-community-haqnow-docs}
      - S3_REGION=${EXOSCALE_S3_REGION}
    volumes:
      - seafile_data:/shared
      - /opt/foi-archive/seahub-custom:/shared/seafile/seahub-data/custom:ro
    depends_on:
      - mysql
  mysql:
    image: mariadb:10.11
    container_name: seafile-db
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-rootpass}
      - MYSQL_LOG_CONSOLE=true
    volumes:
      - db_data:/var/lib/mysql
  onlyoffice:
    image: onlyoffice/documentserver:latest
    container_name: onlyoffice
    restart: unless-stopped
    environment:
      - JWT_ENABLED=true
      - JWT_SECRET=${ONLYOFFICE_JWT_SECRET}
    ports:
      - "9003:80"
    depends_on:
      - seafile
  commapi:
    build:
      context: /opt/foi-archive/backend_simple
      dockerfile: Dockerfile.api
    restart: unless-stopped
    working_dir: /app
    env_file:
      - .env
    environment:
      - COMMUNITY_DB=/opt/foi-archive/community.db
      - COMMUNITY_DATA=/opt/foi-archive/data
      - TESS_LANGS=eng+ara+rus+fra
      - SEAFILE_BASE_URL=http://seafile
      - SEAFILE_ADMIN_EMAIL=${admin_email}
      - SEAFILE_ADMIN_PASSWORD=${admin_password}
      - OLLAMA_HOST=http://ollama:11434
      - OLLAMA_MODEL=llama3
    ports:
      - "8000:8000"
    healthcheck:
      test: ["CMD","curl","-f","http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 60s
    depends_on:
      - seafile
      - ollama
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/version"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s
volumes:
  seafile_data: {}
  db_data: {}
  ollama_data: {}
EOF

# Nginx reverse proxy for Seahub, OnlyOffice, and API
cat > /etc/nginx/sites-available/foi-archive <<'EOF'
server {
    listen 80;
    server_name community.haqnow.com _;
    client_max_body_size 200M;
    location / {
        proxy_pass http://localhost:9002/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # Temporary: inject redact tool until Seahub template override is verified
        sub_filter_once off;
        sub_filter '</body>' '<script src="/media/custom/custom.js"></script></body>';
        sub_filter_types text/html;
    }
    location /onlyoffice/ {
        proxy_pass http://localhost:9003/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    location /community-api/ {
        proxy_pass http://localhost:8000/community-api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    # custom assets now mounted directly into Seahub via seahub-data/custom
    location = /health { proxy_pass http://localhost:8000/health; }
}
EOF

# Prepare Seahub customization (custom.js at root of custom dir)
mkdir -p /opt/foi-archive/seahub-custom
cp -f /opt/foi-archive/site/seahub-redact.js /opt/foi-archive/seahub-custom/custom.js || true

ln -sf /etc/nginx/sites-available/foi-archive /etc/nginx/sites-enabled/foi-archive
rm -f /etc/nginx/sites-enabled/default || true
# Remove legacy static site mapping if present
rm -f /etc/nginx/sites-enabled/community-haqnow || true
nginx -t && systemctl restart nginx || true

# Start/refresh stack
docker-compose pull || true
# Rebuild API to pick up code changes
docker-compose build commapi || true
# Remove old API container to avoid docker-compose 'ContainerConfig' bug on recreate
docker-compose rm -f -s commapi || true
docker-compose rm -f -s seafile || true
docker-compose up -d --remove-orphans

# Basic health check
sleep 5
# Wait up to ~5 minutes for API health without hanging terminal
for i in $(seq 1 50); do 
  out=$(curl -m 3 -s http://localhost:8000/health || true); 
  if echo "$out" | grep -q '"status"'; then echo "$out"; break; fi; 
  sleep 6; 
done
REMOTE3

log "Deployment completed."

echo ""
echo "Seafile UI:   http://${SERVER_IP}"
echo "API health:   http://${SERVER_IP}/health"
