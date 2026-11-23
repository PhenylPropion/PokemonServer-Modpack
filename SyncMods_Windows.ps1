param(
    [string]$RawBaseUrl = "__RAW_BASE_URL__",
    [string]$InstancePath = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  PokemonServer MOD環境 自動同期ツール (Windows)" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

if ($RawBaseUrl -eq "__RAW_BASE_URL__" -or [string]::IsNullOrWhiteSpace($RawBaseUrl)) {
    Write-Host "[エラー] GitHubのURLが未設定です。サーバー管理者に最新の同期スクリプトをもらってください。" -ForegroundColor Red
    exit 1
}

$RawBaseUrl = $RawBaseUrl.TrimEnd("/")
$ManifestUrl = "$RawBaseUrl/pack_manifest.json"
$TargetSaveFile = Join-Path $PSScriptRoot ".mc_sync_target.txt"

# 1. インスタンスフォルダを選択または復元
if ([string]::IsNullOrWhiteSpace($InstancePath)) {
    if (Test-Path -LiteralPath $TargetSaveFile) {
        $saved = (Get-Content -LiteralPath $TargetSaveFile -Raw -Encoding UTF8).Trim()
        if ($saved -and (Test-Path -LiteralPath $saved)) {
            $InstancePath = $saved
            Write-Host "前回の対象フォルダを使用します: $InstancePath" -ForegroundColor Gray
            $change = Read-Host "このまま同期しますか？ [Enter=続行 / c=フォルダ変更]"
            if ($change -eq "c" -or $change -eq "C") {
                $InstancePath = ""
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($InstancePath)) {
    $candidates = @()
    $searchRoots = @(
        (Join-Path $env:USERPROFILE "curseforge\minecraft\Instances"),
        (Join-Path $env:APPDATA "PrismLauncher\instances"),
        (Join-Path $env:APPDATA "ModrinthApp\profiles")
    )
    foreach ($root in $searchRoots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
                $mcSub = Join-Path $_.FullName ".minecraft"
                if (Test-Path -LiteralPath $mcSub) {
                    $candidates += $mcSub
                } else {
                    $candidates += $_.FullName
                }
            }
        }
    }

    Write-Host ""
    Write-Host "同期先の Minecraft インスタンスフォルダを選んでください:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $candidates[$i])
    }
    Write-Host "  [0] フォルダパスを手動で入力する"
    $pick = Read-Host "番号を入力"
    if ($pick -match "^\d+$" -and [int]$pick -ge 1 -and [int]$pick -le $candidates.Count) {
        $InstancePath = $candidates[[int]$pick - 1]
    } else {
        $InstancePath = (Read-Host "インスタンスフォルダのフルパスを貼り付けてください").Trim('"').Trim()
    }

    if (-not (Test-Path -LiteralPath $InstancePath)) {
        Write-Host "[エラー] フォルダが見つかりません: $InstancePath" -ForegroundColor Red
        exit 1
    }
    Set-Content -LiteralPath $TargetSaveFile -Value $InstancePath -Encoding UTF8
}

# 2. GitHub から最新マニフェストを取得
Write-Host ""
Write-Host "最新のMOD構成を取得中: $ManifestUrl" -ForegroundColor Cyan
$manifest = Invoke-RestMethod -Uri $ManifestUrl -Headers @{ "User-Agent" = "PokemonServer-ClientSync/1.0" }

Write-Host ("  サーバー構成: Minecraft {0} / NeoForge {1}" -f $manifest.minecraft_version, $manifest.neoforge_version) -ForegroundColor Green
Write-Host ("  最終更新日時: {0}" -f $manifest.updated_at) -ForegroundColor Gray
$cfgCount = if ($manifest.config_bundle) { $manifest.config_bundle.file_count } else { 0 }
Write-Host ("  対象: MOD {0}個 / ResourcePack {1}個 / Config {2}個" -f $manifest.mods.Count, $manifest.resourcepacks.Count, $cfgCount) -ForegroundColor Gray

# NeoForge バージョン確認 (CurseForge minecraftinstance.json がある場合)
$cfInstFile = Join-Path $InstancePath "minecraftinstance.json"
if (Test-Path -LiteralPath $cfInstFile) {
    try {
        $cfRaw = Get-Content -LiteralPath $cfInstFile -Raw -Encoding UTF8
        if ($cfRaw -match '"neoforge-([0-9.]+)"') {
            $localNf = $Matches[1]
            if ($localNf -ne $manifest.neoforge_version) {
                Write-Host ""
                Write-Host ("[注意] ローカルの NeoForge は {0} ですが、サーバーは {1} です。" -f $localNf, $manifest.neoforge_version) -ForegroundColor Yellow
                Write-Host "       もしログイン時にエラーが出たら、ランチャーのプロフィール設定で NeoForge バージョンを揃えてください。" -ForegroundColor Yellow
            }
        }
    } catch {}
}

$StatePath = Join-Path $InstancePath ".mc_server_sync_state.json"
$PrevState = @{ mods = @{}; resourcepacks = @{}; config_bundle_sha1 = "" }
if (Test-Path -LiteralPath $StatePath) {
    try {
        $loaded = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($loaded.mods) { foreach ($p in $loaded.mods.PSObject.Properties) { $PrevState.mods[$p.Name] = $p.Value } }
        if ($loaded.resourcepacks) { foreach ($p in $loaded.resourcepacks.PSObject.Properties) { $PrevState.resourcepacks[$p.Name] = $p.Value } }
        if ($loaded.config_bundle_sha1) { $PrevState.config_bundle_sha1 = $loaded.config_bundle_sha1 }
    } catch {}
}

$BackupRoot = Join-Path $InstancePath ("backup\sync_removed_" + (Get-Date -Format "yyyyMMdd_HHmmss"))

function Backup-OldFile($filePath, $subDir) {
    if (-not (Test-Path -LiteralPath $filePath)) { return }
    if ($DryRun) {
        Write-Host ("  [DryRun/退避] {0}" -f (Split-Path $filePath -Leaf)) -ForegroundColor Yellow
        return
    }
    $destDir = Join-Path $BackupRoot $subDir
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Move-Item -LiteralPath $filePath -Destination (Join-Path $destDir (Split-Path $filePath -Leaf)) -Force
}

function Sync-FileGroup($entries, $relFolder, $prevMap) {
    $dir = Join-Path $InstancePath $relFolder
    if (-not (Test-Path -LiteralPath $dir)) {
        if (-not $DryRun) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    $newMap = @{}
    $desiredByName = @{}
    $desiredKeys = @{}
    foreach ($e in $entries) {
        $desiredByName[$e.filename.ToLower()] = $e
        if ($e.key) { $desiredKeys[$e.key] = $e }
    }

    # 1. 前回このツールが管理していた旧版・削除済みファイルを退避（個人のクライアント専用MODは触らない）
    $removed = 0
    foreach ($oldName in $prevMap.Keys) {
        if (-not $desiredByName.ContainsKey($oldName.ToLower())) {
            $oldFull = Join-Path $dir $oldName
            if (Test-Path -LiteralPath $oldFull) {
                Backup-OldFile $oldFull $relFolder
                Write-Host ("  [削除/退避] {0}/{1}" -f $relFolder, $oldName) -ForegroundColor Yellow
                $removed++
            }
        }
    }

    # 初回実行時でも、同じMODの旧バージョンがあればプレフィックス一致で自動退避
    $existingFiles = @()
    if (Test-Path -LiteralPath $dir) {
        $existingFiles = Get-ChildItem -LiteralPath $dir -File
    }
    $existingHashes = @{}
    foreach ($ef in $existingFiles) {
        $existingHashes[$ef.Name.ToLower()] = (Get-FileHash -LiteralPath $ef.FullName -Algorithm SHA1).Hash.ToLower()
    }

    $downloaded = 0
    $skipped = 0
    $failed = 0

    foreach ($e in $entries) {
        $fn = $e.filename
        $dest = Join-Path $dir $fn
        $expectedSha1 = ($e.sha1).ToLower()
        $newMap[$fn] = $e.key

        if ($existingHashes.ContainsKey($fn.ToLower()) -and $existingHashes[$fn.ToLower()] -eq $expectedSha1) {
            $skipped++
            continue
        }

        # 同名別ハッシュまたは同一prefixの旧版ファイルを退避
        if ($e.prefix) {
            foreach ($ef in $existingFiles) {
                if ($ef.Name.ToLower() -ne $fn.ToLower() -and -not $desiredByName.ContainsKey($ef.Name.ToLower())) {
                    if ($ef.Name.ToLower().StartsWith($e.prefix.ToLower())) {
                        Backup-OldFile $ef.FullName $relFolder
                        Write-Host ("  [旧版退避]  {0}/{1} -> {2}" -f $relFolder, $ef.Name, $fn) -ForegroundColor Yellow
                        $removed++
                    }
                }
            }
        }

        if ($DryRun) {
            Write-Host ("  [DryRun/DL] {0}/{1}" -f $relFolder, $fn) -ForegroundColor Cyan
            $downloaded++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($e.url)) {
            Write-Host ("  [スキップ]  {0}: URL未登録" -f $fn) -ForegroundColor Red
            $failed++
            continue
        }

        Write-Host ("  [DL] {0}/{1} ..." -f $relFolder, $fn) -ForegroundColor Cyan
        $tmp = "$dest.downloading"
        try {
            Invoke-WebRequest -Uri $e.url -OutFile $tmp -Headers @{ "User-Agent" = "PokemonServer-ClientSync/1.0" }
            $gotHash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA1).Hash.ToLower()
            if ($expectedSha1 -and $gotHash -ne $expectedSha1) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                Write-Host ("  [失敗] {0}: ハッシュ不一致" -f $fn) -ForegroundColor Red
                $failed++
                continue
            }
            Move-Item -LiteralPath $tmp -Destination $dest -Force
            $downloaded++
        } catch {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Write-Host ("  [失敗] {0}: {1}" -f $fn, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    }

    Write-Host ("  => {0}: 最新済み {1} / 取得 {2} / 旧版退避 {3} / 失敗 {4}" -f $relFolder, $skipped, $downloaded, $removed, $failed) -ForegroundColor Green
    return $newMap
}

Write-Host ""
Write-Host "--- MOD 同期 ---" -ForegroundColor Cyan
$newModsMap = Sync-FileGroup $manifest.mods "mods" $PrevState.mods

# サーバー外に追加されているMODの自動チェック（クライアント専用は維持、両側必須MODは自動退避）
$modsDir = Join-Path $InstancePath "mods"
if (Test-Path -LiteralPath $modsDir) {
    $desiredSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $manifest.mods) { [void]$desiredSet.Add($m.filename) }
    $extraJars = @(Get-ChildItem -LiteralPath $modsDir -File -Filter "*.jar" | Where-Object { -not $desiredSet.Contains($_.Name) })

    if ($extraJars.Count -gt 0) {
        Write-Host ""
        Write-Host ("--- 追加MODチェック ({0} 個のサーバー外MODを検査中) ---" -f $extraJars.Count) -ForegroundColor Cyan
        $allowedPats = @()
        if ($manifest.client_allowed_patterns) { $allowedPats = @($manifest.client_allowed_patterns) }

        $clientOk = @()
        $serverReq = @()
        $unknown = @()
        $needApi = @()

        foreach ($jar in $extraJars) {
            $matchedAllow = $false
            foreach ($pat in $allowedPats) {
                if ($jar.Name -like $pat) { $matchedAllow = $true; break }
            }
            if ($matchedAllow) {
                $clientOk += @{ File = $jar; Reason = "定番クライアントMOD" }
            } else {
                $needApi += $jar
            }
        }

        if ($needApi.Count -gt 0) {
            $hashMap = @{}
            foreach ($jar in $needApi) {
                $h = (Get-FileHash -LiteralPath $jar.FullName -Algorithm SHA1).Hash.ToLower()
                if (-not $hashMap.ContainsKey($h)) { $hashMap[$h] = @() }
                $hashMap[$h] += $jar
            }

            $verByHash = $null
            $projById = @{}
            try {
                $body = @{ hashes = @($hashMap.Keys); algorithm = "sha1" } | ConvertTo-Json
                $verByHash = Invoke-RestMethod -Method Post -Uri "https://api.modrinth.com/v2/version_files" -ContentType "application/json" -Body $body -Headers @{ "User-Agent" = "PokemonServer-ClientSync/1.0" }
                $pids = @()
                foreach ($prop in $verByHash.PSObject.Properties) {
                    if ($prop.Value.project_id) { $pids += $prop.Value.project_id }
                }
                $pids = @($pids | Select-Object -Unique)
                if ($pids.Count -gt 0) {
                    $idsParam = [Uri]::EscapeDataString(($pids | ConvertTo-Json -Compress))
                    if ($pids.Count -eq 1) { $idsParam = [Uri]::EscapeDataString("[`"$($pids[0])`"]") }
                    $projs = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/projects?ids=$idsParam" -Headers @{ "User-Agent" = "PokemonServer-ClientSync/1.0" }
                    foreach ($pr in $projs) { $projById[$pr.id] = $pr }
                }
            } catch {}

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            foreach ($h in $hashMap.Keys) {
                $pr = $null
                if ($verByHash -and $verByHash.PSObject.Properties[$h]) {
                    $pidVal = $verByHash.PSObject.Properties[$h].Value.project_id
                    if ($pidVal -and $projById.ContainsKey($pidVal)) { $pr = $projById[$pidVal] }
                }
                foreach ($jar in $hashMap[$h]) {
                    if ($pr) {
                        $ss = ($pr.server_side).ToLower()
                        if ($ss -eq "unsupported" -or $ss -eq "optional") {
                            $clientOk += @{ File = $jar; Reason = "Modrinth判定: クライアント専用 ($($pr.title))" }
                            continue
                        } elseif ($ss -eq "required") {
                            $serverReq += @{ File = $jar; Reason = "Modrinth判定: サーバー必須MOD ($($pr.title))" }
                            continue
                        }
                    }
                    # Fallback: neoforge.mods.toml 判定
                    $isClientToml = $false
                    try {
                        $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
                        $entry = $zip.GetEntry("META-INF/neoforge.mods.toml")
                        if (-not $entry) { $entry = $zip.GetEntry("META-INF/mods.toml") }
                        if ($entry) {
                            $sr = New-Object System.IO.StreamReader($entry.Open())
                            $txt = $sr.ReadToEnd(); $sr.Close()
                            if ($txt -match 'displayTest\s*=\s*"(IGNORE_ALL_VERSION|NONE)"') {
                                $isClientToml = $true
                            } else {
                                $sideMatches = [regex]::Matches($txt, 'side\s*=\s*"(CLIENT|SERVER|BOTH)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                                $sides = @($sideMatches | ForEach-Object { $_.Groups[1].Value.ToUpper() } | Select-Object -Unique)
                                if ($sides.Count -eq 1 -and $sides[0] -eq "CLIENT") { $isClientToml = $true }
                            }
                        }
                        $zip.Dispose()
                    } catch {}

                    if ($isClientToml) {
                        $clientOk += @{ File = $jar; Reason = "mods.toml判定: クライアント専用" }
                    } else {
                        $unknown += @{ File = $jar; Reason = "サイド不明" }
                    }
                }
            }
        }

        foreach ($c in $clientOk) {
            Write-Host ("  [そのまま維持] {0} ({1})" -f $c.File.Name, $c.Reason) -ForegroundColor Green
        }
        foreach ($s in $serverReq) {
            Write-Host ("  [接続不可/自動退避] {0} ({1})" -f $s.File.Name, $s.Reason) -ForegroundColor Red
            Backup-OldFile $s.File.FullName "incompatible_mods"
        }
        if ($unknown.Count -gt 0) {
            Write-Host ""
            Write-Host "  [?] サーバーに無く、クライアント専用か自動判定できないMODが見つかりました:" -ForegroundColor Yellow
            foreach ($u in $unknown) { Write-Host ("      - {0}" -f $u.File.Name) -ForegroundColor Yellow }
            if (-not $DryRun) {
                $ans = Read-Host "  これらが両側MODだと接続エラーになります。バックアップへ退避しますか？ [Y/n]"
                if ([string]::IsNullOrWhiteSpace($ans) -or $ans -match "^[Yy]") {
                    foreach ($u in $unknown) {
                        Backup-OldFile $u.File.FullName "unknown_extra_mods"
                        Write-Host ("  [退避] {0}" -f $u.File.Name) -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "  そのまま残しました（接続エラーが出た場合は外してください）。" -ForegroundColor Gray
                }
            }
        }
    }
}

$newRpMap = @{}
if ($manifest.resourcepacks.Count -gt 0) {
    Write-Host ""
    Write-Host "--- ResourcePack 同期 ---" -ForegroundColor Cyan
    $newRpMap = Sync-FileGroup $manifest.resourcepacks "resourcepacks" $PrevState.resourcepacks
}

$newConfigBundleSha1 = $PrevState.config_bundle_sha1
if ($manifest.config_bundle -and $manifest.config_bundle.sha1) {
    Write-Host ""
    Write-Host "--- Config (バランス調整設定) 同期 ---" -ForegroundColor Cyan
    $targetSha1 = ($manifest.config_bundle.sha1).ToLower()
    if ($PrevState.config_bundle_sha1 -eq $targetSha1) {
        Write-Host ("  => config: 最新済み ({0} ファイル)" -f $manifest.config_bundle.file_count) -ForegroundColor Green
    } elseif ($DryRun) {
        Write-Host ("  [DryRun/Config] config_bundle.zip ({0} ファイル) を適用予定" -f $manifest.config_bundle.file_count) -ForegroundColor Cyan
    } else {
        $zipUrl = "$RawBaseUrl/$($manifest.config_bundle.filename)"
        $tmpZip = Join-Path $InstancePath "config_bundle.zip.downloading"
        try {
            Write-Host "  [DL] config_bundle.zip を取得中..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -Headers @{ "User-Agent" = "PokemonServer-ClientSync/1.0" }
            $gotHash = (Get-FileHash -LiteralPath $tmpZip -Algorithm SHA1).Hash.ToLower()
            if ($gotHash -ne $targetSha1) {
                Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
                Write-Host "  [失敗/Config] ハッシュ不一致のためスキップしました" -ForegroundColor Red
            } else {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
                foreach ($entry in $zip.Entries) {
                    if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                    $relPath = $entry.FullName -replace "/", "\"
                    $destPath = Join-Path $InstancePath $relPath
                    $destDir = Split-Path $destPath -Parent
                    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
                }
                $zip.Dispose()
                Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
                $newConfigBundleSha1 = $targetSha1
                Write-Host ("  => config: {0} ファイルを一括同期しました" -f $manifest.config_bundle.file_count) -ForegroundColor Green
            }
        } catch {
            Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
            Write-Host ("  [失敗/Config] {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }
}

if (-not $DryRun) {
    $newState = @{
        updated_at         = $manifest.updated_at
        mods               = $newModsMap
        resourcepacks      = $newRpMap
        config_bundle_sha1 = $newConfigBundleSha1
    }
    $newState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  同期完了！Minecraft を起動してサーバーへ接続できます！" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
