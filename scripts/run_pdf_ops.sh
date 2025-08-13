#!/usr/bin/env bash
set -euo pipefail

ADMIN_EMAIL="${ADMIN_EMAIL:-salman.naqvi@gmail.com}"
ADMIN_PASS="${ADMIN_PASS:-adslkj2390sadslkjALKJA9A*}"
API="http://localhost:8000/community-api"
SEAF="http://localhost:9002/api2"
DID="${1:-1}"

echo "[token]"
TOKEN=$(curl -s -X POST "$SEAF/auth-token/" -d "username=${ADMIN_EMAIL}&password=${ADMIN_PASS}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))')
if [[ -z "$TOKEN" ]]; then echo "no token"; exit 1; fi
echo "tok:${TOKEN:0:6}..."

echo -n "[note] "; curl -s -w " HTTP:%{http_code}\n" -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" -d '{"content":"pdf note"}' "$API/docs/$DID/notes"
echo -n "[highlight] "; curl -s -w " HTTP:%{http_code}\n" -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" -d '{"page":1,"x":50,"y":100,"width":200,"height":60,"color":"#ffff00"}' "$API/docs/$DID/highlights"
echo -n "[redact] "; curl -s -w " HTTP:%{http_code}\n" -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" -d '{"rects":[{"page":1,"x":100,"y":150,"width":150,"height":40}]}' "$API/docs/$DID/redact" -o /root/redacted.pdf; ls -lh /root/redacted.pdf || true
echo -n "[export] "; curl -s -w " HTTP:%{http_code}\n" -H "Authorization: Token $TOKEN" "$API/docs/$DID/export?pages=1" -o /root/export_p1.pdf; ls -lh /root/export_p1.pdf || true
echo "[done]"

