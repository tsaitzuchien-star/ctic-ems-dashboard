# 中創園區 磁浮冰機 CHU-2 自動控制 (mag_auto.ps1) — 裝在空調監控主機
# 寫入的只有「負載限制百分比」(SG_CHU2_Item40035)，不開關機、不改其他設定。
# 兩層控制：
#  1) 契約需量（最優先，每 10 秒）：向監控電腦 http://10.10.2.20:8088/api/live 取 15 分鐘需量推估（台電基準），
#     推估 ≥ 契約 95% 就每分鐘降 10%；回到 88% 以下 5 分鐘後逐步回升。
#  2) 舒適度（07:30–19:00，冰機運轉中，每 10 分鐘最多調 5%）：
#     依冰水出水溫度與目標值的差，加上有開的小型送風機房間溫度（比設定熱 1°C 的比例）調整。
#     目標出水：夏月 11°C、非夏月 12°C；房間普遍偏涼放寬 +1°C，偏熱收緊 -1°C。
# 預設「試跑」：只記錄會怎麼調，不寫入。加 -Live 才寫入；加 -NoComfort 只做契約需量保護。
# 停用：在 C:\BMS_Export 放 mag_auto_off.txt（不再寫入，維持現值）。
# 人員手動改了負載限制 → 程式讓手：舒適度暫停 60 分鐘，以人員的值為準。
# 記錄：C:\BMS_Export\mag_auto_yyyy-MM-dd.csv；狀態：C:\BMS_Export\mag_auto_status.json（網站讀取）
param([switch]$Live, [switch]$Once, [switch]$NoComfort)
$ErrorActionPreference = 'Stop'
$Out  = 'C:\BMS_Export'
$Tag  = 'SG_CHU2_Item40035'
$Api  = 'http://10.10.2.20:8088/api/live'
$Off  = Join-Path $Out 'mag_auto_off.txt'
$FcuList = Join-Path $Out 'fcu_tags.txt'

# ---- 參數 ----
$MAX = 90; $MIN = 20                 # 負載限制範圍（Cliff 2026-11-06）
$TRIG = 0.95; $HARD = 1.00; $CLEAR = 0.88; $CLEAR_S = 300
$D_STEP = 10; $D_STEP_S = 60         # 需量降載：每步 10%、間隔 60 秒
$C_STEP = 5;  $C_STEP_S = 600        # 舒適度：每步 5%、間隔 10 分鐘
$C_START = '07:30'; $C_END = '19:00'
$TGT_SUMMER = 11.0; $TGT_OTHER = 12.0
$ERR_UP = 1.0        # 出水高於目標 1°C → 加載
$ERR_DOWN = 0.3      # 出水在目標 +0.3°C 以內 → 可減載
$HOT_UP = 0.30; $HOT_OK = 0.10       # 熱房間比例門檻
$STALE_S = 90; $LOST_RESTORE_S = 900
$MANUAL_HOLD_S = 3600

$mtx = New-Object System.Threading.Mutex($false, 'Global\CTIC_Mag_Auto')
if (-not $Once -and -not $mtx.WaitOne(0)) { exit 0 }

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
 public static string[] Read(string[] tags){
  uint id=0; if(DdeInitializeW(ref id,keep,0x10,0)!=0) return null;
  IntPtr s=DdeCreateStringHandleW(id,"VIEW",1200), tp=DdeCreateStringHandleW(id,"TAGNAME",1200);
  IntPtr c=DdeConnect(id,s,tp,IntPtr.Zero);
  if(c==IntPtr.Zero){DdeFreeStringHandle(id,s);DdeFreeStringHandle(id,tp);DdeUninitialize(id);return null;}
  var o=new string[tags.Length];
  for(int i=0;i<tags.Length;i++){
   IntPtr it=DdeCreateStringHandleW(id,tags[i],1200); uint res;
   IntPtr h=DdeClientTransaction(IntPtr.Zero,0,c,it,1,0x20B0,5000,out res);
   if(h==IntPtr.Zero) o[i]="";
   else{uint n=DdeGetData(h,null,0,0);var b=new byte[n];DdeGetData(h,b,n,0);DdeFreeDataHandle(h);o[i]=Encoding.Default.GetString(b).TrimEnd('\0','\r','\n',' ');}
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
  $v = [CticDdeW]::Read([string[]]@($Tag, 'SGB1DC51_CHU2_ST', 'SG_CHU2_Item30041', 'SG_CHU2_Item30043', 'SG_CHU2_Item40035_SCH_ONOFF', 'SG_CHU2_Item30001', 'SG_CHU2_Item30003'))
  if ($null -eq $v) { return $null }
  [pscustomobject]@{ limit = Num $v[0]; run = Num $v[1]; kw = ((Num $v[2]) + (Num $v[3])); enabled = Num $v[4]; chws = Num $v[5]; chwr = Num $v[6] }
}

# 小型送風機：有開的台數、比設定熱 1°C 以上的比例、平均 (室溫-設定)
$fcuTags = $null
function Read-Fcu {
  if ($null -eq $script:fcuTags) {
    if (-not (Test-Path $FcuList)) { return $null }
    $script:fcuTags = [string[]]@(Get-Content $FcuList | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '_FCU\d+_(Run|T|setT)$' })
  }
  $v = [CticDdeW]::Read($script:fcuTags)
  if ($null -eq $v) { return $null }
  $u = @{}
  for ($i = 0; $i -lt $fcuTags.Count; $i++) {
    if ($fcuTags[$i] -match '^(.*_FCU\d+)_(Run|T|setT)$') {
      if (-not $u.ContainsKey($matches[1])) { $u[$matches[1]] = @{} }
      $u[$matches[1]][$matches[2]] = Num $v[$i]
    }
  }
  $on = 0; $hot = 0; $n = 0; $sum = 0.0
  foreach ($k in $u.Keys) {
    $f = $u[$k]
    if ($f.Run -gt 0.5) {
      $on++
      if ($f.T -gt 5 -and $f.T -lt 40 -and $f.setT -ge 10 -and $f.setT -le 35) {
        $n++; $dlt = $f.T - $f.setT; $sum += $dlt
        if ($dlt -ge 1.0) { $hot++ }
      }
    }
  }
  [pscustomobject]@{ on = $on; n = $n; hot = $(if ($n) { $hot / $n } else { $null }); dt = $(if ($n) { $sum / $n } else { $null }) }
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
function In-Window($t) { $hm = $t.ToString('HH:mm'); return ($hm -ge $C_START -and $hm -lt $C_END) }

# ---- 狀態 ----
$lastApiTime = $null; $lastApiSeen = Get-Date
$mode = $(if ($Live) { 'LIVE' } else { 'DRY' })
$sim = $null                 # 試跑時假想的現值
$comfort = $null             # 舒適度想要的值
$cap = $null                 # 需量保護上限（null = 沒有在限制）
$lastWrite = $null
$lastDStep = [datetime]::MinValue; $lastCStep = [datetime]::MinValue
$clearSince = $null; $lostSince = $null; $manualUntil = [datetime]::MinValue
$fcu = $null; $fcuAt = [datetime]::MinValue
$lastAction = ''; $lastActionAt = ''
$tgtOffset = 0.0

function Write-Limit([double]$p, [string]$why) {
  $p = [math]::Max($MIN, [math]::Min($MAX, [math]::Round($p)))
  $script:lastAction = "$why -> $p%"; $script:lastActionAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  if ($Live) {
    $ok = [CticDdeW]::Poke($Tag, $p.ToString($inv))
    $script:lastWrite = $p
    return "$why->$p poke=$ok"
  }
  $script:sim = $p
  return "WOULD $why->$p"
}

function Save($now, $d, $m, $cur, $tgt, $action, $note) {
  $f = Join-Path $Out ('mag_auto_' + $now.ToString('yyyy-MM-dd') + '.csv')
  if (-not (Test-Path $f)) { 'time,mode,period,contract_kw,projected_kw,ratio,now_kw,data_age_s,chu2_run,mag_kw,chws_c,chwr_c,chws_target,fcu_on,hot_share,avg_dt,limit_read,limit_eff,comfort,cap,action,note' | Out-File $f -Encoding utf8 }
  $r = $(if ($d) { [math]::Round($d.proj / $d.limit, 3) } else { $null })
  $row = @($now.ToString('yyyy-MM-dd HH:mm:ss'), $mode, $(if($d){$d.period}), $(if($d){$d.limit}), $(if($d){$d.proj}), $r,
           $(if($d){$d.now}), $(if($d){[int]$d.age}), $(if($m){$m.run}), $(if($m){R1 $m.kw}), $(if($m){R1 $m.chws}), $(if($m){R1 $m.chwr}), $tgt,
           $(if($fcu){$fcu.on}), $(if($fcu -and $null -ne $fcu.hot){[math]::Round($fcu.hot,2)}), $(if($fcu){R1 $fcu.dt}),
           $(if($m){$m.limit}), $cur, $comfort, $cap, $action, $note) -join ','
  $row | Out-File $f -Append -Encoding utf8
  $st = [ordered]@{
    time = $now.ToString('yyyy-MM-dd HH:mm:ss'); mode = $mode; comfort_on = (-not $NoComfort); off = (Test-Path $Off)
    enabled = $(if ($m) { $m.enabled -ge 0.5 }); running = $(if ($m) { $m.run -gt 0 })
    limit_read = $(if ($m) { $m.limit }); limit = $cur; comfort = $comfort; cap = $cap
    chws_c = $(if ($m) { R1 $m.chws }); chws_target = $tgt; fcu_on = $(if ($fcu) { $fcu.on })
    hot_share = $(if ($fcu -and $null -ne $fcu.hot) { [math]::Round($fcu.hot, 2) }); ratio = $r
    manual_hold = ($now -lt $manualUntil); note = $note; last_action = $lastAction; last_action_at = $lastActionAt
  }
  ($st | ConvertTo-Json -Compress) | Out-File (Join-Path $Out 'mag_auto_status.json') -Encoding utf8
  if ($action) { Write-Host $row }
}

function Step {
  $now = Get-Date
  $m = Read-Mag
  $d = Read-Demand
  if (-not $m -or $null -eq $m.limit) { Save $now $d $m '' '' '' 'no-intouch'; return }
  if (($now - $fcuAt).TotalSeconds -ge 300) { try { $script:fcu = Read-Fcu } catch { $script:fcu = $null }; $script:fcuAt = $now }
  $cur = $(if (-not $Live -and $null -ne $sim) { $sim } else { $m.limit })
  $action = ''; $note = ''

  # 人員手動改了 → 讓手
  if ($Live -and $null -ne $lastWrite -and [math]::Abs($m.limit - $lastWrite) -gt 0.5) {
    $script:comfort = $m.limit; $script:cap = $null; $script:lastWrite = $null
    $script:manualUntil = $now.AddSeconds($MANUAL_HOLD_S)
    $script:lastAction = "人員手動改成 $($m.limit)%，程式暫停舒適度 60 分鐘"; $script:lastActionAt = $now.ToString('yyyy-MM-dd HH:mm:ss')
    Save $now $d $m $m.limit '' 'manual-override' ''; return
  }
  if ($m.enabled -lt 0.5) { Save $now $d $m $cur '' '' 'limit-not-enabled'; return }
  if (Test-Path $Off) { $script:sim = $null; $script:cap = $null; $script:comfort = $null; Save $now $d $m $m.limit '' '' 'off-switch'; return }
  if ($null -eq $comfort) { $script:comfort = $cur }

  # ---- 1) 契約需量 ----
  $ratio = $null
  if (-not $d -or $d.age -gt $STALE_S) {
    if ($null -eq $lostSince) { $script:lostSince = $now }
    $note = 'no-demand-data'
    if ($null -ne $cap -and ($now - $lostSince).TotalSeconds -ge $LOST_RESTORE_S) { $script:cap = $null; $note = 'no-demand-data-release-cap' }
  } else {
    $script:lostSince = $null
    $ratio = $d.proj / $d.limit
    $high = ($ratio -ge $HARD -or ($ratio -ge $TRIG -and $d.elapsed -ge 60))
    if ($high -and $m.run -gt 0) {
      $script:clearSince = $null
      if (($now - $lastDStep).TotalSeconds -ge $D_STEP_S -and $cur -gt $MIN) {
        $script:cap = [math]::Max($MIN, $cur - $D_STEP); $script:lastDStep = $now; $note = 'demand-derate'
      }
    } elseif ($null -ne $cap) {
      if ($ratio -lt $CLEAR) {
        if ($null -eq $clearSince) { $script:clearSince = $now }
        if (($now - $clearSince).TotalSeconds -ge $CLEAR_S -and ($now - $lastDStep).TotalSeconds -ge $D_STEP_S) {
          $script:cap = $cap + $D_STEP; $script:lastDStep = $now; $note = 'demand-release'
          if ($cap -ge $comfort) { $script:cap = $null; $script:clearSince = $null }
        }
      } else { $script:clearSince = $null }
    }
  }

  # ---- 2) 舒適度 ----
  $tgt = $(if (Is-Summer $now) { $TGT_SUMMER } else { $TGT_OTHER })
  if ($fcu -and $null -ne $fcu.hot) {
    if ($fcu.hot -ge $HOT_UP) { $tgt -= 1 } elseif ($fcu.hot -lt $HOT_OK -and $fcu.dt -lt -0.5) { $tgt += 1 }
  }
  if ($NoComfort) { $script:comfort = $m.limit }
  elseif (-not (In-Window $now) -or $m.run -le 0) { $script:comfort = $cur }
  elseif ($now -lt $manualUntil) { $note = ($note + ' manual-hold').Trim() }
  elseif (($now - $lastCStep).TotalSeconds -ge $C_STEP_S -and $null -ne $m.chws -and $m.chws -gt 0) {
    $err = $m.chws - $tgt
    $hot = $(if ($fcu -and $null -ne $fcu.hot) { $fcu.hot } else { 0 })
    $demandTight = ($null -ne $ratio -and $ratio -ge 0.90) -or ($null -ne $cap)
    if (($err -gt $ERR_UP -or ($hot -ge $HOT_UP -and $err -gt $ERR_DOWN)) -and -not $demandTight -and $comfort -lt $MAX) {
      $script:comfort = [math]::Min($MAX, $comfort + $C_STEP); $script:lastCStep = $now; $note = ($note + " comfort-up(chws $([math]::Round($m.chws,1)) vs $tgt, hot $([math]::Round($hot,2)))").Trim()
    } elseif ($err -lt $ERR_DOWN -and $hot -lt $HOT_OK -and $comfort -gt $MIN) {
      $script:comfort = [math]::Max($MIN, $comfort - $C_STEP); $script:lastCStep = $now; $note = ($note + " comfort-down(chws $([math]::Round($m.chws,1)) vs $tgt, hot $([math]::Round($hot,2)))").Trim()
    }
  }

  # ---- 合成：取兩者較低者 ----
  $want = $comfort
  if ($null -ne $cap) { $want = [math]::Min($want, $cap) }
  $want = [math]::Max($MIN, [math]::Min($MAX, $want))
  if ($m.limit -gt $MAX -and $null -eq $cap -and -not (In-Window $now)) { $want = $cur }   # 窗外不主動改人員設定
  if ([math]::Abs($want - $cur) -ge 0.5 -and ($note -match 'demand|comfort')) {
    $why = $(if ($note -match 'demand-derate') { '需量降載' } elseif ($note -match 'demand-release') { '需量回升' } elseif ($note -match 'comfort-up') { '出水偏高加載' } else { '冷量足夠減載' })
    $action = Write-Limit $want $why
    $cur = $(if ($Live) { $want } else { $sim })
  }
  Save $now $d $m $cur $tgt $action $note
}

if ($Once) { Step; Get-Content (Join-Path $Out 'mag_auto_status.json'); exit 0 }
Write-Host "mag_auto $mode comfort=$(-not $NoComfort) started $(Get-Date -f s)"
while ($true) {
  try { Step } catch { "$(Get-Date -f s) $($_.Exception.Message)" | Out-File (Join-Path $Out 'mag_auto.log') -Append -Encoding utf8 }
  Start-Sleep -Seconds 10
}
