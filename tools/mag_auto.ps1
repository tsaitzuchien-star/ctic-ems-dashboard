# 中創園區 磁浮冰機 CHU-2 自動降載 (mag_auto.ps1) — 裝在空調監控主機
# 每 10 秒向監控電腦 http://10.10.2.20:8088/api/live 取 15 分鐘需量推估（台電基準），
# 快超約時把「負載限制百分比」(SG_CHU2_Item40035) 一步步往下調，需量回落後再調回人員原本的設定值。
# 預設是「試跑」：只記錄會怎麼調，不寫入。加 -Live 才真的寫入。
# 停用：在 C:\BMS_Export 放一個 mag_auto_off.txt（程式就不再寫入，維持現值）。
# 記錄：C:\BMS_Export\mag_auto_yyyy-MM-dd.csv；狀態：C:\BMS_Export\mag_auto_status.json
param([switch]$Live, [switch]$Once)
$ErrorActionPreference = 'Stop'
$Out  = 'C:\BMS_Export'
$Tag  = 'SG_CHU2_Item40035'
$Api  = 'http://10.10.2.20:8088/api/live'
$Off  = Join-Path $Out 'mag_auto_off.txt'

# ---- 參數 ----
$TRIG   = 0.95   # 推估 / 契約 ≥ 95% 開始降載
$HARD   = 1.00   # ≥ 100% 時，不等時段過 1 分鐘就降
$CLEAR  = 0.88   # < 88% 且維持 CLEAR_S 秒才回升
$CLEAR_S = 300
$STEP   = 10     # 每步 10%
$STEP_S = 60     # 兩步之間至少 60 秒
$FLOOR  = 30     # 最低 30%
$STALE_S = 90    # 需量資料超過 90 秒沒更新視為失聯
$LOST_RESTORE_S = 900   # 失聯 15 分鐘後回到原設定，避免一直卡在低負載

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

function Read-Mag {
  $v = [CticDdeW]::Read([string[]]@($Tag, 'SGB1DC51_CHU2_ST', 'SG_CHU2_Item30041', 'SG_CHU2_Item30043'))
  if ($null -eq $v) { return $null }
  [pscustomobject]@{ limit = Num $v[0]; run = Num $v[1]; kw = ((Num $v[2]) + (Num $v[3])) }
}
function Read-Demand {
  try { $d = Invoke-RestMethod -Uri $Api -TimeoutSec 5 } catch { return $null }
  if (-not $d.ok) { return $null }
  $t = [datetime]::ParseExact("$((Get-Date).ToString('yyyy-MM-dd')) $($d.time)", 'yyyy-MM-dd HH:mm:ss', $inv)
  $age = ((Get-Date) - $t).TotalSeconds
  if ($age -lt -43200) { $age += 86400 }
  [pscustomobject]@{ age = $age; proj = [double]$d.demand.projected; limit = [double]$d.demand.limit
                     now = [double]$d.demand.now_kw; elapsed = [int]$d.demand.elapsed_s; period = $d.demand.period }
}

# ---- 狀態 ----
$base = $null          # 人員設定值（降載前的值）
$sim  = $null          # 試跑時的「假想」現值
$lastWrite = $null; $lastStep = [datetime]::MinValue
$clearSince = $null; $lostSince = $null
$mode = $(if ($Live) { 'LIVE' } else { 'DRY' })

function Log-Row($d, $m, $cur, $action) {
  $now = Get-Date
  $f = Join-Path $Out ('mag_auto_' + $now.ToString('yyyy-MM-dd') + '.csv')
  if (-not (Test-Path $f)) { 'time,mode,period,contract_kw,projected_kw,ratio,now_kw,data_age_s,chu2_run,mag_kw,limit_read,limit_eff,base,action' | Out-File $f -Encoding utf8 }
  $r = $(if ($d) { [math]::Round($d.proj / $d.limit, 3) } else { '' })
  $row = @($now.ToString('yyyy-MM-dd HH:mm:ss'), $mode, $(if($d){$d.period}), $(if($d){$d.limit}), $(if($d){$d.proj}), $r,
           $(if($d){$d.now}), $(if($d){[int]$d.age}), $(if($m){$m.run}), $(if($m){[math]::Round($m.kw,1)}), $(if($m){$m.limit}), $cur, $base, $action) -join ','
  $row | Out-File $f -Append -Encoding utf8
  $st = [ordered]@{ time = $now.ToString('yyyy-MM-dd HH:mm:ss'); mode = $mode; off = (Test-Path $Off); controlling = ($null -ne $base)
                    base = $base; limit = $cur; ratio = $r; action = $action }
  ($st | ConvertTo-Json -Compress) | Out-File (Join-Path $Out 'mag_auto_status.json') -Encoding utf8
  if ($action) { Write-Host $row }
}

function Set-Limit([double]$p, [string]$why) {
  $p = [math]::Max($FLOOR, [math]::Min(100, $p))
  if ($Live -and -not (Test-Path $Off)) {
    $ok = [CticDdeW]::Poke($Tag, $p.ToString($inv))
    $script:lastWrite = $p
    return "$why->$p poke=$ok"
  }
  $script:sim = $p
  return "WOULD $why->$p"
}

function Step {
  $m = Read-Mag
  $d = Read-Demand
  if (-not $m -or $null -eq $m.limit) { Log-Row $d $m '' 'no-intouch'; return }
  $cur = $(if (-not $Live -and $null -ne $sim) { $sim } else { $m.limit })
  $now = Get-Date; $action = ''

  # 有人手動改過 → 讓手
  if ($Live -and $null -ne $base -and $null -ne $lastWrite -and [math]::Abs($m.limit - $lastWrite) -gt 0.5) {
    $script:base = $null; $script:lastWrite = $null
    Log-Row $d $m $m.limit "manual-override($($m.limit))"; return
  }
  if (Test-Path $Off) { Log-Row $d $m $cur 'off-switch'; $script:base = $null; $script:sim = $null; return }

  if (-not $d -or $d.age -gt $STALE_S) {
    if ($null -eq $script:lostSince) { $script:lostSince = $now }
    if ($null -ne $base -and ($now - $lostSince).TotalSeconds -ge $LOST_RESTORE_S) {
      $action = Set-Limit $base 'restore-nodata'; $script:base = $null; $script:sim = $null
    }
    Log-Row $d $m $cur $(if ($action) { $action } else { 'no-demand-data' }); return
  }
  $script:lostSince = $null
  $ratio = $d.proj / $d.limit
  $canStep = ($now - $lastStep).TotalSeconds -ge $STEP_S

  if (($ratio -ge $HARD -or ($ratio -ge $TRIG -and $d.elapsed -ge 60)) -and $m.run -gt 0) {
    $script:clearSince = $null
    if ($canStep -and $cur -gt $FLOOR) {
      if ($null -eq $base) { $script:base = $cur }
      $action = Set-Limit ($cur - $STEP) 'derate'; $script:lastStep = $now
    } elseif ($cur -le $FLOOR) { $action = 'at-floor' }
  } elseif ($null -ne $base) {
    if ($ratio -lt $CLEAR) {
      if ($null -eq $clearSince) { $script:clearSince = $now }
      if (($now - $clearSince).TotalSeconds -ge $CLEAR_S -and $canStep) {
        $tgt = [math]::Min($base, $cur + $STEP)
        $action = Set-Limit $tgt 'restore'; $script:lastStep = $now
        if ($tgt -ge $base) { $script:base = $null; $script:sim = $null; $script:clearSince = $null }
      }
    } else { $script:clearSince = $null }
  }
  Log-Row $d $m $cur $action
}

if ($Once) { Step; Get-Content (Join-Path $Out 'mag_auto_status.json'); exit 0 }
Write-Host "mag_auto $mode started $(Get-Date -f s)"
while ($true) {
  try { Step } catch { "$(Get-Date -f s) $($_.Exception.Message)" | Out-File (Join-Path $Out 'mag_auto.log') -Append -Encoding utf8 }
  Start-Sleep -Seconds 10
}
