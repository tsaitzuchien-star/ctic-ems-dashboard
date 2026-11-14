# 中創園區 磁浮冰機 CHU-2 自動控制 (mag_auto.ps1) — 裝在空調監控主機
# 寫入的點（Cliff 授權）：負載限制百分比 SG_CHU2_Item40035 與其啟用時間 TIME_SET1_H/_M、冰水出水溫度設定 1/2 SG_CHU2_Item40001/40003。
# 負載限制要到「啟用時間」那一分鐘才會送到主機，所以每次改上限都把啟用時間設成下一分鐘。
# 不開關機、不改其他設定。
# 兩層控制：
#  1) 契約需量（最優先，每 10 秒）：向監控電腦 http://10.10.2.20:8088/api/live 取 15 分鐘需量推估（台電基準），
#     推估 ≥ 契約 95% 就每分鐘把負載上限降 10%；回到 88% 以下 5 分鐘後逐步回升到原本的值。
#     平常不動負載上限（維持人員設定的值）。
#  2) 出水溫度重設（07:30–19:00，冰機運轉中，每 10 分鐘最多調 0.5°C）：調主機自己的出水設定值。
#     季節上下限：夏月 10.5–11.5、過渡月 11.5–13、冬月 12–14 °C；室外露點 > 20°C 時上限 12°C。
#     依「最熱的樓層」：任一層（≥5 台運轉）熱房間比例 ≥ 30% → 降 0.5°C；
#     所有樓層 < 10% 且平均室溫低於設定 0.5°C → 升 0.5°C（07:30–09:00 開機拉溫、4 樓熱房間 ≥ 20%、需量吃緊時不升）。
# 預設「試跑」：只記錄會怎麼調，不寫入。加 -Live 才寫入；加 -NoComfort 只做契約需量保護。
# 停用：在 C:\BMS_Export 放 mag_auto_off.txt（不再寫入，維持現值）。
# 人員手動改了負載限制或出水設定 → 程式讓手 60 分鐘，以人員的值為準。
# 積極節電（Cliff 2026-11-06 改選方案 B，到 11/30）：09:00 後平時上限 65%，非 4 樓最熱樓層熱房間 ≥ 25%（4 樓 ≥ 40%）
#   每 10 分鐘 +10%（最多 100%），< 15%（4 樓 < 30%）再每 10 分鐘 -10% 回 65%；
#   出水設定範圍 13–14 °C，熱房間 ≥ 30%（4 樓 ≥ 45%）就降、< 15%（4 樓 < 30%）就升。
#   平日時段基準（上限的底）：07:30–09:30 90%（出水 12–13）、09:30–11:00 65%、11:00–14:00 80%、14:00–16:00 60%、16:00–18:00 50%、18:00 後 40%。週末不套用。
#   提前結束：放 C:\BMS_Export\mag_eco_off.txt。人員設定低於 65% 不會被調高。
# 記錄：C:\BMS_Export\mag_auto_yyyy-MM-dd.csv；狀態：C:\BMS_Export\mag_auto_status.json（網站讀取）
param([switch]$Live, [switch]$Once, [switch]$NoComfort)
$ErrorActionPreference = 'Stop'
$Out  = 'C:\BMS_Export'
$Tag  = 'SG_CHU2_Item40035'
$Api  = 'http://10.10.2.20:8088/api/live'
$Off  = Join-Path $Out 'mag_auto_off.txt'
$FcuList = Join-Path $Out 'fcu_tags.txt'
$FcuExclude = Join-Path $Out 'fcu_exclude.txt'   # 不列入熱房間判斷的送風機（空房、未進駐），一行一個標籤開頭，例如 SG_4F31_P32
$SpTags = @('SG_CHU2_Item40001', 'SG_CHU2_Item40003')   # 冰水出水溫度設定 1、2

# ---- 參數 ----
$MAX = 100; $MIN = 20                # 負載限制範圍（Cliff 2026-11-06：上限開放到 100%，由程式掌控）
$BASE_HI = 100; $BASE_LO = 90        # 平時上限：需量有餘裕且熱房間 ≥ 30% 時 100%，接近契約時退回 90%
$BOOST_ON = 0.85; $BOOST_OFF = 0.90; $BOOST_UP_S = 600   # 需量推估 < 85% 契約才升到 100%（升級間隔 10 分鐘）；≥ 90% 立刻退回 90%
$BOOST_HOT = 0.30   # 升到 100% 還要「最熱樓層熱房間 ≥ 30%」（Cliff 2026-11-06 19:33：首日中午放到 100% 多用電、效率差）
$TRIG = 0.95; $HARD = 1.00; $CLEAR = 0.88; $CLEAR_S = 300
$D_STEP = 10; $D_STEP_S = 60         # 需量降載：每步 10%、間隔 60 秒
$SP_STEP = 0.5; $SP_STEP_S = 600     # 出水設定：每步 0.5°C、間隔 10 分鐘
$SP_HARD_MIN = 10.0; $SP_HARD_MAX = 14.0
$SET_FLOOR = 24.0                    # 熱房間判斷：室溫 ≥ max(設定, 24) + 1°C（設定下限 24°C，Cliff 2026-11-06）
$C_START = '07:30'; $C_END = '19:00'; $PULLDOWN_END = '09:00'
$HOT_UP = 0.30; $HOT_OK = 0.10; $HOT_4F_HOLD = 0.20   # 熱房間比例門檻
$DEW_CAP_C = 20.0; $DEW_SP_MAX = 12.0                 # 室外露點高時出水上限
$STALE_S = 90; $LOST_RESTORE_S = 900
$MANUAL_HOLD_S = 3600
$ECO_UNTIL = [datetime]'2026-12-01'; $EcoOff = Join-Path $Out 'mag_eco_off.txt'
$ECO_BASE = 65; $ECO_STEP = 10; $ECO_STEP_S = 600
$ECO_HOT_UP = 0.25; $ECO_HOT_DN = 0.15; $ECO_4F_UP = 0.40; $ECO_4F_OK = 0.30   # 上限：非 4 樓最熱樓層 ≥ 25%（或 4 樓 ≥ 40%）就加；< 15%（4 樓 < 30%）才減
$AFTER_START = '18:00'; $AFTER_LIMIT = 30   # 園區供應 07:30–18:00，之後是申請付費的加班空調，上限固定 30%（Cliff 2026-11-06 16:51，原 40%）
$ECO_SP_DN = 0.30; $ECO_4F_SP_DN = 0.45                                         # 出水：熱房間 ≥ 30%（4 樓 ≥ 45%）才降

$mtx = New-Object System.Threading.Mutex($false, 'Global\CTIC_Mag_Auto')
if (-not $Once -and -not $mtx.WaitOne(0)) {
  # 另一個 mag_auto 還拿著鎖：如果它超過 5 分鐘沒更新狀態，就當它卡死，關掉它接手
  $sf = Join-Path $Out 'mag_auto_status.json'
  $stale = (-not (Test-Path $sf)) -or (((Get-Date) - (Get-Item $sf).LastWriteTime).TotalSeconds -gt 300)
  if (-not $stale) { exit 0 }
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*mag_auto.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  "$(Get-Date -f s) watchdog: status stale, killed stuck mag_auto and took over" | Out-File (Join-Path $Out 'mag_auto.log') -Append -Encoding utf8
  try { if (-not $mtx.WaitOne(15000)) { exit 0 } } catch [System.Threading.AbandonedMutexException] { }
}

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
function R1($x) { if ($null -eq $x) { '' } else { [math]::Round($x, 1) } }

function Read-Mag {
  $v = [CticDdeW]::Read([string[]]@($Tag, 'SGB1DC51_CHU2_ST', 'SG_CHU2_Item30041', 'SG_CHU2_Item30043', 'SG_CHU2_Item40035_SCH_ONOFF', 'SG_CHU2_Item30001', 'SG_CHU2_Item30003', $SpTags[0], $SpTags[1]))
  if ($null -eq $v) { return $null }
  [pscustomobject]@{ limit = Num $v[0]; run = Num $v[1]; kw = ((Num $v[2]) + (Num $v[3])); enabled = Num $v[4]; chws = Num $v[5]; chwr = Num $v[6]
                     sp1 = Num $v[7]; sp2 = Num $v[8] }
}

# 小型送風機：有開的台數、比設定熱 1°C 以上的比例、平均 (室溫-設定)
$fcuTags = $null
# 溫度線防作弊（Cliff 2026-11-09 10:30「好」：廠商把送風機溫度線拉到平板燈旁或天花板，讓熱房間失準）
# 1) 冰水回水：主機已到設定（出水 ≤ 設定 + 1.5°C）而回水 − 出水 < 2.0°C → 建築負載低，熱房間再多也不加載、不降出水（11/6 實測：低負載 ΔT ≈ 2.0、滿載 ≈ 3.0）
# 2) 可疑溫度線：開機中連續熱 90 分鐘，或比同樓層房間中位數高 3°C 以上 → 當天不列入熱房間；每天記一筆到 fcu_suspect_log.csv（週報用）
# 3) 參考房間（溫度線位置正確）：B301、B239，可在 C:\BMS_Export\ref_rooms.txt 加（一行：面板 房號，例如 SG_3F31_P01 B301）
#    參考房間有開機時：全部不熱（< 0.5°C）→ 不加載；任一熱（≥ 1°C）→ 視同熱房間多
$DT_LOW = 2.0; $DT_SP_OK = 1.5; $SUS_HOT_MIN = 90; $SUS_MED_DT = 3.0; $HOT_CAP = 0.24; $H4_CAP = 0.39
$REF_ROOMS = [ordered]@{ 'SG_3F31_P01' = 'B301'; 'SG_2F31_P25' = 'B239' }
$RefFile = Join-Path $Out 'ref_rooms.txt'; $SusLog = Join-Path $Out 'fcu_suspect_log.csv'
$script:hotSince = @{}; $script:suspect = @{}; $script:gateCap = $false; $script:gateWhy = ''
function Ref-Rooms {
  $r = [ordered]@{}; foreach ($k in $REF_ROOMS.Keys) { $r[$k] = $REF_ROOMS[$k] }
  try { if (Test-Path $RefFile) { foreach ($l in (Get-Content $RefFile -Encoding UTF8)) { $x = (($l -split '#')[0].Trim() -split '\s+'); if ($x[0]) { $r[$x[0]] = $(if ($x.Count -gt 1) { $x[1] } else { $x[0] }) } } } } catch { }
  return $r
}
function Hot-Gate($hx, $h4, $m, $fcu) {   # 回傳 @(hx, h4)，並設 $script:gateCap／gateWhy
  $script:gateCap = $false; $script:gateWhy = ''
  if ($m -and $m.run -gt 0 -and $m.chws -gt 0 -and $m.chwr -gt 0 -and $m.sp1 -gt 0 -and $m.chws -le $m.sp1 + $DT_SP_OK -and ($m.chwr - $m.chws) -lt $DT_LOW) {
    $script:gateCap = $true; $script:gateWhy = "回水−出水 $(R1 ($m.chwr - $m.chws))°C < $DT_LOW，建築負載低"
  } elseif ($fcu -and $fcu.ref_n -gt 0) {
    if ($fcu.ref_max -lt 0.5) { $script:gateCap = $true; $script:gateWhy = "參考房間（$($fcu.ref_txt)）不熱" }
    elseif ($fcu.ref_max -ge 1.0) { $script:gateWhy = "參考房間熱（$($fcu.ref_txt)）"; $hx = [math]::Max($(if ($null -ne $hx) { $hx } else { 0 }), $ECO_HOT_UP) }
  }
  if ($script:gateCap) { if ($null -ne $hx) { $hx = [math]::Min($hx, $HOT_CAP) }; $h4 = [math]::Min($h4, $H4_CAP) }
  return @($hx, $h4)
}
# 場地租借區（Cliff 2026-11-06 16:21）：挑高又熱，設定下限 20°C；ac_events.txt 有登記的時段照常供冷、下班不關
$ZONES = [ordered]@{
  '會議廳' = @('SG_1F31_P20')                                                   # C104 國際會議廳（SP-21-3 L3、L4）
  '展演'   = @('SG_1F31_P18', 'SG_1F31_P19', 'SG_1F31_P25', 'SG_1F31_P26')       # 展演大廳（SP-21-2 L13、SP-21-3 L05–L08）
  '訓練'   = @('SG_1F31_P15', 'SG_1F31_P14', 'SG_1F31_P17', 'SG_1F31_P16')       # 訓練教室 B131–B134（SP-21-3 L10–L13）
}
$ZONE_ALIAS = @{ 'hall' = '會議廳'; 'expo' = '展演'; 'train' = '訓練'; 'all' = '全部' }   # 英文代號，方便在 PowerShell 打字
$ZONE_SET_MIN = 20.0; $EVENT_PRECOOL_MIN = 30
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
$EVENT_FLOOR = 70; $EVT_HOT_UP = 0.25; $EVT_HOT_DN = 0.15   # 活動中：上限至少 70%，活動區熱房間 ≥ 25% 每 10 分鐘 +10%

function Read-Fcu {
  if ($null -eq $script:fcuTags) {
    if (-not (Test-Path $FcuList)) { return $null }
    $script:fcuTags = [string[]]@(Get-Content $FcuList | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '_FCU\d+_(Run|T|setT)$' -or $_ -match '_(OAT|OAH)$' })
  }
  $v = [CticDdeW]::Read($script:fcuTags, [uint32]1000, 60000)   # 最多 60 秒，讀不完這輪就跳過
  if ($null -eq $v) { return $null }
  $u = @{}; $oa = @{}
  for ($i = 0; $i -lt $fcuTags.Count; $i++) {
    if ($fcuTags[$i] -match '^(.*_FCU\d+)_(Run|T|setT)$') {
      if (-not $u.ContainsKey($matches[1])) { $u[$matches[1]] = @{} }
      $u[$matches[1]][$matches[2]] = Num $v[$i]
    } elseif ($fcuTags[$i] -match '^(.*)_(OAT|OAH)$') {
      if (-not $oa.ContainsKey($matches[1])) { $oa[$matches[1]] = @{} }
      $oa[$matches[1]][$matches[2]] = Num $v[$i]
    }
  }
  $on = 0; $hot = 0; $n = 0; $sum = 0.0; $fl = @{}; $rooms = @{}; $zrooms = @{}; $roomT = @{}
  # 「Run」只代表有通電／連線，不代表有開機（B425 實測 2026-11-06）。真正開機 = 風速 High/Middle/Low 任一為 1。
  $runKeys = @($u.Keys | Where-Object { $u[$_].Run -gt 0.5 })
  $fanState = 'none'; $fanOff = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
  if ($runKeys.Count) {
    $ft = [string[]]@($runKeys | ForEach-Object { "$($_)_Fan_High", "$($_)_Fan_Middle", "$($_)_Fan_Low" })
    $fv = [CticDdeW]::Read($ft, [uint32]1000, 90000)
    $fanState = $(if ($null -eq $fv) { 'read-failed' } else { 'ok' })
    for ($i = 0; $i -lt $runKeys.Count; $i++) {
      $fan = $null
      if ($null -ne $fv) { $a = Num $fv[3*$i]; $b = Num $fv[3*$i+1]; $c = Num $fv[3*$i+2]; if ($null -ne $a -or $null -ne $b -or $null -ne $c) { $fan = ($a -gt 0.5 -or $b -gt 0.5 -or $c -gt 0.5) } }
      if ($fan -eq $false) { $u[$runKeys[$i]].Run = 0; $fanOff++ }
    }
  }
  $ex = @(); if (Test-Path $FcuExclude) { $ex = @(Get-Content $FcuExclude -Encoding UTF8 | ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ }) }
  foreach ($k in $u.Keys) {
    $skip = $false; foreach ($e in $ex) { if ($k.StartsWith($e)) { $skip = $true; break } }
    if ($skip) { continue }
    $f = $u[$k]
    if ($f.Run -gt 0.5) {
      $on++
      if ($f.T -gt 5 -and $f.T -lt 40 -and $f.setT -ge 10 -and $f.setT -le 35) {
        $dlt = $f.T - [math]::Max($f.setT, $SET_FLOOR)   # 使用者設太低（例如 13.5°C）以 24°C 計，不算冷氣不足
        # 以「房間」（同一面板 _Pnn）為單位：同房有一台已經涼了，就代表房間不熱（例如太冷只開一台，B443/B425 實測）
        $room = $k -replace '_FCU\d+$', ''
        if (-not $rooms.ContainsKey($room) -or $dlt -lt $rooms[$room]) { $rooms[$room] = $dlt; $roomT[$room] = $f.T }
        if (In-Zone $k) { $zd = $f.T - [math]::Max($f.setT, $ZONE_SET_MIN); if (-not $zrooms.ContainsKey($room) -or $zd -lt $zrooms[$room]) { $zrooms[$room] = $zd } }
      }
    }
  }
  # ---- 參考房間、可疑溫度線 ----
  $refs = Ref-Rooms; $refD = @(); $refT = @()
  $tn = Get-Date; $today = $tn.ToString('yyyy-MM-dd')
  $byFl = @{}
  foreach ($room in $rooms.Keys) { $fk = $(if ($room -match '^SG_(B1|\d)F') { $matches[1] } else { '?' }); if (-not $byFl.ContainsKey($fk)) { $byFl[$fk] = @() }; $byFl[$fk] += $roomT[$room] }
  $susNow = @{}
  foreach ($k in @($script:hotSince.Keys)) { if (-not $rooms.ContainsKey($k)) { [void]$script:hotSince.Remove($k) } }   # 沒開機的房間重新計時
  foreach ($room in @($rooms.Keys)) {
    $isRef = $false; foreach ($rk in $refs.Keys) { if ($room.StartsWith($rk)) { $isRef = $true; $refD += $rooms[$room]; $refT += "$($refs[$rk]) $(R1 $roomT[$room])°C"; break } }
    $isHot = ($rooms[$room] -ge 1.0)
    if ($isHot) { if (-not $script:hotSince.ContainsKey($room)) { $script:hotSince[$room] = $tn } } else { [void]$script:hotSince.Remove($room) }
    if ($isRef -or -not $isHot) { continue }
    $fk = $(if ($room -match '^SG_(B1|\d)F') { $matches[1] } else { '?' }); $why = ''
    if (($tn - $script:hotSince[$room]).TotalMinutes -ge $SUS_HOT_MIN) { $why = "開機連續熱 $SUS_HOT_MIN 分鐘以上" }
    if ($byFl[$fk].Count -ge 5) { $s2 = @($byFl[$fk] | Sort-Object); $md = $s2[[int][math]::Floor(($s2.Count - 1) / 2)]; if ($roomT[$room] -ge $md + $SUS_MED_DT) { $why = "比同樓層中位數 $(R1 $md)°C 高 $SUS_MED_DT°C 以上" } }
    if ($why) {
      $susNow[$room] = $true
      if (-not $script:suspect.ContainsKey($room) -or $script:suspect[$room] -ne $today) {
        $script:suspect[$room] = $today
        try { if (-not (Test-Path $SusLog)) { 'date,time,panel,room_t,set_dlt,reason' | Out-File $SusLog -Encoding utf8 }; "$today,$($tn.ToString('HH:mm')),$room,$(R1 $roomT[$room]),$(R1 $rooms[$room]),$why" | Out-File $SusLog -Append -Encoding utf8 } catch { }
      }
    }
  }
  $susN = 0
  foreach ($room in @($rooms.Keys)) { if ($script:suspect.ContainsKey($room) -and $script:suspect[$room] -eq $today) { [void]$rooms.Remove($room); $susN++ } }   # 當天不列入熱房間
  $refMax = $(if ($refD.Count) { ($refD | Measure-Object -Maximum).Maximum } else { $null })
  foreach ($room in $rooms.Keys) {
    $dlt = $rooms[$room]; $n++; $sum += $dlt
    $floor = $(if ($room -match '^SG_(B1|\d)F') { $(if ($matches[1] -eq 'B1') { 'B1F' } else { $matches[1] + 'F' }) } else { '?' })
    if (-not $fl.ContainsKey($floor)) { $fl[$floor] = @{ n = 0; hot = 0 } }
    $fl[$floor].n++
    if ($dlt -ge 1.0) { $hot++; $fl[$floor].hot++ }
  }
  $floors = [ordered]@{}
  foreach ($k in ($fl.Keys | Sort-Object)) { $floors[$k] = [ordered]@{ n = $fl[$k].n; hot = [math]::Round($fl[$k].hot / $fl[$k].n, 2) } }
  # 室外露點：空調箱外氣溫濕度感測器，取有效值的中位數（Magnus 公式）
  $dps = @(); $ots = @()
  foreach ($k in $oa.Keys) {
    $t = $oa[$k].OAT; $rh = $oa[$k].OAH
    if ($t -gt 0 -and $t -lt 45) { $ots += $t }
    if ($t -gt 0 -and $t -lt 45 -and $rh -gt 15 -and $rh -le 100) {
      $g = [math]::Log($rh / 100) + 17.62 * $t / (243.12 + $t); $dps += 243.12 * $g / (17.62 - $g)
    }
  }
  $dew = $null; if ($dps.Count) { $s = @($dps | Sort-Object); $dew = $s[[int][math]::Floor(($s.Count - 1) / 2)] }
  $oat = $null; if ($ots.Count) { $s = @($ots | Sort-Object); $oat = $s[[int][math]::Floor(($s.Count - 1) / 2)] }
  [pscustomobject]@{ on = $on; n = $n; hot = $(if ($n) { $hot / $n } else { $null }); dt = $(if ($n) { $sum / $n } else { $null })
                     floors = $floors; zone = $zrooms; dew = $dew; oat = $oat; oa_n = $dps.Count; ref_n = $refD.Count; ref_max = $refMax; ref_txt = ($refT -join '、'); suspect_n = $susN; fan = "$fanState off=$fanOff of=$($runKeys.Count) $([int]$sw.Elapsed.TotalSeconds)s" }
}

function Read-Demand {
  try { $d = Invoke-RestMethod -Uri $Api -TimeoutSec 5 } catch { return $null }
  if (-not $d.ok) { return $null }
  # 兩台電腦時鐘不一定一致：用「資料時間上次改變」到現在的秒數判斷是否失聯
  if ($d.time -ne $script:lastApiTime) { $script:lastApiTime = $d.time; $script:lastApiSeen = Get-Date }
  $age = ((Get-Date) - $script:lastApiSeen).TotalSeconds
  [pscustomobject]@{ age = $age; proj = [double]$d.demand.projected; limit = [double]$d.demand.limit
                     now = [double]$d.demand.now_kw; elapsed = [int]$d.demand.elapsed_s; period = $d.demand.period }
}

function Is-Summer($t) { $md = $t.Month * 100 + $t.Day; return ($md -ge 516 -and $md -le 1015) }
function Is-Eco($t) { return ($t -lt $ECO_UNTIL -and -not (Test-Path $EcoOff) -and $t.DayOfWeek -ne 'Saturday' -and $t.DayOfWeek -ne 'Sunday') }
$ECO_V2_FROM = [datetime]'2026-11-09'
# 平日時段基準（Cliff 2026-11-06 15:35 同意）：上限的「底」，熱房間多再往上加（最多 100%）
# 單日特別設定（Cliff 用手機核准的測試）：日期 → 起、迄、上限底 %。只在那一天、那個時段生效，過了就自動回到上面的時段基準。
$FLOOR_OVERRIDE = @{
  '2026-11-09' = @('07:20', '09:30', 90)   # 星期一 7:20 開機測試，早上上限 90%（Cliff 2026-11-08 10:22）
}
# 指令信箱寫的單日設定（sched_cmd kind=maglimit）：C:\BMS_Export\mag_limit_override.json，{"2026-11-09":{"from":"07:40","to":"09:30","pct":100}}
# 有寫那一天就取代上面表格的那一天。檔案改了才重讀。
$MagOvFile = Join-Path $Out 'mag_limit_override.json'; $script:magOv = @{}; $script:magOvAt = [datetime]::MinValue
function Day-Override($t) {
  $d = $t.ToString('yyyy-MM-dd')
  try {
    if (Test-Path $MagOvFile) {
      $w = (Get-Item $MagOvFile).LastWriteTime
      if ($w -ne $script:magOvAt) {
        $j = Get-Content $MagOvFile -Raw -Encoding UTF8 | ConvertFrom-Json; $m = @{}
        foreach ($p in $j.PSObject.Properties) { $m[$p.Name] = @("$($p.Value.from)", "$($p.Value.to)", [double]$p.Value.pct) }
        $script:magOv = $m; $script:magOvAt = $w
      }
    } else { $script:magOv = @{}; $script:magOvAt = [datetime]::MinValue }
  } catch { }
  if ($script:magOv.ContainsKey($d)) { return $script:magOv[$d] }
  return $FLOOR_OVERRIDE[$d]
}
# 涼爽日模式 v2（Cliff 2026-11-09 08:22「好要做」、08:24 補充）：三個來源一起、整天持續判斷，不是早上判一次就定案
#   1) ECMWF 預報（Open-Meteo ecmwf_ifs025，與需量預測同座標）：今天剩下到 16:00 的最高溫、今天雨量，每 3 小時更新
#   2) 現場外氣溫濕度計（空調箱 OAT/OAH，取有效值中位數）：現在外氣溫度、露點
#   3) 室內送風機：最熱樓層熱房間比例、4 樓熱房間比例
# 進入（全部成立）：預報剩餘最高 ≤ 25°C（或雨 ≥ 5 mm 且 ≤ 27°C）、外氣 ≤ 25°C、露點 ≤ 19°C、最熱樓層熱房間 < 15% 且 4 樓 < 30%
# 離開（任一成立）：預報剩餘最高 > 27°C、外氣 > 27°C、露點 > 21°C、最熱樓層熱房間 ≥ 25% 或 4 樓 ≥ 40%
# 切換後至少維持 30 分鐘（避免來回跳）。很涼（預報 ≤ 22°C 且外氣 ≤ 22°C）再多降 10 點。
# 涼爽時：16:00 前上限底 −20（很涼 −30，最低 30%）；出水 13–14°C（很涼 13.5–14）。熱房間回饋照常往上加。
# 指令信箱的單日上限（mag_limit_override.json）仍然最優先。強制開／關：C:\BMS_Export\cool_on.txt／cool_off.txt
# 預報抓不到：只用外氣＋室內（外氣 ≤ 23°C 才算涼）；外氣也讀不到 → 一般日。
$COOL_TMAX = 25.0; $COOL_RAIN_MM = 5.0; $COOL_RAIN_TMAX = 27.0; $COOL_EXIT_T = 27.0; $COOL_COLD_T = 22.0
$COOL_DEW_IN = 19.0; $COOL_DEW_OUT = 21.0; $COOL_HOLD_MIN = 30; $COOL_DROP = 20; $COOL_DROP2 = 30
$COOL_URL = 'https://api.open-meteo.com/v1/forecast?latitude=23.936537&longitude=120.697917&hourly=temperature_2m,precipitation&daily=temperature_2m_max,precipitation_sum&timezone=Asia%2FTaipei&forecast_days=1'
$CoolFile = Join-Path $Out 'cool_day.json'; $script:wx = $null; $script:wxTry = [datetime]::MinValue
$script:coolLvl = 0; $script:coolSince = [datetime]::MinValue; $script:cool = $null
function Get-Wx($t) {   # ECMWF 預報，每 3 小時更新；失敗 20 分鐘後再試；先用 ECMWF，不行用預設模式
  $d = $t.ToString('yyyy-MM-dd')
  if (-not $script:wx) { try { if (Test-Path $CoolFile) { $c = Get-Content $CoolFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($c.wx -and $c.wx.date -eq $d) { $script:wx = $c.wx } } } catch { } }
  $stale = (-not $script:wx) -or $script:wx.date -ne $d -or ($t - [datetime]$script:wx.fetched).TotalMinutes -ge 180
  if ($stale -and ($t - $script:wxTry).TotalMinutes -ge 20) {
    $script:wxTry = $t
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($mdl in @('ecmwf_ifs025', '')) {
      try {
        $u = $COOL_URL + $(if ($mdl) { "&models=$mdl" } else { '' })
        $w = Invoke-RestMethod -Uri $u -TimeoutSec 15
        $hr = @(); for ($i = 0; $i -lt $w.hourly.time.Count; $i++) { $v = $w.hourly.temperature_2m[$i]; if ($null -ne $v) { $hr += [pscustomobject]@{ h = ([datetime]$w.hourly.time[$i]).Hour; t = [double]$v } } }
        if (-not $hr.Count) { continue }
        $rain = 0.0; foreach ($x in $w.hourly.precipitation) { if ($null -ne $x) { $rain += [double]$x } }
        $script:wx = [pscustomobject]@{ date = $d; model = $(if ($mdl) { 'ECMWF' } else { 'best_match' }); fetched = $t.ToString('yyyy-MM-dd HH:mm:ss'); rain = [math]::Round($rain, 1); hourly = $hr }
        break
      } catch { }
    }
  }
  if ($script:wx -and $script:wx.date -eq $d) { return $script:wx }
  return $null
}
# 現場外氣鎖定（2026-11-10）：PLC 規則「外氣 SGB1DC51_CHU1_OAH 低於設定值 CHU1_OAH_SP（目前 22°C）冰機不開機」。
# 從 ac_logger 的 ac_latest.json 讀（5 分鐘內的才用）。涼爽日「很涼」門檻改用這個設定值，外氣感測器讀不到時也拿它補。
function Plant-Oa {
  try {
    $a = Get-Content (Join-Path $Out 'ac_latest.json') -Raw | ConvertFrom-Json
    if (((Get-Date) - [datetime]::ParseExact($a.time, 'yyyy-MM-dd HH:mm:ss', $null)).TotalMinutes -gt 5) { return $null }
    $o = $a.oat_c; $sp = $a.oat_sp_c
    return [pscustomobject]@{ oat = $(if ($o -gt 0 -and $o -lt 45) { [double]$o } else { $null }); sp = $(if ($sp -gt 10 -and $sp -lt 35) { [double]$sp } else { $null }) }
  } catch { return $null }
}
function Cool-Eval($t, $fcu, $m) {   # 每一輪 Step 開頭呼叫一次
  $why = @(); $lvl = 0
  if (Test-Path (Join-Path $Out 'cool_off.txt')) { $script:coolLvl = 0; $script:cool = [ordered]@{ cool = $false; level = 0; why = '手動關閉 cool_off.txt' }; return }
  if (Test-Path (Join-Path $Out 'cool_on.txt'))  { $script:coolLvl = 1; $script:cool = [ordered]@{ cool = $true; level = 1; why = '手動開啟 cool_on.txt' }; return }
  $wx = $null; try { $wx = Get-Wx $t } catch { }
  $fmax = $null; $rain = $null
  if ($wx) {
    $end = $(if ($t.Hour -lt 16) { 16 } else { 23 })
    $rest = @($wx.hourly | Where-Object { $_.h -ge $t.Hour -and $_.h -le $end } | ForEach-Object { $_.t })
    if ($rest.Count) { $fmax = ($rest | Measure-Object -Maximum).Maximum }
    $rain = [double]$wx.rain
  }
  $oat = $(if ($fcu) { $fcu.oat }); $dew = $(if ($fcu) { $fcu.dew })
  $po = Plant-Oa; if ($null -eq $oat -and $po) { $oat = $po.oat }
  $coldT = $(if ($po -and $null -ne $po.sp) { $po.sp } else { $COOL_COLD_T })
  $hx = $null; $h4 = 0.0
  if ($fcu -and $fcu.floors) { foreach ($k in $fcu.floors.Keys) { $f = $fcu.floors[$k]; if ($f.n -lt 5) { continue }; if ($k -eq '4F') { $h4 = $f.hot } elseif ($null -eq $hx -or $f.hot -gt $hx) { $hx = $f.hot } } }
  $g = Hot-Gate $hx $h4 $m $fcu; $hx = $g[0]; $h4 = $g[1]
  # 離開條件
  $exit = @()
  if ($null -ne $fmax -and $fmax -gt $COOL_EXIT_T) { $exit += "預報最高 $(R1 $fmax)°C" }
  if ($null -ne $oat -and $oat -gt $COOL_EXIT_T) { $exit += "外氣 $(R1 $oat)°C" }
  if ($null -ne $dew -and $dew -gt $COOL_DEW_OUT) { $exit += "露點 $(R1 $dew)°C" }
  if ($null -ne $hx -and ($hx -ge $ECO_HOT_UP -or $h4 -ge $ECO_4F_UP)) { $exit += "熱房間 $([math]::Round([math]::Max($hx,0)*100))%/4F $([math]::Round($h4*100))%" }
  # 進入條件
  $fcOk = $(if ($null -ne $fmax) { ($fmax -le $COOL_TMAX) -or ($rain -ge $COOL_RAIN_MM -and $fmax -le $COOL_RAIN_TMAX) } else { $null })
  $oaOk = $(if ($null -ne $oat) { $oat -le $(if ($null -eq $fcOk) { 23.0 } else { $COOL_TMAX }) } else { $null })
  $enter = ($fcOk -ne $false) -and ($oaOk -ne $false) -and ($null -ne $fcOk -or $null -ne $oaOk) -and
           ($null -eq $dew -or $dew -le $COOL_DEW_IN) -and ($null -eq $hx -or ($hx -lt $ECO_HOT_DN -and $h4 -lt $ECO_4F_OK))
  $cold = ($null -ne $fmax -and $fmax -le $coldT) -and ($null -eq $oat -or $oat -le $coldT)
  $held = ($t - $script:coolSince).TotalMinutes -lt $COOL_HOLD_MIN
  $prev = $script:coolLvl
  if ($prev -gt 0) {
    if ($exit.Count -and -not $held) { $lvl = 0 } else { $lvl = $(if ($cold -and $enter) { 2 } elseif ($prev -eq 2 -and -not $cold -and -not $held) { 1 } else { $prev }) }
  } elseif ($enter -and -not $exit.Count -and -not $held) { $lvl = $(if ($cold) { 2 } else { 1 }) }
  if ($lvl -ne $prev) { $script:coolSince = $t; $script:coolLvl = $lvl }
  $src = "預報($(if($wx){$wx.model}else{'無'})) 剩餘最高 $(R1 $fmax)°C 雨 $(R1 $rain)mm；外氣 $(R1 $oat)°C 露點 $(R1 $dew)°C；開機門檻 $(R1 $coldT)°C；熱房間 $(if($null -ne $hx){[math]::Round($hx*100)}else{'-'})% 4F $([math]::Round($h4*100))%"
  $script:cool = [ordered]@{ cool = ($lvl -gt 0); level = $lvl; since = $script:coolSince.ToString('HH:mm'); exit = ($exit -join '、'); why = $src }
  try { ([ordered]@{ date = $t.ToString('yyyy-MM-dd'); state = $script:cool; wx = $script:wx } | ConvertTo-Json -Compress -Depth 5) | Out-File $CoolFile -Encoding utf8 } catch { }
}
function Cool-Day($t) { return ($script:coolLvl -gt 0) }
function Eco-Floor($t) {
  $h = $t.ToString('HH:mm')
  $o = Day-Override $t
  if ($o -and $h -ge $o[0] -and $h -lt $o[1]) { return $o[2] }
  $f = Eco-Floor-Base $t $h
  if ($h -lt '16:00' -and (Cool-Day $t)) { return [math]::Max(30, $f - $(if ($script:coolLvl -ge 2) { $COOL_DROP2 } else { $COOL_DROP })) }   # 涼爽日
  return $f
}
function Eco-Floor-Base($t, $h) {
  $v2 = $t -ge $ECO_V2_FROM            # 11/9 起早上與中午再降（Cliff 2026-11-06 15:54 同意）
  if ($h -lt '09:30') { if ($v2) { return 75 } else { return 90 } }    # 早上剛上班最悶
  if ($h -lt '11:00') { return 65 }
  if ($h -lt '14:00') { if ($v2) { return 70 } else { return 80 } }    # 餐廳營業、外氣最熱
  if ($h -lt '16:00') { return 60 }
  if ($h -lt '17:00') { return 40 }    # 16:00–17:00（Cliff 2026-11-06 17:06）
  return 30                            # 17:00–18:00；18:00 後另有固定 30%
}
function Sp-Band($t) {   # 出水設定季節上下限
  if ((Cool-Day $t) -and -not (Is-Summer $t)) { if ($script:coolLvl -ge 2) { return @(13.5, 14.0) } else { return @(13.0, 14.0) } }   # 涼爽日：早上也 13–14°C（非夏月，含 12 月後）
  if (Is-Eco $t) { if ($t.ToString('HH:mm') -lt '09:30') { return @(12.0, 13.0) } else { return @(13.0, 14.0) } }   # 早上出水冷一點除濕；白天上限 14（15:13 Cliff）
  $md = $t.Month * 100 + $t.Day
  if ($md -ge 516 -and $md -le 1015) { return @(10.5, 11.5) }
  if ($md -ge 1201 -or $md -le 331) { return @(12.0, 14.0) }
  return @(11.5, 13.0)
}
function In-Window($t) { $hm = $t.ToString('HH:mm'); return ($hm -ge $C_START -and $hm -lt $C_END) }

# ---- 狀態 ----
$lastApiTime = $null; $lastApiSeen = Get-Date
$mode = $(if ($Live) { 'LIVE' } else { 'DRY' })
$sim = $null                 # 試跑時假想的現值
$base = $null                # 沒有需量保護時的負載上限（人員設定值）
$spSim = $null; $spLastWrite = $null; $lastSpStep = [datetime]::MinValue; $spWant = $null
$cap = $null                 # 需量保護上限（null = 沒有在限制）
$lastWrite = $null
$lastDStep = [datetime]::MinValue; $lastCStep = [datetime]::MinValue; $lastBoost = [datetime]::MinValue; $lastTight = [datetime]::MinValue; $lastEco = [datetime]::MinValue; $afterSet = $false; $evtOn = $false; $evtText = ''; $evtHot = $null
$clearSince = $null; $lostSince = $null; $manualUntil = [datetime]::MinValue
$fcu = $null; $fcuAt = [datetime]::MinValue
$lastAction = ''; $lastActionAt = ''

function Write-Limit([double]$p, [string]$why) {
  $p = [math]::Max($MIN, [math]::Min($MAX, [math]::Round($p)))
  $script:lastAction = "$why -> $p%"; $script:lastActionAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  if ($Live) {
    $ok = [CticDdeW]::Poke($Tag, $p.ToString($inv))
    $n = Get-Date; $t = $n.AddMinutes($(if ($n.Second -ge 50) { 2 } else { 1 }))
    if ($t.Hour -eq 22 -and $t.Minute -eq 0) { $t = $t.AddMinutes(1) }   # 啟用時間不能等於停用時間 22:00
    $okH = [CticDdeW]::Poke('SG_CHU2_Item40035_TIME_SET1_H', "$($t.Hour)")
    $okM = [CticDdeW]::Poke('SG_CHU2_Item40035_TIME_SET1_M', "$($t.Minute)")
    $script:lastWrite = $p
    return "$why->$p poke=$ok start=$('{0:HH:mm}' -f $t) ok=$okH/$okM"
  }
  $script:sim = $p
  return "WOULD $why->$p"
}

function Write-Sp([double]$t, [string]$why) {
  $t = [math]::Max($SP_HARD_MIN, [math]::Min($SP_HARD_MAX, [math]::Round($t * 2) / 2))
  $script:lastAction = "$why -> 出水設定 $t°C"; $script:lastActionAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  if ($Live) {
    $ok1 = [CticDdeW]::Poke($SpTags[0], $t.ToString($inv)); $ok2 = [CticDdeW]::Poke($SpTags[1], $t.ToString($inv))
    $script:spLastWrite = $t
    return "$why->sp$t poke=$ok1/$ok2"
  }
  $script:spSim = $t
  return "WOULD $why->sp$t"
}

function Save($now, $d, $m, $cur, $tgt, $action, $note) {
  $f = Join-Path $Out ('mag_auto_' + $now.ToString('yyyy-MM-dd') + '.csv')
  if (-not (Test-Path $f)) { 'time,mode,period,contract_kw,projected_kw,ratio,now_kw,data_age_s,chu2_run,mag_kw,chws_c,chwr_c,chws_target,fcu_on,hot_share,avg_dt,limit_read,limit_eff,base,cap,sp_read,sp_eff,hot_max_floor,hot_4f,dewpoint,action,note' | Out-File $f -Encoding utf8 }
  $hm = $null; $h4 = $null
  if ($fcu -and $fcu.floors) { foreach ($k in $fcu.floors.Keys) { if ($fcu.floors[$k].n -ge 5 -and ($null -eq $hm -or $fcu.floors[$k].hot -gt $hm)) { $hm = $fcu.floors[$k].hot } }; if ($fcu.floors.Contains('4F')) { $h4 = $fcu.floors['4F'].hot } }
  $spE = $(if (-not $Live -and $null -ne $spSim) { $spSim } elseif ($m) { $m.sp1 })
  $r = $(if ($d) { [math]::Round($d.proj / $d.limit, 3) } else { $null })
  $row = @($now.ToString('yyyy-MM-dd HH:mm:ss'), $mode, $(if($d){$d.period}), $(if($d){$d.limit}), $(if($d){$d.proj}), $r,
           $(if($d){$d.now}), $(if($d){[int]$d.age}), $(if($m){$m.run}), $(if($m){R1 $m.kw}), $(if($m){R1 $m.chws}), $(if($m){R1 $m.chwr}), $tgt,
           $(if($fcu){$fcu.on}), $(if($fcu -and $null -ne $fcu.hot){[math]::Round($fcu.hot,2)}), $(if($fcu){R1 $fcu.dt}),
           $(if($m){$m.limit}), $cur, $base, $cap, $(if($m){$m.sp1}), $spE, $hm, $h4, $(if($fcu){R1 $fcu.dew}), $action, $note) -join ','
  $row | Out-File $f -Append -Encoding utf8
  $st = [ordered]@{
    time = $now.ToString('yyyy-MM-dd HH:mm:ss'); mode = $mode; comfort_on = (-not $NoComfort); off = (Test-Path $Off)
    enabled = $(if ($m) { $m.enabled -ge 0.5 }); running = $(if ($m) { $m.run -gt 0 })
    limit_read = $(if ($m) { $m.limit }); limit = $cur; base = $base; cap = $cap
    sp_read = $(if ($m) { $m.sp1 }); sp = $spE; floors = $(if ($fcu) { $fcu.floors }); dewpoint = $(if ($fcu) { R1 $fcu.dew }); oa_n = $(if ($fcu) { $fcu.oa_n }); fan_check = $(if ($fcu) { $fcu.fan })
    chws_c = $(if ($m) { R1 $m.chws }); chws_target = $tgt; fcu_on = $(if ($fcu) { $fcu.on })
    hot_share = $(if ($fcu -and $null -ne $fcu.hot) { [math]::Round($fcu.hot, 2) }); ratio = $r
    manual_hold = ($now -lt $manualUntil); cool_day = $(if ($script:cool) { $script:cool }); event = $evtText; event_hot = $evtHot; hot_gate = $gateWhy; ref_rooms = $(if ($fcu) { $fcu.ref_txt }); suspect_n = $(if ($fcu) { $fcu.suspect_n }); note = $note; last_action = $lastAction; last_action_at = $lastActionAt
  }
  ($st | ConvertTo-Json -Compress -Depth 5) | Out-File (Join-Path $Out 'mag_auto_status.json') -Encoding utf8
  if ($action) { Write-Host $row }
}

# 外氣開機門檻守門（2026-11-13 Cliff 授權）：PLC 點 SGB1DC51_CHU1_OAH_SP（外氣低於它冰機不開機）固定 21.5°C。
# 原本 22°C 時廠商反映太悶，同仁改 21.5 後好很多。每分鐘讀一次，高於 21.5 就寫回 21.5（最多每 10 分鐘寫一次）；
# 低於 21.5 不動（只限制上限）。停用：C:\BMS_Export\oa_sp_guard_off.txt。
$OA_SP_TAG = 'SGB1DC51_CHU1_OAH_SP'; $OA_SP_MAX = 21.5
$script:oaSpAt = [datetime]::MinValue; $script:oaSpWriteAt = [datetime]::MinValue
function Oa-Sp-Guard($now) {
  if (($now - $script:oaSpAt).TotalSeconds -lt 60) { return }
  $script:oaSpAt = $now
  if (Test-Path (Join-Path $Out 'oa_sp_guard_off.txt')) { return }
  $v = [CticDdeW]::Read([string[]]@($OA_SP_TAG)); $x = 0.0
  if ($null -eq $v -or -not [double]::TryParse("$($v[0])", [Globalization.NumberStyles]::Float, $inv, [ref]$x)) { return }
  if ($x -le 10 -or $x -ge 35 -or $x -le $OA_SP_MAX + 0.05) { return }
  if (($now - $script:oaSpWriteAt).TotalMinutes -lt 10) { return }
  $script:oaSpWriteAt = $now
  if ($Live) {
    $ok = [CticDdeW]::Poke($OA_SP_TAG, $OA_SP_MAX.ToString($inv))
    $script:lastAction = "外氣開機門檻被改成 $x°C，已調回 $OA_SP_MAX°C（poke=$ok）"; $script:lastActionAt = $now.ToString('yyyy-MM-dd HH:mm:ss')
  }
  "$($now.ToString('s')) OA_SP $x -> $OA_SP_MAX live=$Live" | Out-File (Join-Path $Out 'mag_auto.log') -Append -Encoding utf8
}

# 磁浮排程自動補勾（2026-11-14 Cliff 授權：同仁忘記勾磁浮，可自己勾選啟動，事後通知）
# 上班日（週一到週五，C:\BMS_Export\holidays.txt 列的日期除外）至少要涵蓋 07:30–18:00；
# ac_events.txt 有登記的活動日，要涵蓋「活動開始前 30 分鐘 → 活動結束」。
# 從需要時段開始前 30 分鐘到結束，每 5 分鐘讀當天的 CHU2_SCH 排程：沒勾 → 勾上；時間沒涵蓋 → 只加長、不縮短。
# 已經過了開機時間才補 → 開機時間設成 2 分鐘後（InTouch 在開機那一分鐘才觸發）。外氣低於門檻沒開是規則，不在這裡處理。
# 只寫 CHU2_SCH 當天的 5 個點，不碰 *_Run。停用：C:\BMS_Export\chu2_guard_off.txt。每天最多補 3 次。
$WORK_ON = '07:30'; $WORK_OFF = '18:00'
$script:chu2At = [datetime]::MinValue; $script:chu2Day = ''; $script:chu2N = 0
function Hm-Min($s) { $a = "$s".Split(':'); return [int]$a[0] * 60 + [int]$a[1] }
function Min-Hm($m) { return '{0:00}:{1:00}' -f [math]::Floor($m / 60), ($m % 60) }
function Chu2-Need($t) {
  $d = $t.ToString('yyyy-MM-dd'); $on = $null; $off = $null; $why = @()
  $hol = Join-Path $Out 'holidays.txt'
  $isHol = (Test-Path $hol) -and (@(Get-Content $hol | ForEach-Object { ($_ -replace '#.*$', '').Trim() }) -contains $d)
  if ($t.DayOfWeek -ne 'Saturday' -and $t.DayOfWeek -ne 'Sunday' -and -not $isHol) { $on = Hm-Min $WORK_ON; $off = Hm-Min $WORK_OFF; $why += '上班日' }
  if (Test-Path $EventFile) {
    foreach ($line in (Get-Content $EventFile -Encoding UTF8)) {
      $l = ($line -replace '#.*$', '').Trim(); $p = @($l -split '\s+')
      if ($p.Count -lt 3 -or $p[0] -ne $d -or $p[1] -notmatch '^(\d{1,2}:\d{2})-(\d{1,2}:\d{2})$') { continue }
      $s1 = (Hm-Min $matches[1]) - $EVENT_PRECOOL_MIN; $e1 = Hm-Min $matches[2]
      $on = $(if ($null -eq $on) { $s1 } else { [math]::Min($on, $s1) }); $off = $(if ($null -eq $off) { $e1 } else { [math]::Max($off, $e1) }); $why += "活動 $($p[1])"
    }
  }
  if ($null -eq $on) { return $null }
  return [pscustomobject]@{ on = $on; off = $off; why = ($why -join '、') }
}
function Chu2-Guard($now) {
  if (($now - $script:chu2At).TotalSeconds -lt 300) { return }
  $script:chu2At = $now
  if (Test-Path (Join-Path $Out 'chu2_guard_off.txt')) { return }
  $day = $now.ToString('yyyy-MM-dd'); if ($script:chu2Day -ne $day) { $script:chu2Day = $day; $script:chu2N = 0 }
  if ($script:chu2N -ge 3) { return }
  $need = Chu2-Need $now; if (-not $need) { return }
  $nm = $now.Hour * 60 + $now.Minute
  if ($nm -lt $need.on - 30 -or $nm -ge $need.off) { return }
  $dn = $(if ($now.DayOfWeek -eq 'Sunday') { 7 } else { [int]$now.DayOfWeek }); $dd = '{0:00}' -f $dn
  $tags = [string[]]@("CHU2_SCH_$($dd)_StartHH", "CHU2_SCH_$($dd)_StartMM", "CHU2_SCH_$($dd)_StopHH", "CHU2_SCH_$($dd)_StopMM", "CHU2_SCH_$($dd)SCHEn")
  $v = [CticDdeW]::Read($tags); if ($null -eq $v) { return }
  $n = @(); foreach ($x in $v) { $y = 0.0; if (-not [double]::TryParse("$x", [Globalization.NumberStyles]::Float, $inv, [ref]$y)) { return }; $n += [int][math]::Round($y) }
  $curOn = $n[0] * 60 + $n[1]; $curOff = $n[2] * 60 + $n[3]; $en = $n[4]
  $okNow = ($en -eq 1 -and $curOn -le $need.on -and $curOff -ge $need.off)
  if ($okNow) { return }
  $newOn = $(if ($en -eq 1) { [math]::Min($curOn, $need.on) } else { $need.on }); $newOff = $(if ($en -eq 1) { [math]::Max($curOff, $need.off) } else { [math]::Max($need.off, $curOff) })
  if ($nm -ge $newOn) { $newOn = $nm + 2 }          # 已過開機時間：設 2 分鐘後讓 InTouch 觸發
  if ($newOff -le $newOn) { return }
  $script:chu2N++
  $old = "$(Min-Hm $curOn)–$(Min-Hm $curOff)（$(if ($en -eq 1) { '有勾' } else { '沒勾' })）"; $new = "$(Min-Hm $newOn)–$(Min-Hm $newOff)（有勾）"
  if ($Live) {
    $vals = @([math]::Floor($newOn / 60), ($newOn % 60), [math]::Floor($newOff / 60), ($newOff % 60), 1)
    for ($i = 0; $i -lt 5; $i++) { $null = [CticDdeW]::Poke($tags[$i], "$($vals[$i])"); Start-Sleep -Milliseconds 300 }
    $script:lastAction = "磁浮排程自動補勾（$($need.why)）：今天 $old → $new"; $script:lastActionAt = $now.ToString('yyyy-MM-dd HH:mm:ss')
  }
  "$($now.ToString('s')) CHU2_GUARD $($need.why) $old -> $new live=$Live" | Out-File (Join-Path $Out 'mag_auto.log') -Append -Encoding utf8
}

function Step {
  $now = Get-Date
  try { Oa-Sp-Guard $now } catch { }
  try { Chu2-Guard $now } catch { }
  $m = Read-Mag
  $d = Read-Demand
  if (-not $m -or $null -eq $m.limit) { Save $now $d $m '' '' '' 'no-intouch'; return }
  if (($now - $fcuAt).TotalSeconds -ge 300) { try { $script:fcu = Read-Fcu } catch { $script:fcu = $null }; $script:fcuAt = $now }
  try { Cool-Eval $now $fcu $m } catch { }
  $cur = $(if (-not $Live -and $null -ne $sim) { $sim } else { $m.limit })
  $sp  = $(if (-not $Live -and $null -ne $spSim) { $spSim } else { $m.sp1 })
  $action = ''; $note = ''

  # 人員手動改了 → 讓手 60 分鐘
  $manLimit = ($Live -and $null -ne $lastWrite -and [math]::Abs($m.limit - $lastWrite) -gt 0.5)
  $manSp = ($Live -and $null -ne $spLastWrite -and $null -ne $m.sp1 -and [math]::Abs($m.sp1 - $spLastWrite) -gt 0.05)
  if ($manLimit -or $manSp) {
    $script:base = $m.limit; $script:cap = $null; $script:lastWrite = $null; $script:spLastWrite = $null
    $script:manualUntil = $now.AddSeconds($MANUAL_HOLD_S)
    $what = $(if ($manSp) { "出水設定 $($m.sp1)°C" } else { "負載上限 $($m.limit)%" })
    $script:lastAction = "人員手動改成$what，程式讓手 60 分鐘"; $script:lastActionAt = $now.ToString('yyyy-MM-dd HH:mm:ss')
    Save $now $d $m $m.limit '' 'manual-override' ''; return
  }
  if (Test-Path $Off) { $script:sim = $null; $script:spSim = $null; $script:cap = $null; $script:base = $null; Save $now $d $m $m.limit '' '' 'off-switch'; return }
  if ($null -eq $cap) { $script:base = $cur }   # 沒在降載時，記住人員設定的負載上限

  # ---- 1) 契約需量（負載上限；需要「是否啟用」打勾才有效）----
  $ratio = $null
  if (-not $d -or $d.age -gt $STALE_S) {
    if ($null -eq $lostSince) { $script:lostSince = $now }
    $note = 'no-demand-data'
    if ($null -ne $cap -and ($now - $lostSince).TotalSeconds -ge $LOST_RESTORE_S) { $script:cap = $null; $note = 'no-demand-data-release-cap' }
  } else {
    $script:lostSince = $null
    $ratio = $d.proj / $d.limit
    $high = ($ratio -ge $HARD -or ($ratio -ge $TRIG -and $d.elapsed -ge 60))
    if ($high -and $m.run -gt 0 -and $m.enabled -ge 0.5) {
      $script:clearSince = $null
      if (($now - $lastDStep).TotalSeconds -ge $D_STEP_S -and $cur -gt $MIN) {
        $script:cap = [math]::Max($MIN, [math]::Min($MAX, $cur - $D_STEP)); $script:lastDStep = $now; $note = 'demand-derate'
      }
    } elseif ($null -ne $cap) {
      if ($ratio -lt $CLEAR) {
        if ($null -eq $clearSince) { $script:clearSince = $now }
        if (($now - $clearSince).TotalSeconds -ge $CLEAR_S -and ($now - $lastDStep).TotalSeconds -ge $D_STEP_S) {
          $script:cap = $cap + $D_STEP; $script:lastDStep = $now; $note = 'demand-release'
          if ($cap -ge $base) { $script:cap = $null; $script:clearSince = $null }
        }
      } else { $script:clearSince = $null }
    }
  }
  if ($m.enabled -lt 0.5 -and $note -notmatch 'demand') { $note = ($note + ' limit-not-enabled').Trim() }

  # 樓層熱房間（非 4 樓最熱樓層、4 樓）
  $hmX = $null; $hmXFloor = ''; $h4f = 0.0
  if ($fcu -and $fcu.floors) {
    foreach ($k in $fcu.floors.Keys) {
      $f = $fcu.floors[$k]; if ($f.n -lt 5) { continue }
      if ($k -eq '4F') { $h4f = $f.hot } elseif ($null -eq $hmX -or $f.hot -gt $hmX) { $hmX = $f.hot; $hmXFloor = $k }
    }
  }
  $g = Hot-Gate $hmX $h4f $m $fcu; $hmX = $g[0]; $h4f = $g[1]
  $eco = Is-Eco $now

  # ---- 1b) 平時上限（沒有在需量降載、沒有人員讓手時才調）----
  if ($null -eq $cap -and $now -ge $manualUntil -and $m.run -gt 0 -and $m.enabled -ge 0.5 -and $note -notmatch 'demand-(derate|release)') {
    # 遲滯（2026-11-09 08:32 實測：需量在 0.89–0.91 之間時上限 100↔90 每 10 秒來回跳）：
    # ≥ 90% 退回 90%；之後要 < 85% 且離上次「接近契約」滿 10 分鐘，才可以再升到 90% 以上。已在 100% 時 85–90% 之間維持不動。
    if ($null -eq $ratio -or $ratio -ge $BOOST_OFF) { $script:lastTight = $now }
    $tight = ($null -eq $ratio -or $ratio -ge $BOOST_OFF -or ($now - $lastTight).TotalSeconds -lt $BOOST_UP_S -or ($ratio -ge $BOOST_ON -and $base -le $BASE_LO + 0.5))
    $hmNow = $now.ToString('HH:mm')
    $ev = Event-Now $now; $script:evtText = $ev.text; $script:evtHot = $null
    if ($ev.panels.Count) {
      # 場地租借活動：活動區熱房間決定上限（至少 70%），不套 18:00 固定 40% 與週末 30%
      $zr = @(); if ($fcu -and $fcu.zone) { foreach ($k in $fcu.zone.Keys) { foreach ($pp in $ev.panels) { if ($k.StartsWith($pp)) { $zr += $fcu.zone[$k]; break } } } }
      if ($zr.Count) { $script:evtHot = [math]::Round(@($zr | Where-Object { $_ -ge 1.0 }).Count / $zr.Count, 2) }
      $top = $(if ($tight) { $BASE_LO } else { $BASE_HI })
      $evFl = $(if ($eco) { [math]::Max($EVENT_FLOOR, (Eco-Floor $now)) } else { $EVENT_FLOOR })
      $wantB = $base
      if (-not $evtOn -or $base -lt $evFl - 0.5) { $wantB = [math]::Max($base, $evFl) }
      elseif ($null -eq $evtHot) { }
      elseif ($evtHot -ge $EVT_HOT_UP) { if (($now - $lastEco).TotalSeconds -ge $ECO_STEP_S) { $wantB = $base + $ECO_STEP } }
      elseif ($evtHot -lt $EVT_HOT_DN) { if (($now - $lastEco).TotalSeconds -ge $ECO_STEP_S) { $wantB = [math]::Max($evFl, $base - $ECO_STEP) } }
      $wantB = [math]::Min([math]::Max($top, $evFl), $wantB); if ($tight) { $wantB = [math]::Min($BASE_LO, $wantB) }
      $script:evtOn = $true; $script:afterSet = $false
      if ([math]::Abs($wantB - $base) -ge 0.5) { $note = ($note + $(if ($wantB -gt $base) { ' event-up' } else { ' event-down' })).Trim(); $script:base = $wantB; $script:lastEco = $now }
    } elseif ($evtOn) {
      # 活動結束：回到平常（18:00 後 40%、週末 30%、平日照時段基準）
      $script:evtOn = $false; $script:lastEco = $now
      $script:base = $(if ($hmNow -ge $AFTER_START) { $script:afterSet = $true; $AFTER_LIMIT } elseif ($eco) { Eco-Floor $now } elseif ($now.DayOfWeek -eq 'Saturday' -or $now.DayOfWeek -eq 'Sunday') { 30 } else { $BASE_LO })
      $note = ($note + ' event-end').Trim()
    }
    if ($ev.panels.Count -or $note -match 'event-end') { }
    elseif ($hmNow -ge $AFTER_START) {
      # 18:00 以後加班空調：上限固定 40%（不因熱房間加）
      if (-not $afterSet -or [math]::Abs($base - $AFTER_LIMIT) -ge 0.5) {
        $script:base = $AFTER_LIMIT; $script:afterSet = $true; $note = ($note + ' after-hours').Trim()
      }
    } elseif ($afterSet) {
      # 隔天開機：回到平時上限
      $script:afterSet = $false
      $script:base = $(if ($eco) { Eco-Floor $now } elseif ($now.DayOfWeek -eq 'Saturday' -or $now.DayOfWeek -eq 'Sunday') { 30 } else { $BASE_LO }); $script:lastEco = $now; $note = ($note + ' after-hours-end').Trim()   # 週末照慣例 30%
    }
    if ($hmNow -ge $AFTER_START -or $note -match 'after-hours-end') { }
    elseif ($eco) {
      # 節電：時段基準（Eco-Floor）＋熱房間回饋；時段換到更高的基準時立刻拉上去
      $fl = Eco-Floor $now
      $top = $(if ($tight) { $BASE_LO } else { $BASE_HI })
      $wantB = $base
      if ($base -lt $fl - 0.5) { $wantB = $fl }
      elseif ($null -eq $hmX) { $wantB = [math]::Min($top, [math]::Max($base, 80)) }   # 讀不到送風機 → 保守 80%
      elseif ($hmX -ge $ECO_HOT_UP -or $h4f -ge $ECO_4F_UP) { if (($now - $lastEco).TotalSeconds -ge $ECO_STEP_S) { $wantB = [math]::Min($top, $base + $ECO_STEP) } }
      elseif ($hmX -lt $ECO_HOT_DN -and $h4f -lt $ECO_4F_OK) { if (($now - $lastEco).TotalSeconds -ge $ECO_STEP_S) { $wantB = [math]::Max($fl, $base - $ECO_STEP) } }
      $wantB = [math]::Min([math]::Max($top, $fl), $wantB); if ($tight) { $wantB = [math]::Min($BASE_LO, $wantB) }
      if ([math]::Abs($wantB - $base) -ge 0.5) {
        $note = ($note + $(if ($wantB -gt $base) { ' eco-up' } else { ' eco-down' })).Trim()
        $script:base = $wantB; $script:lastEco = $now
      }
    } elseif ($null -eq $ratio) {
      if ($base -gt $BASE_LO) { $script:base = $BASE_LO; $note = ($note + ' boost-off').Trim() }   # 看不到需量 → 保守退回 90%
    } elseif ($ratio -ge $BOOST_OFF -and $base -gt $BASE_LO) {
      $script:base = $BASE_LO; $script:lastBoost = $now; $note = ($note + ' boost-off').Trim()
    } elseif ($ratio -lt $BOOST_ON -and $base -lt $BASE_HI -and $base -ge $BASE_LO - 0.5 -and ($now - $lastBoost).TotalSeconds -ge $BOOST_UP_S -and $null -ne $hmX -and $hmX -ge $BOOST_HOT) {
      $script:base = $BASE_HI; $script:lastBoost = $now; $note = ($note + ' boost-on').Trim()
    }
  }

  # ---- 2) 出水溫度重設（主機出水設定值）----
  $band = Sp-Band $now
  $hi = $band[1]
  if ($fcu -and $null -ne $fcu.dew -and $fcu.oa_n -ge 3 -and $fcu.dew -gt $DEW_CAP_C) { $hi = [math]::Min($hi, $DEW_SP_MAX) }
  $tgt = $sp; $why = ''
  if ($now -lt $manualUntil) { $note = ($note + ' manual-hold').Trim() }
  elseif (-not $NoComfort -and (In-Window $now) -and $m.run -gt 0 -and $null -ne $sp -and $sp -gt 0) {
    $stepOk = (($now - $lastSpStep).TotalSeconds -ge $SP_STEP_S)
    if (-not $stepOk) { }
    elseif ($sp -gt $hi + 0.01) { $tgt = [math]::Max($hi, $sp - $SP_STEP); $why = $(if ($hi -lt $band[1]) { "室外露點 $(R1 $fcu.dew)°C 偏高，出水上限 $hi°C" } else { '出水設定超過季節上限' }) }
    elseif ($sp -lt $band[0] - 0.01) { $tgt = [math]::Min($band[0], $sp + $SP_STEP); $why = '出水設定低於季節下限' }
    elseif ($fcu -and $fcu.floors) {
      $hm = 0.0; $hmFloor = ''; $allOk = $true
      foreach ($k in $fcu.floors.Keys) {
        $f = $fcu.floors[$k]
        if ($f.n -lt 5) { continue }
        if ($f.hot -gt $hm) { $hm = $f.hot; $hmFloor = $k }
        if ($f.hot -ge $HOT_OK) { $allOk = $false }
      }
      $h4 = $(if ($fcu.floors.Contains('4F')) { $fcu.floors['4F'].hot } else { 0 })
      if ($gateCap) { $hm = [math]::Min($hm, $HOT_CAP); $h4 = [math]::Min($h4, $H4_CAP) } elseif ($gateWhy -match '參考房間熱') { $hm = [math]::Max($hm, $HOT_UP) }
      $demandTight = ($null -ne $ratio -and $ratio -ge 0.90) -or ($null -ne $cap)
      $pulldown = ($now.ToString('HH:mm') -lt $PULLDOWN_END)
      if ($eco) {
        if ($null -ne $hmX -and ($hmX -ge $ECO_SP_DN -or $h4f -ge $ECO_4F_SP_DN) -and -not $demandTight -and $sp -gt $band[0]) {
          $f2 = $(if ($hmX -ge $ECO_SP_DN) { "$hmXFloor 熱房間 $([math]::Round($hmX*100))%" } else { "4F 熱房間 $([math]::Round($h4f*100))%" })
          $tgt = $sp - $SP_STEP; $why = "$f2，出水調低（節電模式）"
        } elseif ($null -ne $hmX -and $hmX -lt $ECO_HOT_DN -and $h4f -lt $ECO_4F_OK -and -not $pulldown -and $sp -lt $hi) {
          $tgt = $sp + $SP_STEP; $why = '熱房間少，出水調高省電（節電模式）'
        }
      } elseif ($hm -ge $HOT_UP -and -not $demandTight -and $sp -gt $band[0]) {
        $tgt = $sp - $SP_STEP; $why = "$hmFloor 熱房間 $([math]::Round($hm*100))%，出水調低"
      } elseif ($allOk -and $null -ne $fcu.dt -and $fcu.dt -lt -0.5 -and $h4 -lt $HOT_4F_HOLD -and -not $pulldown -and $sp -lt $hi) {
        $tgt = $sp + $SP_STEP; $why = '房間普遍偏涼，出水調高省電'
      }
    }
    if ([math]::Abs($tgt - $sp) -ge 0.25) {
      $note = ($note + " sp $sp->$tgt").Trim()
      $action = Write-Sp $tgt $why
      $script:lastSpStep = $now
      $sp = $tgt
    }
  }

  # ---- 負載上限：只在需量降載／回升時改 ----
  $want = $(if ($null -ne $cap) { [math]::Min($base, $cap) } else { $base })
  $want = [math]::Max($MIN, [math]::Min($MAX, $want))
  if ([math]::Abs($want - $cur) -ge 0.5 -and ($note -match 'demand|boost|eco|after-hours')) {
    $why = $(if ($note -match 'demand-derate') { '需量降載' } elseif ($note -match 'boost-on') { '需量有餘裕且熱房間多，上限放到 100%' } elseif ($note -match 'boost-off') { '需量接近契約或讀不到，上限退回 90%' } elseif ($note -match 'after-hours-end') { '開機，回到時段上限（週末 30%）' } elseif ($note -match 'after-hours') { '18:00 後加班空調，上限固定 40%' } elseif ($note -match 'eco-up') { '節電：時段基準或熱房間，上限調高' } elseif ($note -match 'eco-down') { '節電：熱房間少或時段基準降低，上限調低' } else { '需量回升' })
    $a2 = Write-Limit $want $why
    $action = ($action + ' ' + $a2).Trim()
    $cur = $(if ($Live) { $want } else { $sim })
  }
  Save $now $d $m $cur $sp $action $note
}

if ($Once) { Step; Get-Content (Join-Path $Out 'mag_auto_status.json'); exit 0 }
Write-Host "mag_auto $mode comfort=$(-not $NoComfort) started $(Get-Date -f s)"
while ($true) {
  try { Step } catch { "$(Get-Date -f s) $($_.Exception.Message)" | Out-File (Join-Path $Out 'mag_auto.log') -Append -Encoding utf8 }
  Start-Sleep -Seconds 10
}
