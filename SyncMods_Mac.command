#!/bin/bash
cd "$(dirname "$0")"
RAW_BASE="https://raw.githubusercontent.com/PhenylPropion/PokemonServer-Modpack/main"
if curl -fsSL "$RAW_BASE/sync_client.py" -o ./sync_client.py.tmp 2>/dev/null; then
  mv ./sync_client.py.tmp ./sync_client.py
else
  rm -f ./sync_client.py.tmp
  if [ ! -f "./sync_client.py" ]; then
    echo "[エラー] sync_client.py の取得に失敗しました。"
    read -n1 -r -p "キーを押して閉じます..."
    exit 1
  fi
fi
python3 ./sync_client.py --raw-base-url "$RAW_BASE" "$@"
echo ""
read -n1 -r -p "キーを押して閉じます..."
