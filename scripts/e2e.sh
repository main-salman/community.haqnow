#!/usr/bin/env bash
set -euo pipefail

ADMIN_EMAIL="${ADMIN_EMAIL:-salman.naqvi@gmail.com}"
ADMIN_PASS="${ADMIN_PASS:-adslkj2390sadslkjALKJA9A*}"
SEAFILE_API="http://localhost:9002/api2"
API="http://localhost:8000/community-api"

echo "[e2e] Getting Seafile token..."
TOKEN=$(curl -sf -X POST "$SEAFILE_API/auth-token/" -d "username=${ADMIN_EMAIL}&password=${ADMIN_PASS}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))')
if [[ -z "$TOKEN" ]]; then echo "[e2e] ERROR: No Seafile token"; exit 1; fi
echo "[e2e] Token acquired"

echo "[e2e] Waiting for API health..."
for i in $(seq 1 40); do OUT=$(curl -sf "http://localhost:8000/health" || true); if echo "$OUT" | grep -q '"status"'; then echo "[e2e] API Health: $OUT"; break; fi; sleep 6; done

echo "[e2e] Creating a simple PDF on server for redaction test..."
python3 - <<'PY'
from PyPDF2 import PdfWriter
writer = PdfWriter()
writer.add_blank_page(width=595, height=842)
with open('/root/sample.pdf','wb') as f:
    writer.write(f)
print('created /root/sample.pdf')
PY

echo "[e2e] Uploading sample images and PDF..."
UPLOAD_OUT=$(curl -sf -H "Authorization: Token $TOKEN" -F "files=@/root/arabic-test.png" -F "files=@/root/french-test.png" -F "files=@/root/russian-test.png" -F "files=@/root/sample.pdf" "$API/upload")
echo "$UPLOAD_OUT"

echo "[e2e] Fetching docs..."
DID=$(curl -sf -H "Authorization: Token $TOKEN" "$API/docs" | python3 -c 'import sys,json; d=json.load(sys.stdin).get("docs",[]); print(d[0]["id"] if d else "")')
if [[ -z "$DID" ]]; then echo "[e2e] ERROR: No doc id"; exit 1; fi
echo "[e2e] First doc id: $DID"

echo "[e2e] Adding tag, note, highlight..."
curl -sf -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" -d '{"name":"test-tag"}' "$API/docs/$DID/tags" | cat
curl -sf -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" -d '{"content":"note from e2e"}' "$API/docs/$DID/notes" | cat
curl -sf -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" -d '{"page":1,"x":50,"y":100,"width":200,"height":60,"color":"#ffff00"}' "$API/docs/$DID/highlights" | cat

echo "[e2e] Search (FTS)..."
curl -sf -H "Authorization: Token $TOKEN" "$API/search?q=test" | python3 -m json.tool | sed -n "1,80p"

echo "[e2e] Semantic search (if pgvector is available)..."
curl -sf -H "Authorization: Token $TOKEN" "$API/search/semantic?q=test" | python3 -m json.tool | sed -n "1,80p" || true

echo "[e2e] Redacting first page of PDF (if PDF doc exists)..."
PDF_ID=$(echo "$UPLOAD_OUT" | python3 - <<'PY'
import sys,json
up=json.load(sys.stdin).get('uploaded',[])
for item in up:
    if item.get('filename','').lower().endswith('.pdf'):
        print(item.get('id'))
        break
PY
)
if [[ -n "$PDF_ID" ]]; then
  curl -sf -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" -d '{"rects":[{"page":1,"x":100,"y":150,"width":200,"height":60}]}' "$API/docs/$PDF_ID/redact" -o /root/redacted.pdf || true
  curl -sf -H "Authorization: Token $TOKEN" "$API/docs/$PDF_ID/export?pages=1" -o /root/export_p1.pdf || true
  echo "[e2e] Redaction and export attempted for doc $PDF_ID"
else
  echo "[e2e] No PDF found in upload to test redaction"
fi

echo "[e2e] Done"

