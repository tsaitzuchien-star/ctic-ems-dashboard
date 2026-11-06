# 中創園區 送風機（FCU）開關測試工具 (fcu_switch.ps1) — 裝在空調監控主機
# Cliff 2026-11-06 授權：先拿他的辦公室 B239（2F B 區面板 P25 = SG_2F31_P25，FCU01/02）測試遠端關閉。
# 只允許寫 _Run（0 = 關、1 = 開）和 _setT（只允許 25–28°C，園區標準 25–26°C），而且只限下面 $Allow 列的面板。
# 用法（InTouch WindowViewer 要開著）：
#   powershell -ExecutionPolicy Bypass -File fcu_switch.ps1                 # 只讀 B239 目前狀態
#   powershell -ExecutionPolicy Bypass -File fcu_switch.ps1 -Off            # 寫 Run=0，每 5 秒讀回，看 60 秒
#   powershell -ExecutionPolicy Bypass -File fcu_switch.ps1 -On             # 寫 Run=1，每 5 秒讀回，看 60 秒
#   powershell -ExecutionPolicy Bypass -File fcu_switch.ps1 -SetT 25        # 寫設定溫度 25°C，每 5 秒讀回，看 60 秒
# 每次寫入記錄在 C:\BMS_Export\fcu_switch.log
param([string]$Panel = 'SG_2F31_P25', [switch]$Off, [switch]$On, [double]$SetT = -1, [int]$Watch = 60)
$ErrorActionPreference = 'Stop'
$Out = 'C:\BMS_Export'
$Log = Join-Path $Out 'fcu_switch.log'
$Allow = @('SG_2F31_P25')   # B239（Cliff 辦公室）
if ($Allow -notcontains $Panel) { throw "拒絕：$Panel 不在授權清單（目前只有 $($Allow -join ', ')）" }
if ((@([bool]$Off, [bool]$On, ($SetT -ge 0)) -eq $true).Count -gt 1) { throw '-Off、-On、-SetT 只能選一個' }
if ($SetT -ge 0 -and ($SetT -lt 25 -or $SetT -gt 28)) { throw "拒絕寫入設定溫度 $SetT°C（只允許 25–28°C）" }

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

$all = @(Get-Content (Join-Path $Out 'fcu_tags.txt') | ForEach-Object { $_.Trim() } | Where-Object { $_ -like "$($Panel)_FCU*_Run" } | ForEach-Object { $_ -replace '_Run$','' })
if (-not $all.Count) { $all = @("$($Panel)_FCU01", "$($Panel)_FCU02") }
$fields = 'Run','Fan_High','Fan_Middle','Fan_Low','SpeedSetting','Mode','T','setT','CV_State'
function Snap {
  $tags = [string[]]@(foreach ($u in $all) { foreach ($f in $fields) { "$($u)_$f" } }) + "$($Panel)_GroupPower"
  $v = [CticDdeW]::Read($tags)
  if ($null -eq $v) { throw 'DDE 連不上 InTouch（WindowViewer 有開嗎？）' }
  $rows = @()
  for ($i = 0; $i -lt $all.Count; $i++) {
    $h = [ordered]@{ time = (Get-Date -f 'HH:mm:ss'); fcu = ($all[$i] -replace '^.*_','') }
    for ($j = 0; $j -lt $fields.Count; $j++) { $h[$fields[$j]] = $v[$i * $fields.Count + $j] }
    $h['GroupPower'] = $v[$tags.Count - 1]
    $rows += [pscustomobject]$h
  }
  return $rows
}
function Show($r) { $r | Format-Table -AutoSize | Out-String -Width 200 | Write-Host }

$b = Snap; Show $b
if (-not ($Off -or $On -or $SetT -ge 0)) { exit 0 }
if ($SetT -ge 0) {
  $val = $SetT.ToString([Globalization.CultureInfo]::InvariantCulture); $pt = 'setT'
} else { $val = $(if ($Off) { '0' } else { '1' }); $pt = 'Run' }
$res = @(foreach ($u in $all) { "$($u)_$pt=" + [CticDdeW]::Poke("$($u)_$pt", $val) })
$line = "$(Get-Date -f s) $Panel $pt=$val poke: $($res -join ' ') before: $(($b | ForEach-Object { "$($_.fcu) Run=$($_.Run) H/M/L=$($_.Fan_High)/$($_.Fan_Middle)/$($_.Fan_Low) setT=$($_.setT)" }) -join '; ')"
$line | Out-File $Log -Append -Encoding utf8
Write-Host $line
for ($t = 0; $t -lt $Watch; $t += 5) { Start-Sleep -Seconds 5; Snap | Format-Table -HideTableHeaders -AutoSize | Out-String -Width 200 | Write-Host }
$a = Snap
"$(Get-Date -f s) $Panel after: $(($a | ForEach-Object { "$($_.fcu) Run=$($_.Run) H/M/L=$($_.Fan_High)/$($_.Fan_Middle)/$($_.Fan_Low) setT=$($_.setT)" }) -join '; ')" | Out-File $Log -Append -Encoding utf8
