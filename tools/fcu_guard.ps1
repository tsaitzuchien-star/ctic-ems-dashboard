# 中創園區 送風機巡檢 (fcu_guard.ps1) — 裝在空調監控主機，排程每 15 分鐘跑一次
# Cliff 2026-11-06 授權（B239 測試成功：寫 _Run=0 會關機、寫 _setT 溫控器會跟著變）：
#  1) 守住 24°C：運轉中的送風機設定 < 24°C → 改成 24°C（全天）。
#  2) 加班空調：平日 18:00 以後（到隔天 07:00），運轉中但不在申請名單的送風機 → 關機（_Run=0）。
#     名單：C:\BMS_Export\afterhours_allow_yyyy-MM-dd.txt（當天，優先）或 afterhours_allow.txt，
#     一行一個房號（例如 B239）或面板（例如 SG_2F31_P25），可加結束時間（例如 C303 19:00），# 之後是註解。沒有名單檔 → 這條不執行；空檔 = 沒人申請。
#     房號 ↔ 面板對照：C:\BMS_Export\fcu_rooms.csv。週末先不做。
# 永不碰：C:\BMS_Export\fcu_guard_exclude.txt（一行一個標籤開頭）。
# 預設「試跑」：只記錄會怎麼做。加 -Live 才寫入。停用：放 C:\BMS_Export\fcu_guard_off.txt。
# 記錄：fcu_guard_yyyy-MM-dd.csv；狀態：fcu_guard_status.json
param([switch]$Live, [switch]$NoAfter, [switch]$NoSetT)
$ErrorActionPreference = 'Stop'
$Out = 'C:\BMS_Export'
$SET_MIN = 24.0   # Cliff 2026-11-06 15:08：老闆說 25 度有點悶，下限改 24
$AFTER_START = '18:00'; $AFTER_END = '07:00'
$MAX_WRITES = 150
$mode = $(if ($Live) { 'LIVE' } else { 'DRY' })
$now = Get-Date
$mtx = New-Object System.Threading.Mutex($false, 'Global\CTIC_Fcu_Guard')
if (-not $mtx.WaitOne(0)) { exit 0 }

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
function Num($s) { $d = 0.0; if ([double]::TryParse("$s", [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $d } else { $null } }
function Lines($f) { if (Test-Path $f) { @(Get-Content $f -Encoding UTF8 | ForEach-Object { ($_ -replace '#.*$','').Trim() } | Where-Object { $_ }) } else { $null } }

# 場地租借區（Cliff 2026-11-06 16:21）：挑高又熱，設定下限 20°C；ac_events.txt 有登記的時段照常供冷、下班不關
$ZONES = [ordered]@{
  '會議廳' = @('SG_1F31_P20')                                                   # C104 國際會議廳（SP-21-3 L3、L4）
  '展演'   = @('SG_1F31_P18', 'SG_1F31_P19', 'SG_1F31_P25', 'SG_1F31_P26')       # 展演大廳（SP-21-2 L13、SP-21-3 L05–L08）
  '訓練'   = @('SG_1F31_P15', 'SG_1F31_P14', 'SG_1F31_P17', 'SG_1F31_P16')       # 訓練教室 B131–B134（SP-21-3 L10–L13）
}
$ZONE_ALIAS = @{ 'hall' = '會議廳'; 'expo' = '展演'; 'train' = '訓練'; 'all' = '全部' }   # 英文代號，方便在 PowerShell 打字
$ZONE_SET_MIN = 20.0; $EVENT_PRECOOL_MIN = 30
# 警衛室（1 樓收發室一帶 1-P21，SP-21-1 L7/L8）：24 小時有人值勤，下限 22°C、下班不關（Cliff 2026-11-06 16:24）
$GUARD = @('SG_1F31_P21'); $GUARD_SET_MIN = 22.0
function Is-Guard($u) { foreach ($p in $GUARD) { if ($u.StartsWith($p)) { return $true } }; return $false }
$EventFile = Join-Path $Out 'ac_events.txt'   # 一行一場：2026-11-07 07:30-17:30 會議廳 展演 訓練（也可寫 全部，或面板編號）
function Zone-Panels { @($ZONES.Values | ForEach-Object { $_ }) }
function In-Zone($u) { foreach ($p in (Zone-Panels)) { if ($u.StartsWith($p)) { return $true } }; return $false }
function Event-Now($t) {
  # 回傳現在（含開始前 30 分鐘預冷）有活動的面板與說明
  $pan = @(); $txt = @()
  if (Test-Path $EventFile) {
    foreach ($line in (Get-Content $EventFile -Encoding UTF8)) {
      $l = ($line -replace '#.*$', '').Trim(); if (-not $l) { continue }
      $p = @($l -split '\s+')
      if ($p.Count -lt 3 -or $p[1] -notmatch '^(\d{1,2}:\d{2})-(\d{1,2}:\d{2})$') { continue }
      try { $d0 = [datetime]::ParseExact($p[0], 'yyyy-MM-dd', $null) } catch { continue }
      $s = $d0.Add([timespan]::Parse($matches[1])).AddMinutes(-$EVENT_PRECOOL_MIN); $e = $d0.Add([timespan]::Parse($matches[2]))
      if ($t -lt $s -or $t -ge $e) { continue }
      foreach ($z in $p[2..($p.Count - 1)]) {
        $z = $(if ($ZONE_ALIAS.Contains($z.ToLower())) { $ZONE_ALIAS[$z.ToLower()] } else { $z })
        if ($z -eq '全部') { $pan += Zone-Panels } elseif ($ZONES.Contains($z)) { $pan += $ZONES[$z] } elseif ($z -match '^SG_') { $pan += $z }
      }
      $txt += "$($p[1]) $($p[2..($p.Count - 1)] -join ' ')"
    }
  }
  [pscustomobject]@{ panels = @($pan | Select-Object -Unique); text = ($txt -join '；') }
}
$status = [ordered]@{ time = $now.ToString('yyyy-MM-dd HH:mm:ss'); mode = $mode; event = ''; units = 0; running = 0; setT_fix = 0; after_off = 0; after_rule = ''; note = ''; actions = @() }
function Save-Status { $status | ConvertTo-Json -Depth 4 | Out-File (Join-Path $Out 'fcu_guard_status.json') -Encoding utf8 }
if (Test-Path (Join-Path $Out 'fcu_guard_off.txt')) { $status.note = 'off-switch'; Save-Status; exit 0 }

$units = @(Get-Content (Join-Path $Out 'fcu_tags.txt') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^SG_.*_FCU\d+_Run$' } | ForEach-Object { $_ -replace '_Run$','' })
$exclude = @(Lines (Join-Path $Out 'fcu_guard_exclude.txt'))
$units = @($units | Where-Object { $u = $_; -not ($exclude | Where-Object { $u.StartsWith($_) }) })
$status.units = $units.Count

# 房號對照
$roomOf = @{}
$rf = Join-Path $Out 'fcu_rooms.csv'
if (Test-Path $rf) {
  foreach ($r in (Import-Csv $rf -Encoding UTF8)) {
    if ($r.fcus) { foreach ($f in ($r.fcus -split ',')) { $roomOf["$($r.panel)_FCU$f"] = $r.rooms } }
    elseif (-not $roomOf.ContainsKey($r.panel)) { $roomOf[$r.panel] = $r.rooms }
  }
}
function Rooms($u) { $p = $u -replace '_FCU\d+$',''; if ($roomOf.ContainsKey($u)) { $roomOf[$u] } elseif ($roomOf.ContainsKey($p)) { $roomOf[$p] } else { '' } }

# 讀 Run、setT
$tags = [string[]]@(foreach ($u in $units) { "$($u)_Run"; "$($u)_setT" })
# 分批讀（每批 60 點、批次間停 1 秒），不要一次把 InTouch 佔滿，讓磁浮控制程式也讀得到
$v = New-Object string[] $tags.Count
for ($k = 0; $k -lt $tags.Count; $k += 60) {
  $n = [math]::Min(60, $tags.Count - $k)
  $part = [CticDdeW]::Read([string[]]$tags[$k..($k + $n - 1)], [uint32]1500, 30000)
  if ($null -eq $part) { $status.note = "dde-fail at $k"; Save-Status; exit 1 }
  for ($j = 0; $j -lt $n; $j++) { $v[$k + $j] = $part[$j] }
  Start-Sleep -Milliseconds 1000
}

# 加班名單
$hm = $now.ToString('HH:mm')
$after = (-not $NoAfter) -and ($now.DayOfWeek -ne 'Saturday') -and ($now.DayOfWeek -ne 'Sunday') -and ($hm -ge $AFTER_START -or $hm -lt $AFTER_END)
$allow = $null
if ($after) {
  $day = $(if ($hm -lt $AFTER_END) { $now.AddDays(-1) } else { $now })
  $f1 = Join-Path $Out ("afterhours_allow_{0:yyyy-MM-dd}.txt" -f $day); $f2 = Join-Path $Out 'afterhours_allow.txt'
  $allow = Lines $f1; $af = $f1
  if ($null -eq $allow) { $allow = Lines $f2; $af = $f2 }
  if ($null -eq $allow) { $after = $false; $status.after_rule = 'no-allow-list' } else { $status.after_rule = "$(Split-Path $af -Leaf): $($allow -join ' ')" }
}
$ev = Event-Now $now; $status.event = $ev.text
function Allowed($u) {
  if (Is-Guard $u) { return $true }   # 警衛室 24 小時
  foreach ($p in $ev.panels) { if ($u.StartsWith($p)) { return $true } }   # 場地租借時段照常供冷
  # 名單每行：房號或面板，後面可加結束時間，例如「C303 19:00」= 申請到 19:00，之後照樣關
  $rooms = @((Rooms $u) -split ' ' | Where-Object { $_ })
  foreach ($line in $allow) {
    $p = @($line -split '\s+'); $a = $p[0]
    if ($p.Count -ge 2 -and $p[1] -match '^\d{1,2}:\d{2}$') { $end = $p[1].PadLeft(5, '0'); if ($hm -ge $end -or $hm -lt $AFTER_END) { continue } }
    if ($u.StartsWith($a)) { return $true }; if ($rooms -contains $a) { return $true }
  }
  return $false
}

$logf = Join-Path $Out ('fcu_guard_{0:yyyy-MM-dd}.csv' -f $now)
if (-not (Test-Path $logf)) { 'time,mode,unit,rooms,action,before,ok' | Out-File $logf -Encoding utf8 }
$writes = 0; $acts = @()
for ($i = 0; $i -lt $units.Count; $i++) {
  $u = $units[$i]; $run = Num $v[2*$i]; $st = Num $v[2*$i+1]
  if ($null -eq $run -or $run -lt 0.5) { continue }
  $status.running++
  $act = $null; $tag = $null; $val = $null; $before = $null
  if ($after -and -not (Allowed $u)) { $act = 'off'; $tag = "$($u)_Run"; $val = '0'; $before = "Run=1 setT=$st" }
  elseif (-not $NoSetT -and $null -ne $st -and $st -gt 5 -and $st -lt ($mn = $(if (Is-Guard $u) { $GUARD_SET_MIN } elseif (In-Zone $u) { $ZONE_SET_MIN } else { $SET_MIN })) - 0.05) { $act = 'setT_floor'; $tag = "$($u)_setT"; $val = $mn.ToString($inv); $before = "setT=$st" }
  if (-not $act) { continue }
  if ($writes -ge $MAX_WRITES) { $status.note = "max-writes $MAX_WRITES"; break }
  $ok = ''
  if ($Live) { $ok = [CticDdeW]::Poke($tag, $val); $writes++; Start-Sleep -Milliseconds 300 }
  if ($act -eq 'off') { $status.after_off++ } else { $status.setT_fix++ }
  $rm = Rooms $u
  "$($now.ToString('yyyy-MM-dd HH:mm:ss')),$mode,$u,$rm,$act,$before,$ok" | Out-File $logf -Append -Encoding utf8
  $acts += "$u [$rm] $act ($before)"
}
$status.actions = $acts
Save-Status
Write-Host "fcu_guard $mode $($status.time): units=$($status.units) running=$($status.running) setT_fix=$($status.setT_fix) after_off=$($status.after_off) $($status.after_rule) $($status.note)"
$acts | ForEach-Object { "  $_" }
