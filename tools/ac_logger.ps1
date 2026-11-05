# 中創園區 空調監控主機 唯讀記錄程式 (ac_logger.ps1)
# 每 60 秒用 DDE 向本機 InTouch WindowViewer 讀取冰桶/磁浮/BCU 點位，只讀不寫。
# 輸出：C:\BMS_Export\AC_yyyy-MM-dd.csv (每分鐘一列) 與 C:\BMS_Export\ac_latest.json
param([switch]$Once)
$ErrorActionPreference = 'Stop'
$Out = 'C:\BMS_Export'
New-Item -ItemType Directory -Force $Out | Out-Null
$mtx = New-Object System.Threading.Mutex($false, 'Global\CTIC_AC_Logger')
if (-not $Once -and -not $mtx.WaitOne(0)) { exit 0 }   # 已有一份在跑

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

function Read-Once {
  $now = Get-Date
  $v = [CticDde]::Read($tags)
  $ok = [int]($v -ne $null)
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
  $tmp = Join-Path $Out 'ac_latest.tmp'
  ($j | ConvertTo-Json -Compress) | Out-File $tmp -Encoding ascii
  Move-Item -Force $tmp (Join-Path $Out 'ac_latest.json')
  return "$ts viewer_ok=$ok"
}

if ($Once) { Read-Once; exit 0 }
while ($true) {
  try { Read-Once | Out-Null } catch { "$(Get-Date -f s) $($_.Exception.Message)" | Out-File (Join-Path $Out 'ac_logger.log') -Append -Encoding utf8 }
  $s = 60 - (Get-Date).Second; if ($s -le 0) { $s = 60 }
  Start-Sleep -Seconds $s
}
