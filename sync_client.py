#!/usr/bin/env python3
"""Cross-platform (macOS/Linux/Windows) 1-click Minecraft client MOD/config sync script."""

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import sys
import time
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

RAW_BASE_URL = "https://raw.githubusercontent.com/PhenylPropion/PokemonServer-Modpack/season2"
USER_AGENT = "PokemonServer-ClientSync/1.0"


def sha1_file(path: Path) -> str:
    h = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest().lower()


def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def download_file(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    tmp = dest.with_suffix(dest.suffix + ".downloading")
    with urllib.request.urlopen(req, timeout=60) as r, tmp.open("wb") as out:
        shutil.copyfileobj(r, out)
    os.replace(tmp, dest)


def detect_instances():
    home = Path.home()
    roots = [
        home / "Documents/curseforge/minecraft/Instances",
        home / "curseforge/minecraft/Instances",
        home / "Library/Application Support/PrismLauncher/instances",
        home / "Library/Application Support/ModrinthApp/profiles",
        home / ".local/share/PrismLauncher/instances",
    ]
    found = []
    for root in roots:
        if root.is_dir():
            for child in sorted(root.iterdir()):
                if child.is_dir():
                    mc = child / ".minecraft"
                    found.append(mc if mc.is_dir() else child)
    return found


def pick_instance(cli_path: str, script_dir: Path) -> Path:
    if cli_path:
        p = Path(cli_path).expanduser().resolve()
        if not p.is_dir():
            raise SystemExit(f"[エラー] フォルダが見つかりません: {p}")
        return p

    save_file = script_dir / ".mc_sync_target.txt"
    if save_file.exists():
        saved = Path(save_file.read_text(encoding="utf-8").strip())
        if saved.is_dir():
            print(f"前回の対象フォルダ: {saved}")
            ans = input("このまま同期しますか？ [Enter=続行 / c=変更]: ").strip().lower()
            if ans != "c":
                return saved

    candidates = detect_instances()
    print("\n同期先の Minecraft インスタンスフォルダを選んでください:")
    for i, c in enumerate(candidates, 1):
        print(f"  [{i}] {c}")
    print("  [0] フォルダパスを手動入力")
    pick = input("番号を入力: ").strip()
    if pick.isdigit() and 1 <= int(pick) <= len(candidates):
        chosen = candidates[int(pick) - 1]
    else:
        chosen = Path(input("フォルダのフルパスを入力: ").strip().strip('"').strip("'")).expanduser().resolve()

    if not chosen.is_dir():
        raise SystemExit(f"[エラー] フォルダが見つかりません: {chosen}")
    save_file.write_text(str(chosen) + "\n", encoding="utf-8")
    return chosen


def sync_group(entries, inst_dir: Path, rel_folder: str, prev_map: dict, backup_root: Path, dry_run: bool) -> dict:
    folder = inst_dir / rel_folder
    if not dry_run:
        folder.mkdir(parents=True, exist_ok=True)

    desired_by_name = {e["filename"].lower(): e for e in entries}
    new_map = {}

    def backup_old(p: Path):
        if not p.exists():
            return
        if dry_run:
            print(f"  [DryRun/退避] {rel_folder}/{p.name}")
            return
        bdir = backup_root / rel_folder
        bdir.mkdir(parents=True, exist_ok=True)
        shutil.move(str(p), str(bdir / p.name))

    removed = 0
    for old_name in prev_map:
        if old_name.lower() not in desired_by_name:
            old_p = folder / old_name
            if old_p.exists():
                backup_old(old_p)
                print(f"  [削除/退避] {rel_folder}/{old_name}")
                removed += 1

    existing_files = [p for p in folder.iterdir() if p.is_file()] if folder.is_dir() else []
    existing_hashes = {p.name.lower(): sha1_file(p) for p in existing_files}

    downloaded = skipped = failed = 0
    for e in entries:
        fn = e["filename"]
        dest = folder / fn
        expected_sha1 = (e.get("sha1") or "").lower()
        new_map[fn] = e.get("key", "")

        if fn.lower() in existing_hashes and existing_hashes[fn.lower()] == expected_sha1:
            skipped += 1
            continue

        prefix = (e.get("prefix") or "").lower()
        if prefix:
            for ef in existing_files:
                if ef.name.lower() != fn.lower() and ef.name.lower() not in desired_by_name:
                    if ef.name.lower().startswith(prefix) and ef.exists():
                        backup_old(ef)
                        print(f"  [旧版退避]  {rel_folder}/{ef.name} -> {fn}")
                        removed += 1

        if dry_run:
            print(f"  [DryRun/DL] {rel_folder}/{fn}")
            downloaded += 1
            continue

        url = e.get("url")
        if not url:
            print(f"  [スキップ]  {fn}: URL未登録")
            failed += 1
            continue

        print(f"  [DL] {rel_folder}/{fn} ...")
        try:
            download_file(url, dest)
            if expected_sha1 and sha1_file(dest) != expected_sha1:
                dest.unlink(missing_ok=True)
                print(f"  [失敗] {fn}: SHA1不一致")
                failed += 1
                continue
            downloaded += 1
        except Exception as ex:
            print(f"  [失敗] {fn}: {ex}")
            failed += 1

    print(f"  => {rel_folder}: 最新済み {skipped} / 取得 {downloaded} / 旧版退避 {removed} / 失敗 {failed}")
    return new_map


def post_json(url: str, payload: dict) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"User-Agent": USER_AGENT, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def is_client_only_by_toml(jar_path: Path) -> bool:
    try:
        with zipfile.ZipFile(jar_path, "r") as z:
            for name in ("META-INF/neoforge.mods.toml", "META-INF/mods.toml"):
                if name in z.namelist():
                    txt = z.read(name).decode("utf-8", errors="ignore")
                    if re.search(r'displayTest\s*=\s*"(IGNORE_ALL_VERSION|NONE)"', txt):
                        return True
                    # If mod declares side="CLIENT" and does NOT declare side="BOTH" or "SERVER"
                    sides = set(m.upper() for m in re.findall(r'side\s*=\s*"(CLIENT|SERVER|BOTH)"', txt, re.I))
                    if sides == {"CLIENT"}:
                        return True
    except Exception:
        pass
    return False


def classify_extra_mods(extra_paths, allowed_patterns):
    """Classify unmanaged extra .jar files in client mods/ into (client_ok, server_required, unknown)."""
    client_ok, server_req, unknown = [], [], []
    if not extra_paths:
        return client_ok, server_req, unknown

    need_api = []
    for p in extra_paths:
        low = p.name.lower()
        if any(fnmatch.fnmatch(low, pat.lower()) for pat in allowed_patterns):
            client_ok.append((p, "定番クライアントMOD"))
        else:
            need_api.append(p)

    if not need_api:
        return client_ok, server_req, unknown

    # Batch Modrinth SHA1 lookup -> project server_side check
    hash_to_paths = {}
    for p in need_api:
        hash_to_paths.setdefault(sha1_file(p), []).append(p)

    ver_by_hash = {}
    proj_by_id = {}
    try:
        hashes = list(hash_to_paths.keys())
        for i in range(0, len(hashes), 100):
            ver_by_hash.update(post_json("https://api.modrinth.com/v2/version_files", {"hashes": hashes[i : i + 100], "algorithm": "sha1"}))
        pids = list({v["project_id"] for v in ver_by_hash.values() if v.get("project_id")})
        for i in range(0, len(pids), 100):
            qs = urllib.parse.urlencode({"ids": json.dumps(pids[i : i + 100])})
            for pr in fetch_json(f"https://api.modrinth.com/v2/projects?{qs}"):
                proj_by_id[pr["id"]] = pr
    except Exception:
        pass

    for h, paths in hash_to_paths.items():
        ver = ver_by_hash.get(h)
        pr = proj_by_id.get(ver["project_id"]) if ver and ver.get("project_id") else None
        for p in paths:
            if pr:
                ss = (pr.get("server_side") or "").lower()
                title = pr.get("title") or p.name
                if ss in ("unsupported", "optional"):
                    client_ok.append((p, f"Modrinth判定: クライアント専用 ({title})"))
                    continue
                if ss == "required":
                    server_req.append((p, f"Modrinth判定: サーバー必須MOD ({title})"))
                    continue
            if is_client_only_by_toml(p):
                client_ok.append((p, "mods.toml判定: クライアント専用"))
            else:
                unknown.append((p, "配布元/サイド不明"))

    return client_ok, server_req, unknown


def main():
    parser = argparse.ArgumentParser(description="PokemonServer client modpack sync")
    parser.add_argument("--manifest", help="ローカルまたはURLの pack_manifest.json を指定")
    parser.add_argument("--raw-base-url", default=RAW_BASE_URL, help="GitHub Raw Base URL")
    parser.add_argument("--instance", default="", help="同期先のMinecraftインスタンスフォルダ")
    parser.add_argument("--dry-run", action="store_true", help="実際には変更せず差分だけ確認")
    args = parser.parse_args()

    print("========================================================")
    print("  PokemonServer MOD環境 自動同期ツール")
    print("========================================================")

    raw_base = (args.raw_base_url or "").rstrip("/")
    if args.manifest and Path(args.manifest).is_file():
        manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
        local_repo_root = Path(args.manifest).resolve().parent
    else:
        if not raw_base or not raw_base.startswith(("http://", "https://")):
            raise SystemExit("[エラー] GitHub Raw URL が未設定です。")
        manifest_url = args.manifest or f"{raw_base}/pack_manifest.json"
        print(f"最新マニフェスト取得中: {manifest_url}")
        manifest = fetch_json(manifest_url)
        local_repo_root = None

    inst_dir = pick_instance(args.instance, Path(__file__).resolve().parent)
    cfg_count = (manifest.get("config_bundle") or {}).get("file_count", 0)
    print(f"\nサーバー構成: Minecraft {manifest['minecraft_version']} / NeoForge {manifest['neoforge_version']}")
    print(f"最終更新: {manifest['updated_at']}")
    print(f"対象: MOD {len(manifest['mods'])}個 / ResourcePack {len(manifest['resourcepacks'])}個 / Config {cfg_count}個")

    cf_inst = inst_dir / "minecraftinstance.json"
    if cf_inst.exists():
        m = re.search(r'"neoforge-([0-9.]+)"', cf_inst.read_text(encoding="utf-8", errors="ignore"))
        if m and m.group(1) != manifest["neoforge_version"]:
            print(f"\n[注意] ローカル NeoForge ({m.group(1)}) != サーバー ({manifest['neoforge_version']})")

    state_path = inst_dir / ".mc_server_sync_state.json"
    prev_state = {"mods": {}, "resourcepacks": {}}
    if state_path.exists():
        try:
            prev_state = json.loads(state_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    backup_root = inst_dir / "backup" / ("sync_removed_" + time.strftime("%Y%m%d_%H%M%S"))

    print("\n--- MOD 同期 ---")
    new_mods = sync_group(manifest["mods"], inst_dir, "mods", prev_state.get("mods", {}), backup_root, args.dry_run)

    # Check any extra unmanaged .jar files left in mods/ (keep client-only, quarantine server+client mods!)
    mods_dir = inst_dir / "mods"
    if mods_dir.is_dir():
        desired_lower = {e["filename"].lower() for e in manifest["mods"]}
        extra_jars = sorted(p for p in mods_dir.glob("*.jar") if p.name.lower() not in desired_lower)
        if extra_jars:
            print(f"\n--- 追加MODチェック ({len(extra_jars)} 個のサーバー外MODを検査中) ---")
            client_ok, server_req, unknown = classify_extra_mods(
                extra_jars, manifest.get("client_allowed_patterns") or []
            )
            for p, reason in client_ok:
                print(f"  [そのまま維持] {p.name} ({reason})")
            for p, reason in server_req:
                print(f"  [⚠️ 接続不可/自動退避] {p.name} ({reason})")
                if not args.dry_run:
                    bdir = backup_root / "incompatible_mods"
                    bdir.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(p), str(bdir / p.name))
            if unknown:
                print("\n  [?] サーバーに無く、クライアント専用か自動判定できないMODが見つかりました:")
                for p, _ in unknown:
                    print(f"      - {p.name}")
                if args.dry_run:
                    print("  [DryRun] 実実行時はこれらを退避するか確認します。")
                else:
                    ans = input("  これらが両側MODだと接続エラーになります。バックアップへ退避しますか？ (Y/n): ").strip().lower()
                    if ans in ("", "y", "yes"):
                        bdir = backup_root / "unknown_extra_mods"
                        bdir.mkdir(parents=True, exist_ok=True)
                        for p, _ in unknown:
                            shutil.move(str(p), str(bdir / p.name))
                            print(f"  [退避] {p.name}")
                    else:
                        print("  そのまま残しました（もし接続エラーが出たら外してください）。")

    new_rps = {}
    if manifest.get("resourcepacks"):
        print("\n--- ResourcePack 同期 ---")
        new_rps = sync_group(
            manifest["resourcepacks"], inst_dir, "resourcepacks", prev_state.get("resourcepacks", {}), backup_root, args.dry_run
        )

    new_cfg_sha1 = prev_state.get("config_bundle_sha1", "")
    cb = manifest.get("config_bundle")
    if cb and cb.get("sha1"):
        print("\n--- Config (バランス調整設定) 同期 ---")
        target_sha1 = cb["sha1"].lower()
        if new_cfg_sha1 == target_sha1:
            print(f"  => config: 最新済み ({cb['file_count']} ファイル)")
        elif args.dry_run:
            print(f"  [DryRun/Config] {cb['filename']} ({cb['file_count']} ファイル) を適用予定")
        else:
            tmp_zip = inst_dir / "config_bundle.zip.downloading"
            try:
                if local_repo_root is not None:
                    shutil.copy2(local_repo_root / cb["filename"], tmp_zip)
                else:
                    print(f"  [DL] {cb['filename']} を取得中...")
                    download_file(f"{raw_base}/{cb['filename']}", tmp_zip)
                if sha1_file(tmp_zip) != target_sha1:
                    tmp_zip.unlink(missing_ok=True)
                    print("  [失敗/Config] ハッシュ不一致のためスキップしました")
                else:
                    with zipfile.ZipFile(tmp_zip, "r") as zf:
                        for member in zf.namelist():
                            if member.endswith("/") or ".." in Path(member).parts:
                                continue
                            dest = inst_dir / member
                            dest.parent.mkdir(parents=True, exist_ok=True)
                            dest.write_bytes(zf.read(member))
                    tmp_zip.unlink(missing_ok=True)
                    new_cfg_sha1 = target_sha1
                    print(f"  => config: {cb['file_count']} ファイルを一括同期しました")
            except Exception as ex:
                tmp_zip.unlink(missing_ok=True)
                print(f"  [失敗/Config] {ex}")

    if not args.dry_run:
        state_path.write_text(
            json.dumps(
                {
                    "updated_at": manifest["updated_at"],
                    "mods": new_mods,
                    "resourcepacks": new_rps,
                    "config_bundle_sha1": new_cfg_sha1,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    print("\n========================================================")
    print("  同期完了！Minecraft を起動してサーバーへ接続できます！")
    print("========================================================")


if __name__ == "__main__":
    main()
