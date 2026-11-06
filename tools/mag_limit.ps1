# 中創園區 磁浮冰機 CHU-2 負載限制 寫入工具 (mag_limit.ps1)
# 只寫這些標籤：負載限制百分比 SG_CHU2_Item40035、限制啟用時間 SG_CHU2_Item40035_TIME_SET1_H/_M，
# 以及冰水出水溫度設定 1、2（SG_CHU2_Item40001/40003）。
# 負載限制要到「啟用時間」那一分鐘才會送到主機（監控廠商 2026-11-06），所以 -Set 會把啟用時間設成下一分鐘。
# 用法（空調監控主機，InTouch WindowViewer 要開著）：
#   powershell -ExecutionPolicy Bypass -File mag_limit.ps1            # 只讀目前狀態
#   powershell -ExecutionPolicy Bypass -File mag_limit.ps1 -Set 85    # 寫入 85%，啟用時間設為下一分鐘，讀回確認
#   powershell -ExecutionPolicy Bypass -File mag_limit.ps1 -Sp 12.5   # 冰水出水溫度設定 1、2 寫入 12.5°C（只允許 10–14），讀回確認
#   powershell -ExecutionPolicy Bypass -File mag_limit.ps1 -Tags A,B   # 只讀任意標籤（不寫入）
#   powershell -ExecutionPolicy Bypass -File mag_limit.ps1 -Test      # 原值-5%，觀察 60 秒，寫回原值
# 安全限制：只接受 30–100%；每次寫入記錄在 C:\BMS_Export\mag_control.log。
param([double]$Set = -1, [switch]$Test, [int]$Watch = 60, [string[]]$Tags, [double]$Sp = -1)
$ErrorActionPreference = 'Stop'
$Out = 'C:\BMS_Export'
$Tag = 'SG_CHU2_Item40035'
$Min = 20; $Max = 100
$Log = Join-Path $Out 'mag_control.log'

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

if ($Tags) {   # 只讀，不寫入
  $Tags = [string[]]@($Tags -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $v = [CticDdeW]::Read([string[]]$Tags)
  if ($null -eq $v) { throw 'DDE 連不上 InTouch（WindowViewer 有開嗎？）' }
  for ($i = 0; $i -lt $Tags.Count; $i++) { '{0,-30} {1}' -f $Tags[$i], $v[$i] }
  exit 0
}

$names = 'sp1','sp2','enabled','start_h','start_m','stop_h','stop_m','limit_pct','chu2_st','c1_pct','c2_pct','c1_kw','c2_kw','chws_c','chwr_c'
$tags  = [string[]]@('SG_CHU2_Item40001','SG_CHU2_Item40003','SG_CHU2_Item40035_SCH_ONOFF','SG_CHU2_Item40035_TIME_SET1_H','SG_CHU2_Item40035_TIME_SET1_M','SG_CHU2_Item40035_TIME_SET2_H','SG_CHU2_Item40035_TIME_SET2_M',$Tag,'SGB1DC51_CHU2_ST','SG_CHU2_Item30049','SG_CHU2_Item30051','SG_CHU2_Item30041','SG_CHU2_Item30043','SG_CHU2_Item30001','SG_CHU2_Item30003')
function Snap {
  $v = [CticDdeW]::Read($tags)
  if ($null -eq $v) { throw 'DDE 連不上 InTouch（WindowViewer 有開嗎？）' }
  $h = [ordered]@{ time = (Get-Date -f 'HH:mm:ss') }
  for ($i=0; $i -lt $names.Count; $i++) { $h[$names[$i]] = $v[$i] }
  return [pscustomobject]$h
}
# 把「啟用時間」設成下一分鐘（剩不到 10 秒就設下下分鐘），讓主機在那一分鐘套用新的上限。
function Trigger-Limit {
  $n = Get-Date
  $t = $n.AddMinutes($(if ($n.Second -ge 50) { 2 } else { 1 }))
  $s = Snap
  if ("$($s.stop_h)" -ne '' -and [int][double]$s.stop_h -eq $t.Hour -and [int][double]$s.stop_m -eq $t.Minute) { $t = $t.AddMinutes(1) }
  $okH = [CticDdeW]::Poke('SG_CHU2_Item40035_TIME_SET1_H', "$($t.Hour)")
  $okM = [CticDdeW]::Poke('SG_CHU2_Item40035_TIME_SET1_M', "$($t.Minute)")
  return ('{0:HH:mm}' -f $t) + " ok=$okH/$okM"
}
function Write-Limit([double]$p, [string]$why) {
  if ($p -lt $Min -or $p -gt $Max) { throw "拒絕寫入 $p%（只允許 $Min–$Max%）" }
  $before = (Snap).limit_pct
  $ok = [CticDdeW]::Poke($Tag, $p.ToString([Globalization.CultureInfo]::InvariantCulture))
  $trig = Trigger-Limit
  Start-Sleep -Seconds 2
  $after = (Snap).limit_pct
  $line = "$(Get-Date -f s) $why set=$p before=$before after=$after poke_ok=$ok start=$trig"
  $line | Out-File $Log -Append -Encoding utf8
  Write-Host $line
  return $after
}

if ($Test) {
  $s = Snap; $s | Format-Table -AutoSize | Out-String | Write-Host
  $orig = [double]$s.limit_pct
  $target = [math]::Max($Min, $orig - 5)
  try {
    Write-Limit $target 'TEST' | Out-Null
    for ($t = 0; $t -lt $Watch; $t += 10) { Start-Sleep -Seconds 10; Snap | Format-Table -HideTableHeaders -AutoSize | Out-String | Write-Host }
  } finally {
    Write-Limit $orig 'RESTORE' | Out-Null
  }
  Snap | Format-Table -AutoSize | Out-String | Write-Host
} elseif ($Sp -ge 0) {
  if ($Sp -lt 10 -or $Sp -gt 14) { throw "拒絕寫入出水設定 $Sp°C（只允許 10–14°C）" }
  $b = Snap
  $v = $Sp.ToString([Globalization.CultureInfo]::InvariantCulture)
  $ok1 = [CticDdeW]::Poke('SG_CHU2_Item40001', $v); $ok2 = [CticDdeW]::Poke('SG_CHU2_Item40003', $v)
  Start-Sleep -Seconds 2
  $a = Snap
  $line = "$(Get-Date -f s) SP set=$Sp before=$($b.sp1)/$($b.sp2) after=$($a.sp1)/$($a.sp2) poke_ok=$ok1/$ok2"
  $line | Out-File $Log -Append -Encoding utf8
  Write-Host $line
  $a | Format-Table -AutoSize | Out-String | Write-Host
} elseif ($Set -ge 0) {
  Write-Limit $Set 'MANUAL' | Out-Null
  Snap | Format-Table -AutoSize | Out-String | Write-Host
} else {
  Snap | Format-Table -AutoSize | Out-String | Write-Host
}
