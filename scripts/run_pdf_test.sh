#!/usr/bin/env bash
set -euo pipefail

ADMIN_EMAIL="${ADMIN_EMAIL:-salman.naqvi@gmail.com}"
ADMIN_PASS="${ADMIN_PASS:-adslkj2390sadslkjALKJA9A*}"
API="http://localhost:8000/community-api"

echo "[login]"
JWT=$(curl -sf -X POST "$API/auth/login" -H 'Content-Type: application/json' -d '{"email":"'"$ADMIN_EMAIL"'","password":"'"$ADMIN_PASS"'"}' | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
if [[ -z "$JWT" ]]; then echo "no jwt"; exit 1; fi
echo "jwt:${JWT:0:12}..."

echo "[health]"
curl -sf "http://localhost:8000/health" || true
echo

echo "[fetch sample pdf]"
curl -sSL -o /root/sample.pdf https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf
ls -lh /root/sample.pdf || true

echo "[upload]"
echo "[upload] status+body:"
curl -s -w " HTTP:%{http_code}\n" -H "Authorization: Bearer $JWT" -F "files=@/root/sample.pdf" "$API/upload"
echo
UPLOAD=$(curl -s -H "Authorization: Bearer $JWT" -F "files=@/root/sample.pdf" "$API/upload")

PDF_ID=$(python3 - <<'PY'
import sys,json
up=json.loads(sys.stdin.read()).get('uploaded',[])
print(next((str(i.get('id')) for i in up if str(i.get('filename','')).lower().endswith('.pdf')), ''))
PY
<<< "$UPLOAD")
if [[ -z "$PDF_ID" ]]; then echo "no pdf id"; exit 1; fi
echo "pdfid:$PDF_ID"

echo "[note]"
curl -s -w " HTTP:%{http_code}\n" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" -d '{"content":"pdf note"}' "$API/docs/$PDF_ID/notes" || true
echo

echo "[highlight]"
curl -s -w " HTTP:%{http_code}\n" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" -d '{"page":1,"x":50,"y":100,"width":200,"height":60,"color":"#ffff00"}' "$API/docs/$PDF_ID/highlights" || true
echo

echo "[redact]"
curl -s -w " HTTP:%{http_code}\n" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" -d '{"rects":[{"page":1,"x":100,"y":150,"width":150,"height":40}]}' "$API/docs/$PDF_ID/redact" -o /root/redacted.pdf || true
ls -lh /root/redacted.pdf || true

echo "[export]"
curl -s -w " HTTP:%{http_code}\n" -H "Authorization: Bearer $JWT" "$API/docs/$PDF_ID/export?pages=1" -o /root/export_p1.pdf || true
ls -lh /root/export_p1.pdf || true

echo "[done]"

