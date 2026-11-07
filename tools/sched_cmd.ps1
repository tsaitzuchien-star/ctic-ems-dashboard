# 中創園區 空調監控主機 排程指令信箱 (sched_cmd.ps1)  2026-11-07
# Cliff 在手機上跟 Claude 確認要改的排程並回「執行」後，Claude 把指令放到 GitHub
# tsaitzuchien-star/ctic-ems-dashboard 的 ems-commands 分支 commands/sched_cmd.json（只有 Cliff 的帳號能寫入）。
# 本程式每 2 分鐘（schtasks CTIC_Sched_Cmd）去讀一次，檢查通過才用 DDE 寫進 InTouch，寫完讀回核對。
#
# 只能改這三種排程（白名單），其他點位一律不碰，也不會按主機啟動／停止：
#   ice  = BCU 製冰 BCU_SCHI_0d_*   melt = BCU 融冰 BCU_SCHW_0d_*   chu2 = 磁浮 CHU2_SCH_0d_*   （d：1 = 星期一 … 7 = 星期日）
# 寫死的硬規則（就算指令是 Claude 下錯也會擋下）：
#   製冰有勾時不能跑進 07:30–22:00；融冰、磁浮不能跨午夜，且要在 07:00–22:00 之內；
#   夏月（5/16–10/15）星期一到五磁浮有勾時，停止時間不能晚於 16:00。
#   指令要有 id、過期時間（核准後 24 小時內），同一個 id 只做一次。指令裡寫 "dry_run": true 就只檢查、不寫。
# 送風機（2026-11-07 起）：kind = fcu，只限下面 $FCU_ALLOW 列的房間（目前只有 B239 = SG_2F31_P25）。
#   {"kind":"fcu","room":"B239","units":["FCU01","FCU02"],"action":"off"|"on"|"setT","value":26}
#   action off/on 寫 _Run（0/1），寫完約 75 秒內看風速狀態確認；setT 只允許 24–28 °C，立即讀回。
#   平日 18:00–07:00 遠端開啟時，若當晚加班名單檔已存在，把房號加進去，避免 fcu_guard 又把它關掉。
# 停用：在 C:\BMS_Export 放 sched_cmd_off.txt。
# 結果：C:\BMS_Export\sched_cmd_result.json（監控電腦讀到後推 LINE）與 sched_cmd.log。
# 測試：powershell -ExecutionPolicy Bypass -File C:\BMS_Export\sched_cmd.ps1 -File 某指令.json -DryRun   （只檢查、不寫）
param([string]$File, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$Out = $(if ($env:CTIC_OUT) { $env:CTIC_OUT } else { 'C:\BMS_Export' })   # CTIC_OUT 只給測試用
$Api = 'https://api.github.com/repos/tsaitzuchien-star/ctic-ems-dashboard/contents/commands/sched_cmd.json?ref=ems-commands'
$RawUrl = 'https://raw.githubusercontent.com/tsaitzuchien-star/ctic-ems-dashboard/ems-commands/commands/sched_cmd.json'
$Off = Join-Path $Out 'sched_cmd_off.txt'
$DoneFile = Join-Path $Out 'sched_cmd_done.txt'
$Log = Join-Path $Out 'sched_cmd.log'
$ResultFile = Join-Path $Out 'sched_cmd_result.json'
$PREFIX = @{ ice = 'BCU_SCHI'; melt = 'BCU_SCHW'; chu2 = 'CHU2_SCH' }
$NAME = @{ ice = '製冰'; melt = '融冰'; chu2 = '磁浮' }
$WD = '一二三四五六日'
$ICE_OK_FROM = '22:00'; $ICE_OK_TO = '07:30'
$FCU_ALLOW = @{ 'B239' = 'SG_2F31_P25' }     # 房號 → InTouch 面板（Cliff 授權的房間才放進來）
$FCU_SET_MIN = 24; $FCU_SET_MAX = 28

$src = @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class CticDdeW {
 public delegate IntPtr Cb(uint t,uint f,IntPtr hc,IntPtr h1,IntPtr h2,IntPtr hd,IntPtr d1,IntPtr d2);
 [DllImport("user32.dll")] static extern uint DdeInitializeW(ref uint id,Cb cb,uint cmd,uint res);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr DdeCreateStringHandleW(uint id,string s,int cp);
 [DllImport("user32.dll")] static extern IntPtr DdeConnect(uint id,IntPtr svc,IntPtr top,IntPtr cc);
 [DllImport("user32.dll")] static extern IntPtr DdeClientTransaction(IntPtr d,uint cb,IntPtr c,IntPtr it,uint fmt,uint typ,uint ms,out uint r);
 [DllImport("user32.dll",EntryPoint="DdeClientTransaction")] static extern IntPtr DdePoke(byte[] d,uint cb,IntPtr c,IntPtr it,uint fmt,uint typ,uint ms,out uint r);
 [DllImport("user32.dll")] static extern uint DdeGetData(IntPtr h,byte[] b,uint max,uint off);
 [DllImport("user32.dll")] static extern bool DdeFreeDataHandle(IntPtr h);
 [DllImport("user32.dll")] static extern bool DdeFreeStringHandle(uint id,IntPtr h);
 [DllImport("user32.dll")] static extern bool DdeDisconnect(IntPtr c);
 [DllImport("user32.dll")] static extern bool DdeUninitialize(uint id);
 [DllImport("user32.dll")] static extern uint DdeGetLastError(uint id);
 static Cb keep = (t,f,hc,h1,h2,hd,d1,d2) => IntPtr.Zero;
 public static bool Poke(string tag,string val){
  uint id=0; if(DdeInitializeW(ref id,keep,0x10,0)!=0) return false;
  IntPtr s=DdeCreateStringHandleW(id,"VIEW",1200), tp=DdeCreateStringHandleW(id,"TAGNAME",1200);
  IntPtr c=DdeConnect(id,s,tp,IntPtr.Zero); bool ok=false;
  if(c!=IntPtr.Zero){
   IntPtr it=DdeCreateStringHandleW(id,tag,1200); uint res;
   byte[] b=Encoding.ASCII.GetBytes(val+"\0");
   ok=DdePoke(b,(uint)b.Length,c,it,1,0x4090,5000,out res)!=IntPtr.Zero;
   DdeFreeStringHandle(id,it); DdeDisconnect(c);
  }
  DdeFreeStringHandle(id,s);DdeFreeStringHandle(id,tp);DdeUninitialize(id); return ok;
 }
 public static string[] Read(string[] tags){ return Read(tags,5000,0); }
 // ms = 每點逾時；budget = 整批最多花幾毫秒（0 = 不限）；連續 5 點逾時就放棄，避免 WindowViewer 卡住時整個程式停住
 public static string[] Read(string[] tags,uint ms,int budget){
  var sw=System.Diagnostics.Stopwatch.StartNew(); int fails=0;
  uint id=0; if(DdeInitializeW(ref id,keep,0x10,0)!=0) return null;
  IntPtr s=DdeCreateStringHandleW(id,"VIEW",1200), tp=DdeCreateStringHandleW(id,"TAGNAME",1200);
  IntPtr c=DdeConnect(id,s,tp,IntPtr.Zero);
  if(c==IntPtr.Zero){DdeFreeStringHandle(id,s);DdeFreeStringHandle(id,tp);DdeUninitialize(id);return null;}
  var o=new string[tags.Length];
  for(int i=0;i<tags.Length;i++){
   IntPtr it=DdeCreateStringHandleW(id,tags[i],1200); uint res;
   long t0=sw.ElapsedMilliseconds;
   IntPtr h=DdeClientTransaction(IntPtr.Zero,0,c,it,1,0x20B0,ms,out res);
   bool timedOut=(sw.ElapsedMilliseconds-t0)>=(long)(ms*0.9);
   if(h==IntPtr.Zero){ o[i]=""; if(timedOut) fails++; else fails=0; if(fails>=5 || (budget>0 && sw.ElapsedMilliseconds>budget)){ DdeFreeStringHandle(id,it); DdeDisconnect(c);DdeFreeStringHandle(id,s);DdeFreeStringHandle(id,tp);DdeUninitialize(id); return null; } }
   else{fails=0; if(budget>0 && sw.ElapsedMilliseconds>budget){ DdeFreeDataHandle(h); DdeFreeStringHandle(id,it); DdeDisconnect(c);DdeFreeStringHandle(id,s);DdeFreeStringHandle(id,tp);DdeUninitialize(id); return null; }
    uint n=DdeGetData(h,null,0,0);var b=new byte[n];DdeGetData(h,b,n,0);DdeFreeDataHandle(h);o[i]=Encoding.Default.GetString(b).TrimEnd('\0','\r','\n',' ');}
   DdeFreeStringHandle(id,it);
  }
  DdeDisconnect(c);DdeFreeStringHandle(id,s);DdeFreeStringHandle(id,tp);DdeUninitialize(id); return o;
 }
}
"@
if (-not ('CticDdeW' -as [type])) { Add-Type -TypeDefinition $src }
$inv = [Globalization.CultureInfo]::InvariantCulture

function Log($m) { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') $m" | Out-File $Log -Append -Encoding utf8 }
function Day-Label($d) { $n = 0; if ([int]::TryParse("$d", [ref]$n) -and $n -ge 1 -and $n -le 7) { return "星期$($WD[$n - 1])" } else { return "星期?($d)" } }
function Hm-Ok($x) { return ("$x" -match '^([01]\d|2[0-3]):[0-5]\d$') }
function Is-Summer($t) { $md = $t.Month * 100 + $t.Day; return ($md -ge 516 -and $md -le 1015) }

function Check-Change($c, $now) {
  # 回傳 $null = 通過；否則回傳擋下的原因
  if ("$($c.kind)" -eq 'fcu') {
    if (-not $FCU_ALLOW.ContainsKey("$($c.room)")) { return "送風機房間 $($c.room) 不在授權清單（目前只有 $($FCU_ALLOW.Keys -join ', ')）" }
    $us = @($c.units)
    if ($us.Count -lt 1 -or $us.Count -gt 9) { return "送風機台數不對" }
    foreach ($u in $us) { if ("$u" -notmatch '^FCU0[1-9]$') { return "送風機編號 $u 不對（FCU01–FCU09）" } }
    if (@('off','on','setT') -notcontains "$($c.action)") { return "送風機動作 $($c.action) 不對（off / on / setT）" }
    if ("$($c.action)" -eq 'setT') {
      $v = 0.0
      if (-not [double]::TryParse("$($c.value)", [Globalization.NumberStyles]::Float, $inv, [ref]$v) -or $v -lt $FCU_SET_MIN -or $v -gt $FCU_SET_MAX) {
        return "設定溫度 $($c.value) 超出 $FCU_SET_MIN–$FCU_SET_MAX °C" }
    }
    return $null
  }
  if (-not $PREFIX.ContainsKey("$($c.kind)")) { return "種類 $($c.kind) 不在白名單（只能 ice / melt / chu2 / fcu）" }
  $d = 0; if (-not [int]::TryParse("$($c.day)", [ref]$d) -or $d -lt 1 -or $d -gt 7) { return "星期 $($c.day) 不對（1–7）" }
  if (-not (Hm-Ok $c.on) -or -not (Hm-Ok $c.off)) { return "時間格式不對（$($c.on)–$($c.off)，要 HH:MM）" }
  if ("$($c.en)" -ne '0' -and "$($c.en)" -ne '1') { return "勾選 en 只能 0 或 1" }
  $onT = "$($c.on)"; $offT = "$($c.off)"; $en = [int]"$($c.en)"
  if ($onT -eq $offT) { return "開始和停止時間相同" }
  if ($c.kind -eq 'ice') {
    if ($en -eq 1) {
      if ($offT -lt $onT) { $bad = ($onT -lt $ICE_OK_FROM) -or ($offT -gt $ICE_OK_TO) }
      else { $bad = -not (($onT -ge $ICE_OK_FROM) -or ($offT -le $ICE_OK_TO)) }
      if ($bad) { return "製冰 $onT–$offT 跑進白天 $ICE_OK_TO–$ICE_OK_FROM（硬規則禁止）" }
    }
  } else {
    if ($offT -lt $onT) { return "$($NAME[$c.kind])不能跨午夜（$onT–$offT）" }
    if ($onT -lt '07:00' -or $offT -gt '22:00') { return "$($NAME[$c.kind])要在 07:00–22:00 之內（$onT–$offT）" }
    if ($c.kind -eq 'chu2' -and $en -eq 1 -and $d -le 5 -and (Is-Summer $now) -and $offT -gt '16:00') {
      return "夏月平日磁浮不能排到 16:00 以後（$offT），尖峰要改融冰供冷"
    }
  }
  return $null
}

function Tags($c) {
  $p = $PREFIX["$($c.kind)"]; $dd = '{0:00}' -f [int]$c.day
  return [string[]]@("$($p)_$($dd)_StartHH", "$($p)_$($dd)_StartMM", "$($p)_$($dd)_StopHH", "$($p)_$($dd)_StopMM", "$($p)_$($dd)SCHEn")
}
function Want($c) {
  $a = "$($c.on)".Split(':'); $b = "$($c.off)".Split(':')
  return [string[]]@([int]$a[0], [int]$a[1], [int]$b[0], [int]$b[1], [int]"$($c.en)")
}
function Fmt($v) {
  if ($null -eq $v -or $v.Count -lt 5) { return '讀不到' }
  $n = @($v | ForEach-Object { $x = 0.0; if ([double]::TryParse("$_", [Globalization.NumberStyles]::Float, $inv, [ref]$x)) { [int]$x } else { -1 } })
  return ('{0:00}:{1:00}–{2:00}:{3:00}' -f $n[0], $n[1], $n[2], $n[3]) + $(if ($n[4] -eq 1) { '（有勾）' } else { '（沒勾）' })
}
function Same($got, $want) {
  if ($null -eq $got) { return $false }
  for ($i = 0; $i -lt 5; $i++) {
    $x = 0.0
    if (-not [double]::TryParse("$($got[$i])", [Globalization.NumberStyles]::Float, $inv, [ref]$x)) { return $false }
    if ([int][math]::Round($x) -ne [int]$want[$i]) { return $false }
  }
  return $true
}

function Save-Result($r) {
  ($r | ConvertTo-Json -Depth 6) | Out-File $ResultFile -Encoding utf8
  Log ("$($r.id) $($r.status) " + (($r.lines) -join ' / '))
  if (-not $ManualDry) { "$($r.id)" | Out-File $DoneFile -Append -Encoding ascii }
}

function Fcu-Read($panel, $u) {
  $v = [CticDdeW]::Read([string[]]@("$($panel)_$($u)_Run", "$($panel)_$($u)_Fan_High", "$($panel)_$($u)_Fan_Middle", "$($panel)_$($u)_Fan_Low", "$($panel)_$($u)_setT", "$($panel)_$($u)_T"), 3000, 20000)
  if ($null -eq $v) { return $null }
  $n = @($v | ForEach-Object { $x = 0.0; if ([double]::TryParse("$_", [Globalization.NumberStyles]::Float, $inv, [ref]$x)) { $x } else { $null } })
  return [ordered]@{ run = $n[0]; fan = $(if ($null -eq $n[1]) { $null } else { [int](($n[1] -eq 1) -or ($n[2] -eq 1) -or ($n[3] -eq 1)) }); setT = $n[4]; t = $n[5] }
}
function Fcu-Text($r) {
  if ($null -eq $r -or $null -eq $r.run) { return '讀不到' }
  $on = $(if ($r.fan -eq 1) { '運轉中' } else { '停止' })
  return "$on，設定 $($r.setT)°C，室溫 $([math]::Round([double]$r.t, 1))°C"
}
function Fcu-AllowAfterHours($room) {
  # 平日 18:00–07:00 遠端開啟：當晚加班名單檔若已存在，加上這個房號（名單不存在 = 晚上關機規則沒啟用，不建立新檔，以免誤啟用）
  $now = Get-Date; $hm = $now.ToString('HH:mm')
  if ($now.DayOfWeek -eq 'Saturday' -or $now.DayOfWeek -eq 'Sunday' -or ($hm -lt '18:00' -and $hm -ge '07:00')) { return '' }
  $day = $(if ($hm -lt '07:00') { $now.AddDays(-1) } else { $now })
  $f1 = Join-Path $Out ("afterhours_allow_{0:yyyy-MM-dd}.txt" -f $day); $f2 = Join-Path $Out 'afterhours_allow.txt'
  if (-not (Test-Path $f1)) { if (Test-Path $f2) { Copy-Item $f2 $f1 } else { return '' } }
  if (@(Get-Content $f1 -Encoding UTF8 | ForEach-Object { ($_ -split '\s+')[0] }) -contains $room) { return '' }
  "$room   # 指令信箱遠端開啟 $(Get-Date -f 'HH:mm')" | Out-File $f1 -Append -Encoding utf8
  return "（已加入今晚加班名單，晚上巡檢不會再關）"
}

# ---- 讀指令 ----
if (Test-Path $Off) { exit 0 }
$raw = $null
if ($File) { $raw = Get-Content $File -Raw -Encoding utf8 }
else {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    $r = Invoke-RestMethod -Uri $Api -Headers @{ 'User-Agent' = 'ctic-sched-cmd'; Accept = 'application/vnd.github+json' } -TimeoutSec 20
    $raw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($r.content -replace '\s', '')))
  } catch {
    if ("$($_.Exception.Message)" -match '404') { exit 0 }               # 信箱是空的
    # API 次數用完（公司共用對外 IP 時可能發生）→ 改讀 raw（可能有幾分鐘快取，但不影響安全檢查）
    try {
      $raw = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'ctic-sched-cmd' } `
              -Uri ($RawUrl + '?t=' + [DateTime]::UtcNow.Ticks)).Content
    } catch {
      if ("$($_.Exception.Message)" -notmatch '404') { Log "fetch failed: $($_.Exception.Message)" }
      exit 0
    }
  }
}
$cmd = $raw | ConvertFrom-Json
if (-not $cmd.id) { exit 0 }
$done = @(); if (Test-Path $DoneFile) { $done = @(Get-Content $DoneFile | ForEach-Object { $_.Trim() }) }
if (-not $DryRun -and $done -contains "$($cmd.id)") { exit 0 }      # 做過了
$ManualDry = [bool]$DryRun
if ($cmd.dry_run -eq $true) { $DryRun = $true }                   # 指令本身標 dry_run：只檢查、讀現值，不寫（第一次連線測試用）

$now = Get-Date
$res = [ordered]@{ id = "$($cmd.id)"; time = $now.ToString('yyyy-MM-dd HH:mm:ss'); requested_by = "$($cmd.requested_by)";
                   note = "$($cmd.note)"; status = ''; lines = @(); dry_run = [bool]$DryRun }
try {
  $exp = [datetimeoffset]::Parse("$($cmd.expires)", $inv); $apv = [datetimeoffset]::Parse("$($cmd.approved_at)", $inv)
} catch { $res.status = 'rejected'; $res.lines = @('指令沒有正確的核准時間或過期時間'); Save-Result $res; exit 0 }
if ([datetimeoffset]::Now -gt $exp) { $res.status = 'rejected'; $res.lines = @("指令已過期（$($cmd.expires)）"); Save-Result $res; exit 0 }
if (($exp - $apv).TotalHours -gt 24) { $res.status = 'rejected'; $res.lines = @('過期時間超過核准後 24 小時'); Save-Result $res; exit 0 }
$changes = @($cmd.changes)
if ($changes.Count -lt 1 -or $changes.Count -gt 21) { $res.status = 'rejected'; $res.lines = @('沒有要改的項目，或一次超過 21 筆'); Save-Result $res; exit 0 }
$why = @()
foreach ($c in $changes) { $e = Check-Change $c $now; if ($e) { $why += $(if ("$($c.kind)" -eq 'fcu') { "$($c.room) $e" } else { "$(Day-Label $c.day) $e" }) } }
if ($why.Count) { $res.status = 'rejected'; $res.lines = @('整筆指令沒有執行：') + $why; Save-Result $res; exit 0 }

# ---- 寫入（WindowViewer 要開著） ----
$probe = [CticDdeW]::Read([string[]]@('SGB1DC51_BCU_ST'), 3000, 5000)
if ($null -eq $probe) { $res.status = 'failed'; $res.lines = @('讀不到 InTouch（WindowViewer 有開嗎？），沒有寫入，下次再試'); 
  ($res | ConvertTo-Json -Depth 6) | Out-File $ResultFile -Encoding utf8; Log "$($res.id) viewer down, will retry"; exit 0 }
$allOk = $true
foreach ($c in $changes) {
  if ("$($c.kind)" -eq 'fcu') {
    $panel = $FCU_ALLOW["$($c.room)"]; $act = "$($c.action)"
    $what = $(if ($act -eq 'off') { '關閉' } elseif ($act -eq 'on') { '開啟' } else { "設定 $($c.value)°C" })
    foreach ($u in @($c.units)) {
      $label = "$($c.room) $u"
      $before = Fcu-Read $panel $u
      if ($null -eq $before -or $null -eq $before.run) { $allOk = $false; $res.lines += "$label：讀不到這台送風機，沒有寫入 ❌"; continue }
      if ($DryRun) { $res.lines += "$label：目前 $(Fcu-Text $before) → $what（試跑，沒寫）"; continue }
      if ($act -eq 'setT') {
        $val = ([double]"$($c.value)").ToString($inv)
        $null = [CticDdeW]::Poke("$($panel)_$($u)_setT", $val); Start-Sleep -Seconds 3
        $after = Fcu-Read $panel $u
        if ($null -ne $after -and [math]::Abs([double]$after.setT - [double]$val) -lt 0.05) { $res.lines += "$label：設定 $($before.setT) → $($after.setT)°C ✅（室溫 $([math]::Round([double]$after.t, 1))°C）" }
        else { $allOk = $false; $res.lines += "$label：寫入 $val°C 後讀回 $($after.setT)，不一致 ❌" }
      } else {
        $want = $(if ($act -eq 'off') { 0 } else { 1 })
        $null = [CticDdeW]::Poke("$($panel)_$($u)_Run", "$want")
        $after = $null
        for ($k = 0; $k -lt 15; $k++) { Start-Sleep -Seconds 5; $after = Fcu-Read $panel $u; if ($null -ne $after -and $after.fan -eq $want) { break } }
        if ($null -ne $after -and $after.fan -eq $want) { $res.lines += "$label：$(Fcu-Text $before) → $what ✅" }
        elseif ($null -ne $after -and [int]$after.run -eq $want) { $res.lines += "$label：已送出$what（運轉指令已是 $want），風速狀態 75 秒內還沒更新，請稍後再看 ⚠️" }
        else { $allOk = $false; $res.lines += "$label：送出$what後讀回不符（$(Fcu-Text $after)）❌" }
      }
    }
    if (-not $DryRun -and $act -eq 'on') { $x = Fcu-AllowAfterHours "$($c.room)"; if ($x) { $res.lines += $x } }
    continue
  }
  $tags = Tags $c; $want = Want $c
  $label = "$(Day-Label $c.day)$($NAME[$c.kind])"
  $before = [CticDdeW]::Read($tags, 3000, 20000)
  if ($DryRun) { $res.lines += "$label：$(Fmt $before) → $($c.on)–$($c.off)$(if ([int]$c.en -eq 1) {'（有勾）'} else {'（沒勾）'})（試跑，沒寫）"; continue }
  if (Same $before $want) { $res.lines += "$label：已經是 $(Fmt $before)，不用改"; continue }
  for ($i = 0; $i -lt 5; $i++) { $null = [CticDdeW]::Poke($tags[$i], $want[$i]) }
  Start-Sleep -Seconds 3
  $after = [CticDdeW]::Read($tags, 3000, 20000)
  if (Same $after $want) { $res.lines += "$label：$(Fmt $before) → $(Fmt $after) ✅" }
  else {
    $allOk = $false
    if ($null -ne $before) { for ($i = 0; $i -lt 5; $i++) { $null = [CticDdeW]::Poke($tags[$i], "$($before[$i])") } }
    Start-Sleep -Seconds 2
    $back = [CticDdeW]::Read($tags, 3000, 20000)
    $res.lines += "$label：寫入後讀回 $(Fmt $after) 和指令不符，已還原成 $(Fmt $back) ❌"
  }
}
$res.status = $(if ($DryRun) { 'dry_run' } elseif ($allOk) { 'done' } else { 'failed' })
Save-Result $res
if ($ManualDry) { Get-Content $ResultFile }
