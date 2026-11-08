# 中創園區 程式更新信箱 (update_cmd.ps1)  2026-11-08
# Cliff 2026-11-08 授權（決策卡）：讓 Claude 透過指令信箱遠端更新機房電腦上的程式，但每次都要 Cliff 回「執行」。
# 兩台電腦都裝：空調監控主機 -PC ac、監控電腦 -PC bms。排程 CTIC_Update_Cmd 每 5 分鐘跑一次。
# 讀 GitHub tsaitzuchien-star/ctic-ems-dashboard 的 ems-commands 分支 commands/update_cmd.json：
#   {"id":"...","requested_by":"Cliff Tsai","approved_at":"...+08:00","expires":"...","note":"...",
#    "sha":"<主線上的 40 碼 commit>","files":[{"pc":"bms","file":"tools/line_push.py"}, ...]}
# 寫死的安全規則：
#   1) sha 必須是 main 分支上已合併的 commit（用 GitHub API 比對），否則整筆不做。
#   2) 只能覆蓋下面 $ALLOW 列出的既有程式檔，其他路徑一律擋下。
#   3) 要有 id（只做一次）、過期時間（核准後 24 小時內）。
#   4) 下載後先檢查語法（.ps1 用 PowerShell 解析、.py 用 python 編譯），不過就不換。
#   5) 舊檔先備份到 C:\BMS_Export\backup\，換完需要時重啟對應排程（schtasks /End 再 /Run）。
# 停用：在 C:\BMS_Export 放 update_cmd_off.txt。結果：update_cmd_result.json（監控電腦 line_push 讀到後推 LINE）。
param([Parameter(Mandatory = $true)][ValidateSet('ac', 'bms')][string]$PC, [string]$File)
$ErrorActionPreference = 'Stop'
$Out = $(if ($env:CTIC_OUT) { $env:CTIC_OUT } else { 'C:\BMS_Export' })   # CTIC_OUT 只給測試用
$Repo = 'tsaitzuchien-star/ctic-ems-dashboard'
$Api = "https://api.github.com/repos/$Repo"
$CmdUrl = "$Api/contents/commands/update_cmd.json?ref=ems-commands"
$DoneFile = Join-Path $Out 'update_cmd_done.txt'
$ResultFile = Join-Path $Out 'update_cmd_result.json'
$Log = Join-Path $Out 'update_cmd.log'
$inv = [Globalization.CultureInfo]::InvariantCulture

# 可更新的檔案：repo 路徑 → 本機路徑、換完要重啟的排程（空字串 = 下次排程自然會用新版）
$ALLOW = @{
  ac  = @{
    'tools/ac_logger.ps1'  = @{ to = 'ac_logger.ps1';  task = 'CTIC_AC_Logger' }
    'tools/sched_cmd.ps1'  = @{ to = 'sched_cmd.ps1';  task = '' }
    'tools/mag_auto.ps1'   = @{ to = 'mag_auto.ps1';   task = 'CTIC_Mag_Auto' }
    'tools/fcu_guard.ps1'  = @{ to = 'fcu_guard.ps1';  task = '' }
    'tools/update_cmd.ps1' = @{ to = 'update_cmd.ps1'; task = '' }
  }
  bms = @{
    'tools/local_live.py'     = @{ to = 'local_live.py';     task = 'CTIC_Local_Live' }
    'tools/line_push.py'      = @{ to = 'line_push.py';      task = 'CTIC_Local_Live' }
    'tools/ems_calc.py'       = @{ to = 'ems_calc.py';       task = 'CTIC_Local_Live' }
    'tools/circuit_export.py' = @{ to = 'circuit_export.py'; task = '' }
    'index.html'              = @{ to = 'site\index.html';   task = '' }
    'tools/update_cmd.ps1'    = @{ to = 'update_cmd.ps1';    task = '' }
  }
}

function Log($m) { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') $m" | Out-File $Log -Append -Encoding utf8 }
function Save-Result($r) {
  ($r | ConvertTo-Json -Depth 5) | Out-File $ResultFile -Encoding utf8
  Log ("$($r.id) $($r.status) " + (($r.lines) -join ' / '))
  "$($r.id)" | Out-File $DoneFile -Append -Encoding ascii
}
function Gh($url) { Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'ctic-update-cmd'; Accept = 'application/vnd.github+json' } -TimeoutSec 30 }
function Syntax-Ok($path) {
  if ($path -like '*.ps1') {
    $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$e)
    return (-not $e -or $e.Count -eq 0)
  }
  if ($path -like '*.py') {
    $py = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $py) { return $true }                       # 沒有 python 的電腦不會有 .py 檔
    & $py.Source -c "import sys,py_compile; py_compile.compile(sys.argv[1], doraise=True)" $path 2>$null
    return ($LASTEXITCODE -eq 0)
  }
  if ($path -like '*.html') { return ((Get-Content $path -Raw -Encoding utf8) -match '</html>') }
  return $false
}

# ---- 讀指令 ----
if (Test-Path (Join-Path $Out 'update_cmd_off.txt')) { exit 0 }
$mtx = New-Object System.Threading.Mutex($false, 'Global\CTIC_Update_Cmd')
if (-not $mtx.WaitOne(0)) { exit 0 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($File) { $cmd = Get-Content $File -Raw -Encoding utf8 | ConvertFrom-Json }
else {
  try { $r = Gh $CmdUrl; $cmd = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($r.content -replace '\s', ''))) | ConvertFrom-Json }
  catch { if ("$($_.Exception.Message)" -notmatch '404') { Log "fetch failed: $($_.Exception.Message)" }; exit 0 }
}
if (-not $cmd.id) { exit 0 }
$mine = @($cmd.files | Where-Object { "$($_.pc)" -eq $PC })
if ($mine.Count -eq 0) { exit 0 }                         # 這筆沒有要更新這台
$done = @(); if (Test-Path $DoneFile) { $done = @(Get-Content $DoneFile | ForEach-Object { $_.Trim() }) }
if ($done -contains "$($cmd.id)") { exit 0 }

$res = [ordered]@{ id = "$($cmd.id)"; kind = 'update'; pc = $PC; time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss');
                   requested_by = "$($cmd.requested_by)"; note = "$($cmd.note)"; status = ''; lines = @() }
$pcName = $(if ($PC -eq 'ac') { '空調監控主機' } else { '監控電腦' })
try {
  $exp = [datetimeoffset]::Parse("$($cmd.expires)", $inv); $apv = [datetimeoffset]::Parse("$($cmd.approved_at)", $inv)
} catch { $res.status = 'rejected'; $res.lines = @("$pcName：指令沒有正確的核准時間或過期時間"); Save-Result $res; exit 0 }
if ([datetimeoffset]::Now -gt $exp) { $res.status = 'rejected'; $res.lines = @("$pcName：指令已過期"); Save-Result $res; exit 0 }
if (($exp - $apv).TotalHours -gt 24) { $res.status = 'rejected'; $res.lines = @("$pcName：過期時間超過核准後 24 小時"); Save-Result $res; exit 0 }
$sha = "$($cmd.sha)"
if ($sha -notmatch '^[0-9a-f]{40}$') { $res.status = 'rejected'; $res.lines = @("$pcName：sha 格式不對（要 40 碼）"); Save-Result $res; exit 0 }
$bad = @($mine | Where-Object { -not $ALLOW[$PC].ContainsKey("$($_.file)") } | ForEach-Object { "$($_.file)" })
if ($bad.Count) { $res.status = 'rejected'; $res.lines = @("$pcName：不在可更新清單：$($bad -join ', ')"); Save-Result $res; exit 0 }

# sha 一定要在 main 上（compare sha...main：identical 或 ahead 代表 main 已包含它）
if (-not $File) {
  try { $cmp = Gh "$Api/compare/$sha...main" } catch { Log "compare failed: $($_.Exception.Message)"; exit 0 }   # 網路問題，下次再試
  if (@('identical', 'ahead') -notcontains "$($cmp.status)") { $res.status = 'rejected'; $res.lines = @("$pcName：$($sha.Substring(0,7)) 不在主線上（$($cmp.status)），不更新"); Save-Result $res; exit 0 }
}

# ---- 下載、檢查、備份、替換 ----
$tmpDir = Join-Path $Out 'update_tmp'; New-Item -ItemType Directory -Force $tmpDir | Out-Null
$bakDir = Join-Path $Out 'backup'; New-Item -ItemType Directory -Force $bakDir | Out-Null
$staged = @()
foreach ($f in $mine) {
  $a = $ALLOW[$PC]["$($f.file)"]; $tmp = Join-Path $tmpDir ([IO.Path]::GetFileName($a.to))
  try {
    if ($File) { Copy-Item (Join-Path (Split-Path $File) ([IO.Path]::GetFileName($a.to))) $tmp -Force }   # 測試用
    else { Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "https://raw.githubusercontent.com/$Repo/$sha/$($f.file)" -OutFile $tmp }
  } catch { $res.status = 'failed'; $res.lines = @("$pcName：下載 $($f.file) 失敗，全部沒換：$($_.Exception.Message)"); Save-Result $res; exit 0 }
  if ((Get-Item $tmp).Length -lt 200 -or -not (Syntax-Ok $tmp)) { $res.status = 'failed'; $res.lines = @("$pcName：$($f.file) 語法檢查沒過，全部沒換"); Save-Result $res; exit 0 }
  $staged += [pscustomobject]@{ file = "$($f.file)"; tmp = $tmp; dest = (Join-Path $Out $a.to); task = $a.task }
}
$stamp = Get-Date -f 'yyyyMMdd_HHmmss'; $tasks = @()
foreach ($s in $staged) {
  if (Test-Path $s.dest) { Copy-Item $s.dest (Join-Path $bakDir ("{0}.{1}" -f ([IO.Path]::GetFileName($s.dest)), $stamp)) -Force }
  Copy-Item $s.tmp $s.dest -Force
  $res.lines += "$pcName：$($s.file) 已更新（$($sha.Substring(0,7))，舊檔備份 backup\$([IO.Path]::GetFileName($s.dest)).$stamp）"
  if ($s.task -and $tasks -notcontains $s.task) { $tasks += $s.task }
}
$res.status = 'done'
foreach ($t in $tasks) {
  if ($File) { $res.lines += "（測試：不重啟 $t）"; continue }
  schtasks /End /TN $t 2>&1 | Out-Null; Start-Sleep -Seconds 3
  $o = schtasks /Run /TN $t 2>&1
  $res.lines += $(if ($LASTEXITCODE -eq 0) { "已重啟排程 $t" } else { "重啟 $t 失敗：$o ⚠️" })
}
Save-Result $res
