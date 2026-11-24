# PokemonServer MOD同期ツール

サーバーのMOD更新・追加・バランス調整（Config）を、**1クリックで自分のマイクラ環境へ同期**するためのリポジトリです。  
※MOD本体（`.jar`）はこのリポジトリに含まず、Modrinth / CurseForge の公式CDNから自動ダウンロードします。

- **Minecraft**: `1.21.1`
- **NeoForge**: `21.1.267`
- **最終更新**: `2026-11-24 18:45:53 JST`
- **現在のMOD一覧**: [MODLIST.md](./MODLIST.md)

## 使い方（Windows）
1. `SyncMods_Windows.bat` をダウンロードして適当なフォルダに置く（初回のみ）
2. **`SyncMods_Windows.bat` をダブルクリック**
3. 初回だけ CurseForge App 等のインスタンスフォルダを番号で選択（2回目以降は自動記憶！）
4. 完了したらそのまま Minecraft を起動してサーバーへ接続！

## 使い方（Mac）
1. `SyncMods_Mac.command` をダウンロード（初回のみ）
2. 右クリック →「開く」で実行し、インスタンスフォルダを選択

> 個人的に入れているシェーダーやクライアント専用MOD（Iris / Sodium 等）は削除されず、そのまま残ります。
> 入れ替わった旧バージョンのMODは念のため `backup/sync_removed_*` に退避されます。
