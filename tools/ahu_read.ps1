# 中創園區 空調箱狀態查詢 (ahu_read.ps1) — 只讀，不寫入任何點位。裝在空調監控主機。
# 用法：powershell -ExecutionPolicy Bypass -File C:\BMS_Export\ahu_read.ps1 AHU_112 PAH_111 AHU_G11
# 需要 InTouch WindowViewer 開著。
param([string[]]$Names = @('AHU_112', 'PAH_111', 'AHU_G11', 'AHU_111', 'PAH_112', 'PAH_211', 'PAH_212', 'PAH_213'))
$ErrorActionPreference = 'Stop'
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
$pts = [ordered]@{ Sys_AM = '系統手自動'; Sys_Run = '系統啟動'; Fan_Run = '風車啟動'; VFD_ST = '變頻器狀態'; Fan_ST = '風車狀態'; VFD_FB = '變頻器迴授%'; CV01_FB = '冰水閥01%'; CV02_FB = '冰水閥02%'; RA_T = '回風溫度'; Set_T = '溫度設定'; RA_H = '回風濕度'; OAT = '外氣溫度' }
$days = 1..7
foreach ($a in $Names) {
  $tags = [string[]]@(foreach ($k in $pts.Keys) { "$($a)_$k" }) + [string[]]@(foreach ($d in $days) { "$($a)_SCH_0$($d)_StartHH"; "$($a)_SCH_0$($d)_StartMM"; "$($a)_SCH_0$($d)_StopHH"; "$($a)_SCH_0$($d)_StopMM"; "$($a)_SCH_0$($d)SCHEn" })
  $v = [CticDdeW]::Read($tags, [uint32]1500, 60000)
  Write-Host "===== $a =====" -ForegroundColor Cyan
  if ($null -eq $v) { Write-Host '讀不到（WindowViewer 有開嗎？）'; continue }
  $i = 0; foreach ($k in $pts.Keys) { if ($v[$i] -ne '') { Write-Host ("  {0,-10} {1}" -f $pts[$k], $v[$i]) }; $i++ }
  $wd = '一二三四五六日'
  foreach ($d in $days) { $b = $i + ($d - 1) * 5; if ($v[$b] -ne '') { Write-Host ("  星期{0} 排程 {1:00}:{2:00}–{3:00}:{4:00} 啟用={5}" -f $wd[$d-1], [int]$v[$b], [int]$v[$b+1], [int]$v[$b+2], [int]$v[$b+3], $v[$b+4]) } }
}
