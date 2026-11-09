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
# 送風機（2026-11-07 起）：kind = fcu，只限下面 $FCU_ALLOW 列的房間（B239；2026-11-09 起加 C303，Cliff 授權）。
#   units 可寫 "all"（該房間全部台數）；C303 跨兩個面板，台號寫 P23_FCU01 這種格式。
#   {"kind":"fcu","room":"B239","units":["FCU01","FCU02"],"action":"off"|"on"|"setT","value":26}
#   action off/on 寫 _Run（0/1），所有台一起送出，最多等 180 秒看風速狀態確認；setT 只允許 24–28 °C，立即讀回。
#   平日 18:00–07:00 遠端開啟時，若當晚加班名單檔已存在，把房號加進去，避免 fcu_guard 又把它關掉。
# 照明（2026-11-07 起，Cliff 授權）：kind = light，只限 B330（InTouch 只有這間有燈控）。
#   {"kind":"light","room":"B330","circuits":"all" 或 ["EL3C_13","EL3C1_11",...],"action":"on"|"off"}
#   寫各迴路 Light_B330_<迴路>_LIGHT_DO（1 亮 / 0 滅），3 秒後讀回 DO 和 DI。A/B 區總開關只讀不寫。
# 磁浮負載上限（2026-11-08 起，Cliff 授權）：kind = maglimit，不直接寫 InTouch，而是寫 C:\BMS_Export\mag_limit_override.json，
#   由 mag_auto 在那一天、那個時段把負載上限的「底」設成 pct（需量接近契約時仍會先降載）。
#   {"kind":"maglimit","date":"2026-11-09","from":"07:40","to":"09:30","pct":100}   設定（同一天再送一次會蓋掉）
#   {"kind":"maglimit","date":"2026-11-09","action":"clear"}                         取消那一天
#   只限今天起 7 天內的平日（星期一到五）、07:00–22:00、pct 20–100。
# 活動登記（2026-11-08 起，Cliff 授權）：kind = event，在 C:\BMS_Export\ac_events.txt 加一行（mag_auto、fcu_guard 會照它預冷、提高上限、不關送風機）。
#   {"kind":"event","date":"2026-11-12","from":"13:00","to":"17:00","zones":["會議廳","展演"]}                  登記
#   {"kind":"event","date":"2026-11-12","from":"13:00","to":"17:00","zones":["會議廳"],"action":"remove"}       取消那一行
#   場地只能是 會議廳 / 展演 / 訓練 / 全部；日期今天起 14 天內；時間 06:00–23:00。只登記，不會啟動冰機：
#   寫完會讀那天的磁浮排程，沒涵蓋活動時段就在結果加 ⚠️ 提醒。
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
$MagOvFile = Join-Path $Out 'mag_limit_override.json'
$EventFile = Join-Path $Out 'ac_events.txt'
$EVENT_ZONES = @('會議廳', '展演', '訓練', '全部')
function Event-Line($c) { return "$($c.date) $($c.from)-$($c.to) $(@($c.zones | ForEach-Object { "$_" }) -join ' ')" }
function Event-Lines { if (Test-Path $EventFile) { return @(Get-Content $EventFile -Encoding UTF8 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) } else { return @() } }
$PREFIX = @{ ice = 'BCU_SCHI'; melt = 'BCU_SCHW'; chu2 = 'CHU2_SCH' }
$NAME = @{ ice = '製冰'; melt = '融冰'; chu2 = '磁浮' }
$WD = '一二三四五六日'
$ICE_OK_FROM = '22:00'; $ICE_OK_TO = '07:30'
$FCU_ALLOW = @{ 'B239' = 'SG_2F31_P25'; 'C303' = 'SG_3F31' }     # 房號 → InTouch 點位前綴（Cliff 授權的房間才放進來）
$FCU_UNITS = @{                                                     # 房號 → 可以動的台號（前綴 + '_' + 台號 = 點位）
  'B239' = @('FCU01', 'FCU02')
  'C303' = @('P23_FCU01','P23_FCU02','P23_FCU03','P23_FCU04','P23_FCU05','P23_FCU06','P23_FCU07','P23_FCU08',
             'P24_FCU01','P24_FCU02','P24_FCU03','P24_FCU04','P24_FCU05','P24_FCU06')   # 環電（2026-11-09 Cliff 要求設 25°C）
}
function Fcu-Units($c) {
  $all = @($FCU_UNITS["$($c.room)"])
  if ("$($c.units)" -eq 'all') { return $all }
  $us = @($c.units | ForEach-Object { "$_" })
  if ($us.Count -lt 1) { return $null }
  foreach ($u in $us) { if ($all -notcontains $u) { return $null } }
  return $us
}
$FCU_SET_MIN = 24; $FCU_SET_MAX = 28
$LIGHT_ROOM = 'B330'
$LIGHT_CIRCUITS = @('EL3C_13','EL3C_14','EL3C_15','EL3C_16','EL3C_17','EL3C_18','EL3C_19',
                    'EL3C1_11','EL3C1_12','EL3C1_13','EL3C1_14','EL3C1_15','EL3C1_16','EL3C1_17','EL3C1_18','EL3C1_19','EL3C1_20','EL3C1_21')

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

function Light-Circuits($c) {
  if ("$($c.circuits)" -eq 'all') { return $LIGHT_CIRCUITS }
  $cs = @($c.circuits | ForEach-Object { "$_" })
  if ($cs.Count -lt 1) { return $null }
  foreach ($x in $cs) { if ($LIGHT_CIRCUITS -notcontains $x) { return $null } }
  return $cs
}
function Light-Read($cs) {
  # 回傳 @{ dov = @{迴路=值}; div = @{...}; a = A區總開關; b = B區總開關 }
  $tags = @('Light_B330_A_ALL_ONOFF', 'Light_B330_B_ALL_ONOFF')
  foreach ($x in $cs) { $tags += "Light_B330_$($x)_LIGHT_DO"; $tags += "Light_B330_$($x)_LIGHT_DI" }
  $v = [CticDdeW]::Read([string[]]$tags, 3000, 30000)
  if ($null -eq $v) { return $null }
  $nv = @($v | ForEach-Object { $x = 0.0; if ([double]::TryParse("$_", [Globalization.NumberStyles]::Float, $inv, [ref]$x)) { "$([int]$x)" } else { '?' } })
  $r = @{ a = $nv[0]; b = $nv[1]; dov = [ordered]@{}; div = [ordered]@{} }
  for ($i = 0; $i -lt $cs.Count; $i++) { $r.dov[$cs[$i]] = $nv[2 + 2 * $i]; $r.div[$cs[$i]] = $nv[3 + 2 * $i] }
  return $r
}
function Light-Text($r, $cs) {
  if ($null -eq $r) { return '讀不到' }
  $on = @($cs | Where-Object { $r.dov[$_] -eq '1' }); $unk = @($cs | Where-Object { $r.dov[$_] -ne '1' -and $r.dov[$_] -ne '0' })
  $t = "亮 $($on.Count)／$($cs.Count) 迴路"
  if ($on.Count -gt 0 -and $on.Count -lt $cs.Count) { $t += "（亮：$($on -join ', ')）" }
  if ($unk.Count) { $t += "（讀不到：$($unk -join ', ')）" }
  $di = @($cs | Where-Object { $r.div[$_] -ne $r.dov[$_] })
  if ($di.Count) { $t += "（回授和指令不同：$($di -join ', ')）" }
  return "$t；A區總開關 $($r.a)、B區總開關 $($r.b)"
}

function MagOv-Load {
  $o = [ordered]@{}
  if (Test-Path $MagOvFile) {
    try { $j = Get-Content $MagOvFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $o[$p.Name] = $p.Value } } catch { }
  }
  return $o
}
function MagOv-Text($e) { if ($null -eq $e) { return '沒有特別設定' } else { return "$($e.from)–$($e.to) 上限 $($e.pct)%" } }
function Check-Change($c, $now) {
  # 回傳 $null = 通過；否則回傳擋下的原因
  if ("$($c.kind)" -eq 'event') {
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact("$($c.date)", 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$dt)) { return "日期 $($c.date) 格式不對（yyyy-MM-dd）" }
    if ($dt -lt $now.Date -or $dt -gt $now.Date.AddDays(14)) { return "日期 $($c.date) 要在今天起 14 天內" }
    if (-not (Hm-Ok $c.from) -or -not (Hm-Ok $c.to)) { return "時間格式不對（$($c.from)–$($c.to)，要 HH:MM）" }
    if ("$($c.from)" -ge "$($c.to)") { return "開始要早於結束（$($c.from)–$($c.to)）" }
    if ("$($c.from)" -lt '06:00' -or "$($c.to)" -gt '23:00') { return "要在 06:00–23:00 之內（$($c.from)–$($c.to)）" }
    $zs = @($c.zones | ForEach-Object { "$_" })
    if ($zs.Count -lt 1) { return "沒有寫場地（會議廳 / 展演 / 訓練 / 全部）" }
    foreach ($z in $zs) { if ($EVENT_ZONES -notcontains $z) { return "場地 $z 不對（只能 會議廳 / 展演 / 訓練 / 全部）" } }
    if (@('', 'add', 'remove') -notcontains "$($c.action)") { return "動作 $($c.action) 不對（登記不用寫，取消寫 remove）" }
    return $null
  }
  if ("$($c.kind)" -eq 'maglimit') {
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact("$($c.date)", 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$dt)) { return "日期 $($c.date) 格式不對（yyyy-MM-dd）" }
    if ($dt -lt $now.Date -or $dt -gt $now.Date.AddDays(7)) { return "日期 $($c.date) 要在今天起 7 天內" }
    if ("$($c.action)" -eq 'clear') { return $null }
    if ($dt.DayOfWeek -eq 'Saturday' -or $dt.DayOfWeek -eq 'Sunday') { return "$($c.date) 是週末，自動控制週末不套用時段上限" }
    if (-not (Hm-Ok $c.from) -or -not (Hm-Ok $c.to)) { return "時間格式不對（$($c.from)–$($c.to)，要 HH:MM）" }
    if ("$($c.from)" -ge "$($c.to)") { return "開始要早於結束（$($c.from)–$($c.to)）" }
    if ("$($c.from)" -lt '07:00' -or "$($c.to)" -gt '22:00') { return "要在 07:00–22:00 之內（$($c.from)–$($c.to)）" }
    $v = 0; if (-not [int]::TryParse("$($c.pct)", [ref]$v) -or $v -lt 20 -or $v -gt 100) { return "負載上限 $($c.pct)% 要在 20–100 之間" }
    return $null
  }
  if ("$($c.kind)" -eq 'fcu') {
    if (-not $FCU_ALLOW.ContainsKey("$($c.room)")) { return "送風機房間 $($c.room) 不在授權清單（目前只有 $($FCU_ALLOW.Keys -join ', ')）" }
    $us = Fcu-Units $c
    if ($null -eq $us) { return "送風機台號不對（$($c.room) 只能是 all 或 $(@($FCU_UNITS["$($c.room)"]) -join ', ')）" }
    if (@('off','on','setT') -notcontains "$($c.action)") { return "送風機動作 $($c.action) 不對（off / on / setT）" }
    if ("$($c.action)" -eq 'setT') {
      $v = 0.0
      if (-not [double]::TryParse("$($c.value)", [Globalization.NumberStyles]::Float, $inv, [ref]$v) -or $v -lt $FCU_SET_MIN -or $v -gt $FCU_SET_MAX) {
        return "設定溫度 $($c.value) 超出 $FCU_SET_MIN–$FCU_SET_MAX °C" }
    }
    return $null
  }
  if ("$($c.kind)" -eq 'light') {
    if ("$($c.room)" -ne $LIGHT_ROOM) { return "照明房間 $($c.room) 不在授權清單（只有 $LIGHT_ROOM）" }
    if (@('off','on') -notcontains "$($c.action)") { return "照明動作 $($c.action) 不對（off / on）" }
    $cs = Light-Circuits $c
    if ($null -eq $cs) { return "照明迴路不對（要 all 或 $($LIGHT_CIRCUITS -join ',') 其中幾個）" }
    return $null
  }
  if (-not $PREFIX.ContainsKey("$($c.kind)")) { return "種類 $($c.kind) 不在白名單（只能 ice / melt / chu2 / fcu / light / maglimit / event）" }
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
$mtx = New-Object System.Threading.Mutex($false, 'Global\CTIC_Sched_Cmd')   # 上一輪還在等送風機狀態時，不要重複執行同一筆
if (-not $mtx.WaitOne(0)) { exit 0 }
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
foreach ($c in $changes) { $e = Check-Change $c $now; if ($e) { $why += $(if (@('fcu','light') -contains "$($c.kind)") { "$($c.room) $e" } elseif ("$($c.kind)" -eq 'maglimit') { "磁浮負載上限 $e" } elseif ("$($c.kind)" -eq 'event') { "活動登記 $e" } else { "$(Day-Label $c.day) $e" }) } }
if ($why.Count) { $res.status = 'rejected'; $res.lines = @('整筆指令沒有執行：') + $why; Save-Result $res; exit 0 }

# ---- 寫入（WindowViewer 要開著） ----
$probe = [CticDdeW]::Read([string[]]@('SGB1DC51_BCU_ST'), 3000, 5000)
if ($null -eq $probe) { $res.status = 'failed'; $res.lines = @('讀不到 InTouch（WindowViewer 有開嗎？），沒有寫入，下次再試'); 
  ($res | ConvertTo-Json -Depth 6) | Out-File $ResultFile -Encoding utf8; Log "$($res.id) viewer down, will retry"; exit 0 }
$allOk = $true
foreach ($c in $changes) {
  if ("$($c.kind)" -eq 'event') {
    $line = Event-Line $c; $isRm = ("$($c.action)" -eq 'remove')
    $label = "活動登記 $line"
    $lines = @(Event-Lines); $has = ($lines -contains $line)
    if ($DryRun) { $res.lines += "${label}：$(if ($isRm) { '取消' } else { '登記' })（目前$(if ($has) { '已有' } else { '沒有' })這一行，試跑，沒寫）"; continue }
    if ($isRm) { $new = @($lines | Where-Object { $_ -ne $line }) } elseif ($has) { $new = $lines } else { $new = @($lines) + $line }
    $tmp = "$EventFile.tmp"
    $new | Out-File $tmp -Encoding utf8
    Move-Item $tmp $EventFile -Force
    $after = @(Event-Lines)
    $ok = $(if ($isRm) { $after -notcontains $line } else { $after -contains $line })
    if (-not $ok) { $allOk = $false; $res.lines += "${label}：寫入後讀回不符 ❌"; continue }
    if ($isRm) { $res.lines += "${label}：已取消 ✅"; continue }
    $res.lines += "${label}：$(if ($has) { '本來就登記了' } else { '已登記' }) ✅（開始前 30 分鐘預冷，上限至少 70%，送風機不會被關）"
    # 看那天的磁浮排程有沒有涵蓋活動時段（只讀）
    $dd = [int]([datetime]::ParseExact("$($c.date)", 'yyyy-MM-dd', $inv)).DayOfWeek; if ($dd -eq 0) { $dd = 7 }
    $sv = [CticDdeW]::Read((Tags ([pscustomobject]@{ kind = 'chu2'; day = $dd })), 3000, 20000)
    if ($null -ne $sv -and $sv.Count -ge 5) {
      $n = @($sv | ForEach-Object { $x = 0.0; if ([double]::TryParse("$_", [Globalization.NumberStyles]::Float, $inv, [ref]$x)) { [int]$x } else { -1 } })
      $on = '{0:00}:{1:00}' -f $n[0], $n[1]; $off = '{0:00}:{1:00}' -f $n[2], $n[3]
      if ($n[4] -ne 1 -or $on -gt "$($c.from)" -or $off -lt "$($c.to)") {
        $res.lines += "⚠️ $(Day-Label $dd)磁浮排程是 $(Fmt $sv)，沒有涵蓋活動 $($c.from)–$($c.to)，冰機不會自己開，要另外改排程"
      } else { $res.lines += "$(Day-Label $dd)磁浮排程 $(Fmt $sv) 有涵蓋活動時段" }
    }
    continue
  }
  if ("$($c.kind)" -eq 'maglimit') {
    $label = "磁浮負載上限 $($c.date)"
    $ov = MagOv-Load; $before = $ov["$($c.date)"]
    $isClear = ("$($c.action)" -eq 'clear')
    $what = $(if ($isClear) { '取消特別設定' } else { "$($c.from)–$($c.to) 上限 $([int]"$($c.pct)")%" })
    if ($DryRun) { $res.lines += "${label}：目前 $(MagOv-Text $before) → $what（試跑，沒寫）"; continue }
    foreach ($k in @($ov.Keys)) { if ("$k" -lt $now.ToString('yyyy-MM-dd')) { $ov.Remove($k) } }   # 過期的順便清掉
    if ($isClear) { $ov.Remove("$($c.date)") } else { $ov["$($c.date)"] = [ordered]@{ from = "$($c.from)"; to = "$($c.to)"; pct = [int]"$($c.pct)"; id = "$($cmd.id)" } }
    $tmp = "$MagOvFile.tmp"
    ($ov | ConvertTo-Json -Depth 4) | Out-File $tmp -Encoding utf8
    Move-Item $tmp $MagOvFile -Force
    $after = (MagOv-Load)["$($c.date)"]
    $ok = $(if ($isClear) { $null -eq $after } else { $null -ne $after -and "$($after.from)" -eq "$($c.from)" -and "$($after.to)" -eq "$($c.to)" -and [int]$after.pct -eq [int]"$($c.pct)" })
    if ($ok) { $res.lines += "${label}：$(MagOv-Text $before) → $what ✅（自動控制下一輪就會讀到）" }
    else { $allOk = $false; $res.lines += "${label}：寫入後讀回 $(MagOv-Text $after) 和指令不符 ❌" }
    continue
  }
  if ("$($c.kind)" -eq 'fcu') {
    $panel = $FCU_ALLOW["$($c.room)"]; $act = "$($c.action)"
    $what = $(if ($act -eq 'off') { '關閉' } elseif ($act -eq 'on') { '開啟' } else { "設定 $($c.value)°C" })
    # 先讀全部台數的現況；setT 逐台寫並讀回；on/off 一次對所有台送出，再一起等風速狀態（現場實測：狀態回報比實際慢 60–100 秒以上）
    $pend = @()
    foreach ($u in @(Fcu-Units $c)) {
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
        $pend += [pscustomobject]@{ u = $u; label = $label; before = $before; after = $null; ok = $false; t0 = Get-Date }
      }
    }
    if ($pend.Count) {
      $want = $(if ($act -eq 'off') { 0 } else { 1 })
      for ($k = 0; $k -lt 36; $k++) {                      # 最多等 180 秒
        Start-Sleep -Seconds 5
        foreach ($p in @($pend | Where-Object { -not $_.ok })) {
          $p.after = Fcu-Read $panel $p.u
          if ($null -ne $p.after -and $p.after.fan -eq $want) { $p.ok = $true; $p | Add-Member -NotePropertyName sec -NotePropertyValue ([int]((Get-Date) - $p.t0).TotalSeconds) -Force }
        }
        if (-not @($pend | Where-Object { -not $_.ok }).Count) { break }
      }
      foreach ($p in $pend) {
        if ($p.ok) { $res.lines += "$($p.label)：$(Fcu-Text $p.before) → $what ✅（狀態 $($p.sec) 秒回報）" }
        elseif ($null -ne $p.after -and [int]$p.after.run -eq $want) { $res.lines += "$($p.label)：已送出$what（運轉指令已是 $want），風速狀態 3 分鐘內還沒更新，請稍後再看 ⚠️" }
        else { $allOk = $false; $res.lines += "$($p.label)：送出$what後讀回不符（$(Fcu-Text $p.after)）❌" }
      }
    }
    if (-not $DryRun -and $act -eq 'on') { $x = Fcu-AllowAfterHours "$($c.room)"; if ($x) { $res.lines += $x } }
    continue
  }
  if ("$($c.kind)" -eq 'light') {
    $cs = @(Light-Circuits $c); $act = "$($c.action)"; $want = $(if ($act -eq 'on') { '1' } else { '0' })
    $what = $(if ($act -eq 'on') { '開燈' } else { '關燈' }); $label = "B330 照明"
    $before = Light-Read $cs
    if ($null -eq $before) { $allOk = $false; $res.lines += "$label：讀不到照明點位，沒有寫入 ❌"; continue }
    if ($DryRun) { $res.lines += "$label：目前 $(Light-Text $before $cs) → $what（試跑，沒寫）"; continue }
    foreach ($x in $cs) { $null = [CticDdeW]::Poke("Light_B330_$($x)_LIGHT_DO", $want) }
    Start-Sleep -Seconds 3
    $after = Light-Read $cs
    $bad = @(); if ($null -ne $after) { $bad = @($cs | Where-Object { $after.dov[$_] -ne $want }) }
    if ($null -ne $after -and $bad.Count -eq 0) { $res.lines += "$label：$what ✅ 現在 $(Light-Text $after $cs)" }
    else { $allOk = $false; $res.lines += "$label：送出$what後讀回不符（$(Light-Text $after $cs)）❌" }
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
