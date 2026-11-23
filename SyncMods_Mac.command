#!/bin/bash
cd "$(dirname "$0")"
RAW_BASE="__RAW_BASE_URL__"
if [ ! -f "./sync_client.py" ]; then
  curl -fsSL "$RAW_BASE/sync_client.py" -o ./sync_client.py
fi
python3 ./sync_client.py --raw-base-url "$RAW_BASE" "$@"
echo ""
read -n1 -r -p "キーを押して閉じます..."
