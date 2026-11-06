# 中創園區 空調監控主機 唯讀記錄程式 (ac_logger.ps1)
# 每 60 秒用 DDE 向本機 InTouch WindowViewer 讀取冰桶/磁浮/BCU 點位，只讀不寫。
# 輸出：C:\BMS_Export\AC_yyyy-MM-dd.csv (每分鐘一列) 與 C:\BMS_Export\ac_latest.json
# 另每分鐘讀冰水機房泵浦/水塔/溫度/差壓與空調箱狀態 → ac_latest.json 的 plant 與 PLANT_yyyy-MM-dd.csv（2026-11-06）
# 另外每 5 分鐘讀 fcu_tags.txt 列出的外氣溫溼度與全部小型送風機（運轉、室溫、設定溫度、冷水閥），
# 輸出 C:\BMS_Export\FCU_yyyy-MM-dd.csv（每 5 分鐘一列）。
param([switch]$Once, [switch]$Fcu)
$ErrorActionPreference = 'Stop'
$Out = 'C:\BMS_Export'
New-Item -ItemType Directory -Force $Out | Out-Null
$mtx = New-Object System.Threading.Mutex($false, 'Global\CTIC_AC_Logger')
if (-not $Once -and -not $Fcu -and -not $mtx.WaitOne(0)) { exit 0 }   # 已有一份在跑

$src = @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class CticDde {
 public delegate IntPtr Cb(uint t,uint f,IntPtr hc,IntPtr h1,IntPtr h2,IntPtr hd,IntPtr d1,IntPtr d2);
 [DllImport("user32.dll")] static extern uint DdeInitializeW(ref uint id,Cb cb,uint cmd,uint res);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr DdeCreateStringHandleW(uint id,string s,int cp);
 [DllImport("user32.dll")] static extern IntPtr DdeConnect(uint id,IntPtr svc,IntPtr top,IntPtr cc);
 [DllImport("user32.dll")] static extern IntPtr DdeClientTransaction(IntPtr d,uint cb,IntPtr c,IntPtr it,uint fmt,uint typ,uint ms,out uint r);
 [DllImport("user32.dll")] static extern uint DdeGetData(IntPtr h,byte[] b,uint max,uint off);
 [DllImport("user32.dll")] static extern bool DdeFreeDataHandle(IntPtr h);
 [DllImport("user32.dll")] static extern bool DdeFreeStringHandle(uint id,IntPtr h);
 [DllImport("user32.dll")] static extern bool DdeDisconnect(IntPtr c);
 [DllImport("user32.dll")] static extern bool DdeUninitialize(uint id);
 [DllImport("user32.dll")] static extern uint DdeGetLastError(uint id);
 static Cb keep = (t,f,hc,h1,h2,hd,d1,d2) => IntPtr.Zero;
 public static string[] Read(string[] tags){ return Read(tags,5000,0); }
 // ms = 每點逾時；budget = 整批最多幾毫秒（0 = 不限）；連續 5 點逾時就放棄，避免 WindowViewer 卡住時整個程式停住
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
   bool slow=(sw.ElapsedMilliseconds-t0)>=(long)(ms*0.9);
   if(h==IntPtr.Zero){ o[i]=""; if(slow) fails++; else fails=0;
    if(fails>=5 || (budget>0 && sw.ElapsedMilliseconds>budget)){ DdeFreeStringHandle(id,it); DdeDisconnect(c);DdeFreeStringHandle(id,s);DdeFreeStringHandle(id,tp);DdeUninitialize(id); return null; } }
   else{ fails=0;uint n=DdeGetData(h,null,0,0);var b=new byte[n];DdeGetData(h,b,n,0);DdeFreeDataHandle(h);o[i]=Encoding.Default.GetString(b).TrimEnd('\0','\r','\n',' ');}
   DdeFreeStringHandle(id,it);
  }
  DdeDisconnect(c);DdeFreeStringHandle(id,s);DdeFreeStringHandle(id,tp);DdeUninitialize(id); return o;
 }
}
"@
if (-not ('CticDde' -as [type])) { Add-Type -TypeDefinition $src }

# 欄位名 = InTouch 標籤名
$cols = [ordered]@{
  ice01_pct      = 'SGB1DC51_Sys_IB_Limit01'   # 冰桶01 液位 %
  ice02_pct      = 'SGB1DC51_Sys_IB_Limit02'   # 冰桶02 液位 %
  tank_out_c     = 'SGB1DC51_Sys_T17'          # 儲冰槽出水
  tank_in_c      = 'SGB1DC51_Sys_T18'          # 儲冰槽入水
  ice_low_sp     = 'SGB1DC51_Sys_IceSetPoint'  # 冰桶低限啟動 %
  mag_c1_pct     = 'SG_CHU2_Item30049'         # 磁浮壓縮機1 負載 %
  mag_c2_pct     = 'SG_CHU2_Item30051'
  mag_c1_kw      = 'SG_CHU2_Item30041'         # 磁浮壓縮機1 實際功率
  mag_c2_kw      = 'SG_CHU2_Item30043'
  mag_limit_pct  = 'SG_CHU2_Item40035'         # 負載限制 %
  mag_chws_c     = 'SG_CHU2_Item30001'         # 冰水出水
  mag_chwr_c     = 'SG_CHU2_Item30003'         # 冰水回水
  mag_cws_c      = 'SG_CHU2_Item30005'         # 冷卻水出水
  mag_cwr_c      = 'SG_CHU2_Item30007'         # 冷卻水回水
  chu2_st        = 'SGB1DC51_CHU2_ST'
  bcu_st         = 'SGB1DC51_BCU_ST'
  bcu_chwr_c     = 'SGB1DC51_Sys_T01'          # BCU 冰水回水
  bcu_chws_c     = 'SGB1DC51_Sys_T02'          # BCU 冰水出水
  bcu_kw         = 'CH2_SH_ACMP_B_BCU1_KW'
  flow_m3h       = 'CHSYS_FLOW_NOW'
  flow_tot_m3    = 'CHSYS_FLOW_TOT'
  cop            = 'COP'
  cop_rt         = 'COP_RT'
  kw_per_rt      = 'KW_RT'
}
$names = @($cols.Keys); $tags = [string[]]@($cols.Values)
$inv = [Globalization.CultureInfo]::InvariantCulture

# 冰水機房與空調箱狀態（給本機網站「空調系統圖」用，只讀不寫）：每分鐘讀一次，放進 ac_latest.json 的 plant，
# 另存 C:\BMS_Export\PLANT_yyyy-MM-dd.csv。標籤名都來自 InTouch DBDump（2026-11-05）。
$plantTags = [Collections.Generic.List[string]]::new()
$d = 'SGB1DC51_'
foreach ($e in @('CHU1','CHU2') + (1..6 | % { "CHP$_" }) + (1..8 | % { "CWP$_" }) + (1..5 | % { "SCHP$_" }) + (1..6 | % { "BP$_" }) + (1..3 | % { "CT$_" })) {
  $plantTags.Add("$d$($e)_ST"); $plantTags.Add("$d$($e)_TR")
}
foreach ($t in 'BCU_TR11','CHP5_VFD_FB','CHP6_VFD_FB','CT1_VFD_FB','CT2_VFD_FB','CT3_VFD_FB','BP3_VFD_FB','BP4_VFD_FB',
               'SCHP1_VFD_AOP','SCHP2_VFD_AOP','SCHP3_VFD_AOP','SCHP4_VFD_AOP','SCHP5_VFD_AOP',
               'Sys_DP_01','Sys_DP_02','SCHP_123_Valve01_FB','SCHP_45_Valve01_FB','Hex01_Valve01_FB','Hex02_Valve01_FB','ET2_Limit',
               'Hex01_T01','Hex01_T02','Hex01_T03','Hex01_T04','Hex02_T01','Hex02_T02','Hex02_T03','Hex02_T04') { $plantTags.Add("$d$t") }
foreach ($n in 1..19) { if ($n -ne 16) { $plantTags.Add(('{0}Sys_T{1:00}' -f $d, $n)) } }
foreach ($u in 'AHU_111','AHU_112','AHU_121','AHU_122','AHU_1B1','AHU_1B2','AHU_G11','AHU_G21','AHU_G31','AHU_GB1','AHU_GB2',
               'PAH_111','PAH_112','PAH_121','PAH_122','PAH_131','PAH_132','PAH_211','PAH_212','PAH_213','PAH_221','PAH_222','PAH_231','PAH_232','PAH_241','PAH_242') {
  $plantTags.Add("$($u)_Fan_ST"); $plantTags.Add("$($u)_RA_T"); $plantTags.Add("$($u)_CV01_FB")
}
# COP 查核（2026-11-06）：各區 BTU 熱量計的瞬時流量（m³/h）與熱流量（GJ/h），加總可和冰水主機側流量計 CHSYS_FLOW_NOW 互相比對；
# 另讀主機冰水／冷卻水壓差（可用廠商壓損曲線推算蒸發器流量）與系統累積流量、累積熱量。全部只讀。
foreach ($b in 'PAH_131_BTU01','AHU121_122_BTU01','PAH121_122_BTU01','PAH_111_BTU01','AHU111_112_BTU01','FCU_B1_BTU01','AHU1B2_BTU01','AHU1B1_BTU01',
               'FCU_3F_BTU01','FCU_3FG_BTU01','FCU_2FG_BTU01','PAH_212_BTU01','PAH_211_BTU01','FCU_1FG_BTU01','FCU_1FB_BTU01','PAH_213_BTU01','FCU_1FB_BTU02',
               'PAH_221_BTU01','FCU_2FB_BTU01','PAH_222_BTU01','FCU_2FB_BTU02','PAH_231_BTU01','FCU_3FB_BTU01','PAH_232_BTU01','FCU_3FB_BTU02',
               'PAH_241_BTU01','FCU_4FB_BTU01','PAH_242_BTU01','FCU_4FB_BTU02') {
  $plantTags.Add("$($b)_Flow"); $plantTags.Add("$($b)_HeatFlow")
}
foreach ($t in 'SG_CHU2_Item30017','SG_CHU2_Item30019','SG_CHU2_Item30007','CHSYS_FLOW_TOT','CHSYS_B1F_BTU11_Heat_Acc','CHSYS_B1F_BTU12_Heat_Acc') { $plantTags.Add($t) }
$plantTags = [string[]]$plantTags.ToArray()

function Read-Once {
  $now = Get-Date
  $v = [CticDde]::Read($tags)
  $ok = [int]($null -ne $v)
  $vals = foreach ($i in 0..($tags.Count-1)) {
    if (-not $ok) { '' } else {
      $d = 0.0
      if ([double]::TryParse($v[$i], [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { [math]::Round($d,3).ToString($inv) } else { '' }
    }
  }
  $ts = $now.ToString('yyyy-MM-dd HH:mm:ss')
  $f = Join-Path $Out ('AC_' + $now.ToString('yyyy-MM-dd') + '.csv')
  if (-not (Test-Path $f)) { (@('time','viewer_ok') + $names) -join ',' | Out-File $f -Encoding ascii }
  ((@($ts,$ok) + $vals) -join ',') | Out-File $f -Append -Encoding ascii
  $j = [ordered]@{ time = $ts; viewer_ok = $ok }
  for ($i=0; $i -lt $names.Count; $i++) { $j[$names[$i]] = $(if ($vals[$i] -ne '') { [double]$vals[$i] } else { $null }) }
  if ($ok) {
    try {
      $pv = [CticDde]::Read($plantTags, [uint32]1500, 20000)
      if ($null -ne $pv) {
        $pl = [ordered]@{}; $row = @()
        for ($i=0; $i -lt $plantTags.Count; $i++) {
          $x = 0.0
          if ([double]::TryParse($pv[$i], [Globalization.NumberStyles]::Float, $inv, [ref]$x)) { $x = [math]::Round($x,2); $pl[$plantTags[$i]] = $x; $row += $x.ToString($inv) } else { $row += '' }
        }
        $j['plant'] = $pl
        $pf = Join-Path $Out ('PLANT_' + $now.ToString('yyyy-MM-dd') + '.csv')
        $ph = (@('time') + $plantTags) -join ','
        if ((Test-Path $pf) -and ((Get-Content $pf -TotalCount 1) -ne $ph)) { Move-Item $pf ($pf -replace '\.csv$', ('_' + $now.ToString('HHmm') + '.csv')) -Force }
        if (-not (Test-Path $pf)) { $ph | Out-File $pf -Encoding ascii }
        ((@($ts) + $row) -join ',') | Out-File $pf -Append -Encoding ascii
      }
    } catch { "$(Get-Date -f s) PLANT $($_.Exception.Message)" | Out-File (Join-Path $Out 'ac_logger.log') -Append -Encoding utf8 }
  }
  $tmp = Join-Path $Out 'ac_latest.tmp'
  ($j | ConvertTo-Json -Compress) | Out-File $tmp -Encoding ascii
  Move-Item -Force $tmp (Join-Path $Out 'ac_latest.json')
  return "$ts viewer_ok=$ok"
}

$FcuList = Join-Path $Out 'fcu_tags.txt'
function Read-Fcu {
  if (-not (Test-Path $FcuList)) { return 'no fcu_tags.txt' }
  $ft = [string[]]@(Get-Content $FcuList | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
  $now = Get-Date
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $v = [CticDde]::Read($ft)
  $ok = [int]($null -ne $v)
  $vals = foreach ($i in 0..($ft.Count-1)) {
    if (-not $ok) { '' } else {
      $d = 0.0
      if ([double]::TryParse($v[$i], [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { [math]::Round($d,2).ToString($inv) } else { '' }
    }
  }
  $ts = $now.ToString('yyyy-MM-dd HH:mm:ss')
  $f = Join-Path $Out ('FCU_' + $now.ToString('yyyy-MM-dd') + '.csv')
  $head = (@('time','viewer_ok') + $ft) -join ','
  if ((Test-Path $f) -and ((Get-Content $f -TotalCount 1) -ne $head)) {
    # 點位清單改過：舊檔改名保留，另開新檔，避免欄位對不上
    Move-Item $f ($f -replace '\.csv$', ('_' + $now.ToString('HHmm') + '.csv')) -Force
  }
  if (-not (Test-Path $f)) { $head | Out-File $f -Encoding ascii }
  ((@($ts,$ok) + $vals) -join ',') | Out-File $f -Append -Encoding ascii
  $n = @($vals | Where-Object { $_ -ne '' }).Count
  return "$ts viewer_ok=$ok read $n/$($ft.Count) in $([math]::Round($sw.Elapsed.TotalSeconds,1)) s"
}

if ($Once) { Read-Once; exit 0 }
if ($Fcu) { Read-Fcu; exit 0 }
while ($true) {
  try { Read-Once | Out-Null } catch { "$(Get-Date -f s) $($_.Exception.Message)" | Out-File (Join-Path $Out 'ac_logger.log') -Append -Encoding utf8 }
  if ((Get-Date).Minute % 5 -eq 0) {
    try { Read-Fcu | Out-Null } catch { "$(Get-Date -f s) FCU $($_.Exception.Message)" | Out-File (Join-Path $Out 'ac_logger.log') -Append -Encoding utf8 }
  }
  $s = 60 - (Get-Date).Second; if ($s -le 0) { $s = 60 }
  Start-Sleep -Seconds $s
}
