from fastapi import FastAPI, UploadFile, File, Form, Depends, HTTPException, status, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, FileResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from typing import List, Optional, Dict
import numpy as np
import os
import io
import tempfile
import sqlite3
import re
from PIL import Image
from PIL import ImageDraw
import pytesseract
from langdetect import detect
from googletrans import Translator
from pydantic import BaseModel, EmailStr
from datetime import datetime, timedelta
import bcrypt
import jwt
from PyPDF2 import PdfReader, PdfWriter
import fitz  # PyMuPDF
import pyotp
import requests

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
    # Users table for authentication and roles
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY,
            email TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL CHECK(role IN ('admin','editor','viewer')) DEFAULT 'viewer'
        )
        """
    )
    cur.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users(email)")
    # Lightweight migrations for MFA fields
    try:
        cur.execute("ALTER TABLE users ADD COLUMN mfa_secret TEXT")
    except Exception:
        pass
    try:
        cur.execute("ALTER TABLE users ADD COLUMN mfa_enabled INTEGER DEFAULT 0")
    except Exception:
        pass
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

    # Seed admin from environment if provided and not already present
    admin_email = os.environ.get("admin_email")
    admin_password = os.environ.get("admin_password")
    if admin_email and admin_password:
        row = conn.execute("SELECT id FROM users WHERE email = ?", (admin_email,)).fetchone()
        if not row:
            password_hash = bcrypt.hashpw(admin_password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
            conn.execute(
                "INSERT INTO users(email, password_hash, role) VALUES(?,?,?)",
                (admin_email, password_hash, "admin"),
            )
            conn.commit()
    conn.close()
    # Initialize auxiliary tables
    conn = get_db()
    cur = conn.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS notes (
            id INTEGER PRIMARY KEY,
            doc_id INTEGER NOT NULL,
            author_email TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(doc_id) REFERENCES docs(id) ON DELETE CASCADE
        )
        """
    )
    cur.execute("CREATE INDEX IF NOT EXISTS idx_notes_doc ON notes(doc_id)")
    cur.execute("CREATE TABLE IF NOT EXISTS tags (id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL)")
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS doc_tags (
            doc_id INTEGER NOT NULL,
            tag_id INTEGER NOT NULL,
            PRIMARY KEY(doc_id, tag_id),
            FOREIGN KEY(doc_id) REFERENCES docs(id) ON DELETE CASCADE,
            FOREIGN KEY(tag_id) REFERENCES tags(id) ON DELETE CASCADE
        )
        """
    )
    # Highlights table for annotations
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS highlights (
            id INTEGER PRIMARY KEY,
            doc_id INTEGER NOT NULL,
            page INTEGER NOT NULL,
            x REAL NOT NULL,
            y REAL NOT NULL,
            width REAL NOT NULL,
            height REAL NOT NULL,
            color TEXT DEFAULT '#ffff00',
            comment TEXT,
            author_email TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(doc_id) REFERENCES docs(id) ON DELETE CASCADE
        )
        """
    )
    cur.execute("CREATE INDEX IF NOT EXISTS idx_highlights_doc ON highlights(doc_id)")
    conn.commit()
    conn.close()


init_db()
translator = Translator()

# Optional semantic search (pgvector). Safe to import lazily if not configured.
try:
    import psycopg2  # type: ignore
except Exception:
    psycopg2 = None  # type: ignore

EMBEDDING_DIM = 384
_embedder = None

def get_embedder():
    global _embedder
    if _embedder is None:
        from sentence_transformers import SentenceTransformer
        _embedder = SentenceTransformer("all-MiniLM-L6-v2")
    return _embedder

def get_pg_conn():
    if psycopg2 is None:
        return None
    uri = os.environ.get("POSTGRES_RAG_URI")
    if not uri:
        return None
    try:
        return psycopg2.connect(uri)
    except Exception:
        return None

def ensure_pg_schema():
    conn = get_pg_conn()
    if conn is None:
        return
    try:
        cur = conn.cursor()
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        cur.execute(
            f"CREATE TABLE IF NOT EXISTS doc_embeddings (doc_id INTEGER PRIMARY KEY, filename TEXT NOT NULL, embedding vector({EMBEDDING_DIM}))"
        )
        conn.commit()
    except Exception:
        pass
    finally:
        try:
            cur.close()
        except Exception:
            pass
        conn.close()

ensure_pg_schema()


def ocr_image(data: bytes) -> str:
    image = Image.open(io.BytesIO(data)).convert("RGB")
    # Use multiple languages to improve coverage
    text = pytesseract.image_to_string(image, lang=os.environ.get("TESS_LANGS", "eng+ara+rus+fra"))
    return text.strip()


def sanitize_filename(name: str) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    return name[:200]


def strip_metadata_image(input_bytes: bytes) -> bytes:
    img = Image.open(io.BytesIO(input_bytes)).convert("RGB")
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


def strip_metadata_pdf(input_path: str, output_path: str) -> None:
    reader = PdfReader(input_path)
    writer = PdfWriter()
    for page in reader.pages:
        writer.add_page(page)
    writer.remove_metadata()
    with open(output_path, "wb") as f:
        writer.write(f)


# ==================== Seafile Integration ====================
class SeafileClient:
    def __init__(self) -> None:
        self.base_url: str = os.environ.get("SEAFILE_BASE_URL", "").rstrip("/")
        self.admin_email: Optional[str] = os.environ.get("SEAFILE_ADMIN_EMAIL")
        self.admin_password: Optional[str] = os.environ.get("SEAFILE_ADMIN_PASSWORD")
        self.repo_id: Optional[str] = os.environ.get("SEAFILE_REPO_ID")
        self._token: Optional[str] = None

    def is_configured(self) -> bool:
        return bool(self.base_url and self.admin_email and self.admin_password)

    def _auth_headers(self) -> Dict[str, str]:
        token = self._ensure_token()
        return {"Authorization": f"Token {token}"}

    def _ensure_token(self) -> str:
        if self._token:
            return self._token
        if not self.is_configured():
            raise RuntimeError("Seafile not configured")
        resp = requests.post(
            f"{self.base_url}/api2/auth-token/",
            data={"username": self.admin_email, "password": self.admin_password},
            timeout=5,
        )
        resp.raise_for_status()
        token = resp.json().get("token")
        if not token:
            raise RuntimeError("Failed to obtain Seafile token")
        self._token = token
        return token

    def ensure_repo(self, name: str = "Community Uploads") -> str:
        if self.repo_id:
            return self.repo_id
        # Try to find existing repo by name
        resp = requests.get(f"{self.base_url}/api2/repos/", headers=self._auth_headers(), timeout=10)
        resp.raise_for_status()
        for repo in resp.json():
            if repo.get("name") == name:
                self.repo_id = repo.get("id")
                return self.repo_id
        # Create repo
        resp = requests.post(
            f"{self.base_url}/api2/repos/",
            headers=self._auth_headers(),
            data={"name": name, "desc": "Uploads from Community API"},
            timeout=10,
        )
        resp.raise_for_status()
        self.repo_id = resp.json().get("repo_id") or resp.json().get("id")
        if not self.repo_id:
            raise RuntimeError("Failed to create Seafile repo")
        return self.repo_id

    def upload_file(self, local_path: str, dst_path: str = "/") -> Optional[str]:
        if not os.path.isfile(local_path):
            return None
        repo_id = self.ensure_repo()
        # Get upload link
        resp = requests.get(
            f"{self.base_url}/api2/repos/{repo_id}/upload-link/",
            headers=self._auth_headers(),
            params={"p": dst_path},
            timeout=10,
        )
        resp.raise_for_status()
        upload_link = resp.text.strip().strip('"')
        # Upload file
        with open(local_path, "rb") as f:
            files = {"file": (os.path.basename(local_path), f)}
            data = {"parent_dir": dst_path}
            up = requests.post(upload_link, files=files, data=data, timeout=60)
            up.raise_for_status()
            return os.path.join(dst_path, os.path.basename(local_path))
        
        return None


seafile_client = SeafileClient()

# ==================== Auth / Security ====================
JWT_SECRET: str = os.environ.get("JWT_SECRET_KEY", "dev-insecure-secret-change-me")
JWT_ALGORITHM: str = "HS256"
security = HTTPBearer(auto_error=False)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str
    otp_code: Optional[str] = None


class CreateUserRequest(BaseModel):
    email: EmailStr
    password: str
    role: str = "viewer"


def create_access_token(email: str, role: str, expires_minutes: int = 60 * 24) -> str:
    now = datetime.utcnow()
    payload = {
        "sub": email,
        "role": role,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=expires_minutes)).timestamp()),
    }
    token = jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)
    return token


def get_current_user(request: Request, credentials: Optional[HTTPAuthorizationCredentials] = Depends(security)) -> Dict[str, str]:
    # Accept both Authorization: Bearer <jwt> and Authorization: Token <seafile>
    header = request.headers.get("authorization") or ""
    scheme = ""
    token = ""
    if credentials and credentials.scheme:
        scheme = (credentials.scheme or "").lower()
        token = credentials.credentials or ""
    else:
        parts = header.split()
        if len(parts) == 2:
            scheme = parts[0].lower()
            token = parts[1]
    # Support Seafile tokens via Authorization: Token <token>
    if scheme == "token":
        base_url = os.environ.get("SEAFILE_BASE_URL", "http://localhost:9002")
        try:
            resp = requests.get(
                f"{base_url}/api2/account/info/",
                headers={"Authorization": f"Token {token}"},
                timeout=5,
            )
            if resp.status_code == 200:
                info = resp.json()
                email = info.get("email") or info.get("user") or "unknown@local"
                # Map Seafile users to viewer by default; admin mapping can be extended later
                return {"id": email, "email": email, "role": "viewer"}
        except Exception:
            pass
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid Seafile token")

    # Fallback: accept Seahub session cookies (same domain) and validate against Seafile
    try:
        cookie_header = request.headers.get("cookie") or request.headers.get("Cookie")
        if cookie_header:
            base_url = os.environ.get("SEAFILE_BASE_URL", "http://localhost:9002")
            resp = requests.get(
                f"{base_url}/api2/account/info/",
                headers={"Cookie": cookie_header},
                timeout=5,
            )
            if resp.status_code == 200:
                info = resp.json()
                email = info.get("email") or info.get("user") or "unknown@local"
                return {"id": email, "email": email, "role": "viewer"}
    except Exception:
        pass

    # Backward-compatible JWT via Authorization: Bearer <token>
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        email = payload.get("sub")
        role = payload.get("role")
    except Exception:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    if not email:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    conn = get_db()
    row = conn.execute("SELECT id, email, role FROM users WHERE email = ?", (email,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")
    return {"id": str(row[0]), "email": row[1], "role": row[2]}


def require_admin(user: Dict[str, str] = Depends(get_current_user)) -> Dict[str, str]:
    if user.get("role") != "admin":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin only")
    return user


@app.get("/health")
async def health():
    return {"status": "ok", "service": "community-simple"}


@app.post("/community-api/upload")
async def upload(files: List[UploadFile] = File(...), user: Dict[str, str] = Depends(get_current_user)):
    results = []
    conn = get_db()
    cur = conn.cursor()
    for f in files:
        content = await f.read()
        # Save original file
        safe_name = sanitize_filename(f.filename)
        save_path = os.path.join(DATA_DIR, safe_name)
        with open(save_path, "wb") as out:
            out.write(content)
        # Strip metadata and normalize formats
        try:
            lowered = safe_name.lower()
            if lowered.endswith((".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp")):
                content = strip_metadata_image(content)
                with open(save_path, "wb") as out:
                    out.write(content)
            elif lowered.endswith(".pdf"):
                tmp_path = save_path + ".clean.pdf"
                strip_metadata_pdf(save_path, tmp_path)
                os.replace(tmp_path, save_path)
        except Exception:
            pass
        # Optionally push to Seafile (best-effort, non-blocking)
        try:
            if seafile_client.is_configured():
                seafile_client.upload_file(save_path, "/uploads/")
        except Exception:
            pass

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
        # Try to create/update embedding in pgvector
        try:
            if translated:
                model = get_embedder()
                vec = model.encode([translated])[0]
                vec = np.asarray(vec, dtype=np.float32)
                pg = get_pg_conn()
                if pg is not None:
                    with pg.cursor() as pc:
                        pc.execute(
                            "INSERT INTO doc_embeddings(doc_id, filename, embedding) VALUES(%s,%s,%s) ON CONFLICT (doc_id) DO UPDATE SET embedding=EXCLUDED.embedding",
                            (doc_id, f.filename, vec.tolist()),
                        )
                        pg.commit()
                    pg.close()
        except Exception:
            pass
    conn.commit()
    conn.close()
    return {"uploaded": results}


@app.get("/community-api/search")
async def search(q: str, tag: Optional[str] = None, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    cur = conn.cursor()
    base_sql = "SELECT d.id, d.filename, d.lang, snippet(docs_fts, 1, '<b>', '</b>', ' … ', 10) as snip_text, snippet(docs_fts, 2, '<b>', '</b>', ' … ', 10) as snip_trans FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid"
    params: List = []
    if tag:
        base_sql += " JOIN doc_tags dt ON dt.doc_id = d.id JOIN tags t ON t.id = dt.tag_id AND t.name = ?"
        params.append(tag)
    base_sql += " WHERE docs_fts MATCH ? LIMIT 25"
    params.append(q)
    rows = cur.execute(base_sql, tuple(params)).fetchall()
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


@app.get("/community-api/docs")
async def list_docs(user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    cur = conn.cursor()
    rows = cur.execute("SELECT id, filename, lang FROM docs ORDER BY id DESC LIMIT 100").fetchall()
    conn.close()
    return {"docs": [{"id": r[0], "filename": r[1], "lang": r[2]} for r in rows]}


@app.get("/community-api/files/{filename}")
async def download_file(filename: str, user: Dict[str, str] = Depends(get_current_user)):
    safe = sanitize_filename(filename)
    path = os.path.join(DATA_DIR, safe)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(path, filename=safe)


# Notes
class NoteCreate(BaseModel):
    content: str


@app.get("/community-api/docs/{doc_id}/notes")
async def list_notes(doc_id: int, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    rows = conn.execute(
        "SELECT id, doc_id, author_email, content, created_at FROM notes WHERE doc_id = ? ORDER BY id DESC",
        (doc_id,),
    ).fetchall()
    conn.close()
    return {"notes": [
        {"id": r[0], "doc_id": r[1], "author_email": r[2], "content": r[3], "created_at": r[4]}
        for r in rows
    ]}


@app.post("/community-api/docs/{doc_id}/notes")
async def add_note(doc_id: int, body: NoteCreate, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO notes(doc_id, author_email, content, created_at) VALUES(?,?,?,?)",
        (doc_id, user["email"], body.content, datetime.utcnow().isoformat()),
    )
    conn.commit()
    note_id = cur.lastrowid
    conn.close()
    return {"id": note_id}


# Tags
class TagUpdate(BaseModel):
    name: str


@app.get("/community-api/docs/{doc_id}/tags")
async def get_tags(doc_id: int, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    rows = conn.execute(
        """
        SELECT t.name FROM tags t
        JOIN doc_tags dt ON dt.tag_id = t.id
        WHERE dt.doc_id = ? ORDER BY t.name
        """,
        (doc_id,),
    ).fetchall()
    conn.close()
    return {"tags": [r[0] for r in rows]}


@app.post("/community-api/docs/{doc_id}/tags")
async def add_tag(doc_id: int, body: TagUpdate, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    cur = conn.cursor()
    # ensure tag
    cur.execute("INSERT OR IGNORE INTO tags(name) VALUES(?)", (body.name,))
    tag_row = conn.execute("SELECT id FROM tags WHERE name = ?", (body.name,)).fetchone()
    if not tag_row:
        conn.close(); raise HTTPException(status_code=500, detail="Tag create failed")
    tag_id = tag_row[0]
    cur.execute("INSERT OR IGNORE INTO doc_tags(doc_id, tag_id) VALUES(?,?)", (doc_id, tag_id))
    conn.commit(); conn.close()
    return {"ok": True}


@app.delete("/community-api/docs/{doc_id}/tags")
async def remove_tag(doc_id: int, body: TagUpdate, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    tag_row = conn.execute("SELECT id FROM tags WHERE name = ?", (body.name,)).fetchone()
    if tag_row:
        conn.execute("DELETE FROM doc_tags WHERE doc_id = ? AND tag_id = ?", (doc_id, tag_row[0]))
        conn.commit()
    conn.close()
    return {"ok": True}


# Export selected pages (PDF only)
@app.get("/community-api/docs/{doc_id}/export")
async def export_pdf(doc_id: int, pages: str, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    row = conn.execute("SELECT filename FROM docs WHERE id = ?", (doc_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Document not found")
    filename = sanitize_filename(row[0])
    path = os.path.join(DATA_DIR, filename)
    if not filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="Export supported for PDF only")
    reader = PdfReader(path)
    writer = PdfWriter()
    # pages string like "1-3,5"
    selected = []
    for part in pages.split(','):
        part = part.strip()
        if '-' in part:
            a, b = part.split('-', 1)
            try:
                for p in range(int(a), int(b) + 1):
                    selected.append(p)
            except Exception:
                continue
        else:
            try:
                selected.append(int(part))
            except Exception:
                continue
    for p in selected:
        if 1 <= p <= len(reader.pages):
            writer.add_page(reader.pages[p - 1])
    out_path = os.path.join(DATA_DIR, f"export_{doc_id}.pdf")
    with open(out_path, "wb") as f:
        writer.write(f)
    return FileResponse(out_path, filename=f"document_{doc_id}_export.pdf")


# Redaction (PDF): expects list of rects per page
class RedactRect(BaseModel):
    page: int
    x: float
    y: float
    width: float
    height: float


class RedactRequest(BaseModel):
    rects: List[RedactRect]


@app.post("/community-api/docs/{doc_id}/redact")
async def redact_pdf(doc_id: int, body: RedactRequest, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    row = conn.execute("SELECT filename FROM docs WHERE id = ?", (doc_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Document not found")
    filename = sanitize_filename(row[0])
    path = os.path.join(DATA_DIR, filename)
    if not filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="Redaction supported for PDF only")
    out_path = os.path.join(DATA_DIR, f"redacted_{doc_id}.pdf")
    doc = fitz.open(path)
    try:
        for r in body.rects:
            if 1 <= r.page <= len(doc):
                page = doc[r.page - 1]
                rect = fitz.Rect(r.x, r.y, r.x + r.width, r.y + r.height)
                page.add_redact_annot(rect, fill=(0, 0, 0))
        for p in doc:
            p.apply_redactions()
        doc.save(out_path)
    finally:
        doc.close()
    # Best-effort upload to Seafile if available
    try:
        if seafile_client.is_configured():
            seafile_client.upload_file(out_path, "/redacted/")
    except Exception:
        pass
    return FileResponse(out_path, filename=f"document_{doc_id}_redacted.pdf")


# Image redaction (PNG/JPEG): expects list of rects in image pixel units
class ImageRedactRequest(BaseModel):
    rects: List[RedactRect]


@app.post("/community-api/docs/{doc_id}/redact-image")
async def redact_image(doc_id: int, body: ImageRedactRequest, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    row = conn.execute("SELECT filename FROM docs WHERE id = ?", (doc_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Document not found")
    filename = sanitize_filename(row[0])
    path = os.path.join(DATA_DIR, filename)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="File not found")

    try:
        with Image.open(path).convert("RGB") as img:
            draw = ImageDraw.Draw(img)
            for r in body.rects:
                x0 = max(0, int(r.x))
                y0 = max(0, int(r.y))
                x1 = max(0, int(r.x + r.width))
                y1 = max(0, int(r.y + r.height))
                draw.rectangle([(x0, y0), (x1, y1)], fill=(0, 0, 0))
            out_path = os.path.join(DATA_DIR, f"redacted_{doc_id}.png")
            img.save(out_path, format="PNG")
    except Exception:
        raise HTTPException(status_code=500, detail="Image redaction error")

    # Best-effort upload to Seafile if available
    try:
        if seafile_client.is_configured():
            seafile_client.upload_file(out_path, "/redacted/")
    except Exception:
        pass
    return FileResponse(out_path, filename=f"document_{doc_id}_redacted.png")


# Inline redaction: accept uploaded file bytes and rects; return redacted file
@app.post("/community-api/redact-bytes")
async def redact_bytes(
    file: UploadFile = File(...),
    rects: str = Form(...),
    kind: Optional[str] = Form(None),
    page_pixels_w: Optional[str] = Form(None),
    page_pixels_h: Optional[str] = Form(None),
    page_canvas_w: Optional[str] = Form(None),
    page_canvas_h: Optional[str] = Form(None),
    user: Dict[str, str] = Depends(get_current_user),
):
    try:
        rect_list = []
        try:
            import json
            payload = json.loads(rects)
            items = payload.get("rects") if isinstance(payload, dict) and "rects" in payload else payload
            if not items:
                raise ValueError("no-rects")
            for r in items:
                rect_list.append(RedactRect(page=int(r.get("page", 1)), x=float(r["x"]), y=float(r["y"]), width=float(r["width"]), height=float(r["height"])) )
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid rects JSON")

        name = (file.filename or "file").lower()
        is_pdf = (kind or '').lower() == "pdf" or name.endswith(".pdf")
        is_img = (kind or '').lower() == "image" or any(name.endswith(ext) for ext in (".png",".jpg",".jpeg",".bmp",".tif",".tiff"))
        raw = await file.read()
        if is_pdf:
            out_fd = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
            out_path = out_fd.name; out_fd.close()
            # Open directly from bytes to avoid tmp input management
            try:
                doc = fitz.open(stream=raw, filetype="pdf")
            except Exception:
                # Some Seahub raw links may return HTML; try to fetch via URL if provided as filename
                try:
                    import requests as _r
                    if file and getattr(file, 'filename', None) and str(file.filename).startswith('http'):
                        r = _r.get(file.filename, timeout=10)
                        r.raise_for_status()
                        doc = fitz.open(stream=r.content, filetype="pdf")
                    else:
                        raise
                except Exception as ex:
                    raise HTTPException(status_code=400, detail="Input is not a PDF")
            try:
                for r in rect_list:
                    idx = max(0, int(r.page) - 1)
                    if idx >= len(doc):
                        continue
                    page = doc[idx]
                    # Clamp rectangle within page bounds
                    pg = page.rect
                    # If client sent pixel dimensions from the on-screen canvas, scale to PDF coordinates
                    try:
                        # Prefer canvas pixel size for accuracy; fallback to on-screen size
                        px_w = float(page_canvas_w) if page_canvas_w else (float(page_pixels_w) if page_pixels_w else None)
                        px_h = float(page_canvas_h) if page_canvas_h else (float(page_pixels_h) if page_pixels_h else None)
                    except Exception:
                        px_w = px_h = None
                    sx = (pg.width / px_w) if (px_w and px_w > 0) else 1.0
                    sy = (pg.height / px_h) if (px_h and px_h > 0) else 1.0
                    x0 = max(pg.x0, min(pg.x1, r.x * sx))
                    y0 = max(pg.y0, min(pg.y1, r.y * sy))
                    x1 = max(pg.x0, min(pg.x1, (r.x + r.width) * sx))
                    y1 = max(pg.y0, min(pg.y1, (r.y + r.height) * sy))
                    if x1 > x0 and y1 > y0:
                        rect = fitz.Rect(x0, y0, x1, y1)
                        page.add_redact_annot(rect, fill=(0, 0, 0))
                for p in doc:
                    p.apply_redactions()
                doc.save(out_path)
            finally:
                try: doc.close()
                except Exception: pass
            return FileResponse(out_path, filename=(file.filename or "redacted.pdf"))
        elif is_img:
            try:
                img = Image.open(io.BytesIO(raw)).convert("RGB")
                draw = ImageDraw.Draw(img)
                for r in rect_list:
                    x0 = max(0, int(r.x)); y0 = max(0, int(r.y))
                    x1 = max(0, int(r.x + r.width)); y1 = max(0, int(r.y + r.height))
                    draw.rectangle([(x0, y0), (x1, y1)], fill=(0, 0, 0))
                out_fd = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
                out_path = out_fd.name; out_fd.close()
                img.save(out_path, format="PNG")
                return FileResponse(out_path, filename=(file.filename or "redacted.png").rsplit('.',1)[0] + "_redacted.png")
            except Exception:
                raise HTTPException(status_code=500, detail="Image redaction error")
        else:
            raise HTTPException(status_code=415, detail="Unsupported file type")
    except HTTPException:
        raise
    except Exception as e:
        # Include exception name and message for client (trimmed), and log to server stdout
        try:
            print("[redact-bytes] error:", repr(e))
        except Exception:
            pass
        msg = str(e)
        if len(msg) > 200:
            msg = msg[:200]
        raise HTTPException(status_code=500, detail=f"Redaction error: {type(e).__name__}: {msg}")


# Highlights
class Highlight(BaseModel):
    page: int
    x: float
    y: float
    width: float
    height: float
    color: Optional[str] = "#ffff00"
    comment: Optional[str] = None


@app.get("/community-api/docs/{doc_id}/highlights")
async def list_highlights(doc_id: int, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    rows = conn.execute(
        "SELECT id, page, x, y, width, height, COALESCE(color,''), COALESCE(comment,'') FROM highlights WHERE doc_id = ? ORDER BY id",
        (doc_id,),
    ).fetchall()
    conn.close()
    return {"highlights": [
        {"id": r[0], "page": r[1], "x": r[2], "y": r[3], "width": r[4], "height": r[5], "color": r[6] or "#ffff00", "comment": r[7] or ""}
        for r in rows
    ]}


@app.post("/community-api/docs/{doc_id}/highlights")
async def add_highlight(doc_id: int, body: Highlight, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO highlights(doc_id, page, x, y, width, height, color, comment, author_email, created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
        (doc_id, body.page, body.x, body.y, body.width, body.height, body.color or "#ffff00", body.comment or "", user["email"], datetime.utcnow().isoformat()),
    )
    conn.commit()
    hid = cur.lastrowid
    conn.close()
    return {"id": hid}


@app.delete("/community-api/docs/{doc_id}/highlights/{highlight_id}")
async def delete_highlight(doc_id: int, highlight_id: int, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    conn.execute("DELETE FROM highlights WHERE id = ? AND doc_id = ?", (highlight_id, doc_id))
    conn.commit(); conn.close()
    return {"ok": True}

# Simple Q&A using FTS snippets as grounded answer
class QARequest(BaseModel):
    question: str


@app.post("/community-api/qa")
async def qa(body: QARequest, user: Dict[str, str] = Depends(get_current_user)):
    q = body.question.strip()
    if not q:
        raise HTTPException(status_code=422, detail="Empty question")
    # Prefer semantic if available
    pg = get_pg_conn()
    if pg is not None:
        try:
            model = get_embedder()
            qvec = model.encode([q])[0]
            qvec = np.asarray(qvec, dtype=np.float32)
            with pg.cursor() as pc:
                pc.execute(
                    "SELECT doc_id, filename FROM doc_embeddings ORDER BY embedding <-> %s LIMIT 5",
                    (qvec.tolist(),),
                )
                rows = pc.fetchall()
            pg.close()
            return {"answers": [{"doc_id": r[0], "filename": r[1]} for r in rows]}
        except Exception:
            pass
    # Fallback to FTS
    conn = get_db()
    rows = conn.execute(
        "SELECT d.id, d.filename, snippet(docs_fts, 1, '[', ']', ' … ', 12) as snip_text, snippet(docs_fts, 2, '[', ']', ' … ', 12) as snip_trans FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid WHERE docs_fts MATCH ? LIMIT 5",
        (q,),
    ).fetchall()
    conn.close()
    return {"answers": [
        {"doc_id": r[0], "filename": r[1], "snippet_text": r[2], "snippet_translated": r[3]} for r in rows
    ]}


@app.get("/community-api/search/semantic")
async def semantic_search(q: str, user: Dict[str, str] = Depends(get_current_user)):
    pg = get_pg_conn()
    if pg is None:
        raise HTTPException(status_code=503, detail="Semantic search not available")
    try:
        model = get_embedder()
        qvec = model.encode([q])[0]
        qvec = np.asarray(qvec, dtype=np.float32)
        with pg.cursor() as pc:
            pc.execute(
                "SELECT doc_id, filename FROM doc_embeddings ORDER BY embedding <-> %s LIMIT 10",
                (qvec.tolist(),),
            )
            rows = pc.fetchall()
        return {"results": [{"doc_id": r[0], "filename": r[1]} for r in rows]}
    except Exception:
        raise HTTPException(status_code=500, detail="Semantic search error")
    finally:
        try:
            pg.close()
        except Exception:
            pass


# Bulk tag operations
class BulkTagUpdate(BaseModel):
    name: str
    doc_ids: List[int]


@app.post("/community-api/docs/tags/bulk")
async def bulk_add_tag(body: BulkTagUpdate, user: Dict[str, str] = Depends(get_current_user)):
    if not body.doc_ids:
        return {"updated": 0}
    conn = get_db()
    cur = conn.cursor()
    # ensure tag
    cur.execute("INSERT OR IGNORE INTO tags(name) VALUES(?)", (body.name,))
    tag_row = conn.execute("SELECT id FROM tags WHERE name = ?", (body.name,)).fetchone()
    if not tag_row:
        conn.close(); raise HTTPException(status_code=500, detail="Tag create failed")
    tag_id = tag_row[0]
    updated = 0
    for did in body.doc_ids:
        cur.execute("INSERT OR IGNORE INTO doc_tags(doc_id, tag_id) VALUES(?,?)", (did, tag_id))
        updated += cur.rowcount if cur.rowcount is not None else 0
    conn.commit(); conn.close()
    return {"updated": updated}


@app.delete("/community-api/docs/tags/bulk")
async def bulk_remove_tag(body: BulkTagUpdate, user: Dict[str, str] = Depends(get_current_user)):
    if not body.doc_ids:
        return {"removed": 0}
    conn = get_db()
    tag_row = conn.execute("SELECT id FROM tags WHERE name = ?", (body.name,)).fetchone()
    if not tag_row:
        conn.close(); return {"removed": 0}
    tag_id = tag_row[0]
    removed = 0
    for did in body.doc_ids:
        cur = conn.execute("DELETE FROM doc_tags WHERE doc_id = ? AND tag_id = ?", (did, tag_id))
        removed += cur.rowcount if cur.rowcount is not None else 0
    conn.commit(); conn.close()
    return {"removed": removed}


# ==================== Auth Endpoints ====================
@app.post("/community-api/auth/login")
async def login(body: LoginRequest):
    conn = get_db()
    row = conn.execute(
        "SELECT id, email, password_hash, role, COALESCE(mfa_enabled,0), mfa_secret FROM users WHERE email = ?",
        (body.email,),
    ).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
    user_id, email, password_hash, role, mfa_enabled, mfa_secret = row
    try:
        if not bcrypt.checkpw(body.password.encode("utf-8"), password_hash.encode("utf-8")):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
    except ValueError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
    if mfa_enabled:
        if not body.otp_code or not mfa_secret:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="MFA required")
        totp = pyotp.TOTP(mfa_secret)
        if not totp.verify(body.otp_code, valid_window=1):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid OTP code")
    token = create_access_token(email=email, role=role)
    return {"access_token": token, "token_type": "bearer"}


@app.get("/community-api/auth/me")
async def me(user: Dict[str, str] = Depends(get_current_user)):
    return user


class MFASetupResponse(BaseModel):
    secret: str
    provisioning_uri: str


@app.post("/community-api/auth/mfa/setup")
async def mfa_setup(user: Dict[str, str] = Depends(get_current_user)):
    secret = pyotp.random_base32()
    issuer = "CommunityHaqNow"
    uri = pyotp.totp.TOTP(secret).provisioning_uri(name=user["email"], issuer_name=issuer)
    conn = get_db()
    conn.execute("UPDATE users SET mfa_secret = ? WHERE email = ?", (secret, user["email"]))
    conn.commit(); conn.close()
    return {"secret": secret, "provisioning_uri": uri}


class MFAVerifyRequest(BaseModel):
    otp_code: str


@app.post("/community-api/auth/mfa/verify")
async def mfa_verify(body: MFAVerifyRequest, user: Dict[str, str] = Depends(get_current_user)):
    conn = get_db()
    row = conn.execute("SELECT mfa_secret FROM users WHERE email = ?", (user["email"],)).fetchone()
    if not row or not row[0]:
        conn.close(); raise HTTPException(status_code=400, detail="MFA not initialized")
    secret = row[0]
    totp = pyotp.TOTP(secret)
    if not totp.verify(body.otp_code, valid_window=1):
        conn.close(); raise HTTPException(status_code=401, detail="Invalid OTP code")
    conn.execute("UPDATE users SET mfa_enabled = 1 WHERE email = ?", (user["email"],))
    conn.commit(); conn.close()
    return {"ok": True}


@app.post("/community-api/admin/users")
async def admin_create_user(body: CreateUserRequest, _: Dict[str, str] = Depends(require_admin)):
    if body.role not in ("admin", "editor", "viewer"):
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Invalid role")
    password_hash = bcrypt.hashpw(body.password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO users(email, password_hash, role) VALUES(?,?,?)",
            (str(body.email), password_hash, body.role),
        )
        conn.commit()
        user_id = cur.lastrowid
    except sqlite3.IntegrityError:
        conn.close()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already exists")
    conn.close()
    return {"id": user_id, "email": str(body.email), "role": body.role}


@app.get("/community-api/admin/users")
async def admin_list_users(_: Dict[str, str] = Depends(require_admin)):
    conn = get_db()
    rows = conn.execute("SELECT id, email, role FROM users ORDER BY id ASC").fetchall()
    conn.close()
    return {"users": [{"id": r[0], "email": r[1], "role": r[2]} for r in rows]}
