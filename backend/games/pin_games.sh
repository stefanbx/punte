#!/usr/bin/env bash
# Pin the self-contained game blobs to the relays, content-addressed. Run this at deploy time so the
# CID named in ../games.json actually resolves via /api/media?cid= (the app fetches games this way).
# The CID in games.json MUST equal 'sha256-'<sha256 of the exact file bytes> — recompute after any edit:
#   shasum -a 256 xno_snake.html
set -euo pipefail
cd "$(dirname "$0")"
VENV="$HOME/.xchat-mesh-node/venv/bin"   # has the deps xc_common needs
for f in *.html; do
  base64 "$f" > /tmp/xc_blob_in.txt
  "$VENV/python" ../xc_blobput.py
  echo "$f -> $(cat /tmp/xc_blobput_result.json)"
done
