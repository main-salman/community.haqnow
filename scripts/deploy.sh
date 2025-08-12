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

# Ensure core runtime deps so the server can start
log "Installing core backend deps..."
pip install -q fastapi==0.104.1 uvicorn==0.24.0 pydantic==2.5.2 python-dotenv==1.0.0 structlog==23.2.0 requests==2.31.0 || true

# Create a lightweight community app to bring API online while heavy deps are added incrementally
cat > /opt/foi-archive/appsrc/backend/community_app.py <<'PYAPP'
from fastapi import FastAPI
app = FastAPI(title="Community HaqNow API")
@app.get("/health")
async def health():
    return {"status": "ok", "service": "community"}
PYAPP

# Start minimal backend
log "Starting lightweight backend (community_app)..."
pkill -f "uvicorn community_app:app" || true
nohup python -m uvicorn community_app:app --host 0.0.0.0 --port 8000 >/var/log/foi/backend.out 2>&1 &

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

    # Backend API (strip /api/ prefix)
    location /api/ {
        proxy_pass http://localhost:8000/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Backend health (maps /health directly)
    location = /health {
        proxy_pass http://localhost:8000/health;
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
(set -x; curl -sf http://localhost/health || true)
(set -x; curl -sf http://localhost/api/health || true)

# If health failing, show backend logs tail
if ! curl -sf http://localhost/health >/dev/null; then
  echo "--- backend logs (last 200 lines) ---"
  tail -n 200 /var/log/foi/backend.out || true
fi
REMOTE_EOF

log "Deploying lightweight OCR+search backend..."
ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" bash -s <<'REMOTE2'
set -euo pipefail
log() { echo -e "[remote] $*"; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null || true
# Language packs for OCR
apt-get install -y tesseract-ocr tesseract-ocr-ara tesseract-ocr-rus tesseract-ocr-fra >/dev/null || true

mkdir -p /opt/foi-archive/backend_simple
cat > /opt/foi-archive/backend_simple/app.py <<'PY'
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from typing import List, Optional
import os
import io
import sqlite3
from PIL import Image
import pytesseract
from langdetect import detect
from googletrans import Translator

DB_PATH = os.environ.get("COMMUNITY_DB", "/opt/foi-archive/community.db")
DATA_DIR = os.environ.get("COMMUNITY_DATA", "/opt/foi-archive/data")

os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
os.makedirs(DATA_DIR, exist_ok=True)

app = FastAPI(title="Community OCR+Search API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL;")
    return conn


def init_db():
    conn = get_db()
    cur = conn.cursor()
    cur.execute(
        "CREATE TABLE IF NOT EXISTS docs (id INTEGER PRIMARY KEY, filename TEXT, lang TEXT, text TEXT, translated TEXT)"
    )
    cur.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts USING fts5(filename, text, translated, content='docs', content_rowid='id')"
    )
    # Ensure FTS sync trigger
    cur.executescript(
        """
        CREATE TRIGGER IF NOT EXISTS docs_ai AFTER INSERT ON docs BEGIN
          INSERT INTO docs_fts(rowid, filename, text, translated) VALUES (new.id, new.filename, new.text, new.translated);
        END;
        CREATE TRIGGER IF NOT EXISTS docs_ad AFTER DELETE ON docs BEGIN
          INSERT INTO docs_fts(docs_fts, rowid, filename, text, translated) VALUES('delete', old.id, old.filename, old.text, old.translated);
        END;
        CREATE TRIGGER IF NOT EXISTS docs_au AFTER UPDATE ON docs BEGIN
          INSERT INTO docs_fts(docs_fts, rowid, filename, text, translated) VALUES('delete', old.id, old.filename, old.text, old.translated);
          INSERT INTO docs_fts(rowid, filename, text, translated) VALUES (new.id, new.filename, new.text, new.translated);
        END;
        """
    )
    conn.commit()
    conn.close()


init_db()
translator = Translator()


def ocr_image(data: bytes) -> str:
    image = Image.open(io.BytesIO(data)).convert("RGB")
    # Use multiple languages to improve coverage
    text = pytesseract.image_to_string(image, lang=os.environ.get("TESS_LANGS", "eng+ara+rus+fra"))
    return text.strip()


@app.get("/health")
async def health():
    return {"status": "ok", "service": "community-simple"}


@app.post("/api/upload")
async def upload(files: List[UploadFile] = File(...)):
    results = []
    conn = get_db()
    cur = conn.cursor()
    for f in files:
        content = await f.read()
        # Save original file
        save_path = os.path.join(DATA_DIR, f.filename)
        with open(save_path, "wb") as out:
            out.write(content)
        # OCR
        try:
            text = ocr_image(content)
        except Exception as e:
            text = ""
        # Detect language and translate to English
        lang: Optional[str] = None
        translated: str = text
        try:
            if text:
                lang = detect(text)
                if lang and lang != "en":
                    translated = translator.translate(text, src=lang, dest="en").text
        except Exception:
            pass
        cur.execute(
            "INSERT INTO docs(filename, lang, text, translated) VALUES(?,?,?,?)",
            (f.filename, lang or "unknown", text, translated),
        )
        doc_id = cur.lastrowid
        results.append({"id": doc_id, "filename": f.filename, "lang": lang or "unknown"})
    conn.commit()
    conn.close()
    return {"uploaded": results}


@app.get("/api/search")
async def search(q: str):
    conn = get_db()
    cur = conn.cursor()
    rows = cur.execute(
        "SELECT d.id, d.filename, d.lang, snippet(docs_fts, 1, '<b>', '</b>', ' … ', 10) as snip_text, snippet(docs_fts, 2, '<b>', '</b>', ' … ', 10) as snip_trans FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid WHERE docs_fts MATCH ? LIMIT 25",
        (q,),
    ).fetchall()
    conn.close()
    results = [
        {
            "id": r[0],
            "filename": r[1],
            "lang": r[2],
            "snippet_text": r[3],
            "snippet_translated": r[4],
        }
        for r in rows
    ]
    return {"results": results}


@app.get("/api/docs")
async def list_docs():
    conn = get_db()
    cur = conn.cursor()
    rows = cur.execute("SELECT id, filename, lang FROM docs ORDER BY id DESC LIMIT 100").fetchall()
    conn.close()
    return {"docs": [{"id": r[0], "filename": r[1], "lang": r[2]} for r in rows]}
PY

cd /opt/foi-archive/backend_simple
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip >/dev/null
pip install -q fastapi uvicorn pillow pytesseract googletrans==3.1.0a0 langdetect >/dev/null || true

export COMMUNITY_DB=/opt/foi-archive/community.db
export COMMUNITY_DATA=/opt/foi-archive/data
export TESS_LANGS="eng+ara+rus+fra"

# Start service
pkill -f "uvicorn app:app --host 0.0.0.0 --port 9000" || true
nohup /opt/foi-archive/backend_simple/.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 9000 >/var/log/foi/backend-simple.out 2>&1 &

# Wire nginx /api to new service (temporary while full backend is WIP)
cat > /etc/nginx/sites-available/community-haqnow <<'NG'
server {
    listen 80;
    server_name community.haqnow.com;
    client_max_body_size 200M;

    location / {
        root /var/www/community;
        try_files $uri /index.html;
    }

    location /api/ {
        proxy_pass http://localhost:9000/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /health {
        proxy_pass http://localhost:9000/health;
    }
}
NG
ln -sf /etc/nginx/sites-available/community-haqnow /etc/nginx/sites-enabled/community-haqnow
nginx -t && systemctl restart nginx || true

# Quick health
sleep 2
curl -sf http://localhost:9000/health || true
REMOTE2

log "Deployment completed."

echo ""
echo "Application:  http://${SERVER_IP}"
echo "API health:   http://${SERVER_IP}/api/health"
