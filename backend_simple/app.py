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
