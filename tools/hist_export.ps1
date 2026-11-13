# hist_export.ps1 — 從監控電腦 InTouch 歷史檔（D:\History\*.lgh）批次匯出指定點位成 CSV。
# 透過 InTouch 內建的 HistData.exe（DDE 服務 HistData / 主題 Tagname），只讀歷史檔，不改任何設定。
# 每天一個檔：C:\BMS_Export\hist\<前綴>_yyyy-MM-dd.csv，已存在就跳過（可中斷後續跑）。
#
# 例：先探測（不匯出）           powershell -File hist_export.ps1 -Probe
#     試匯一天                   powershell -File hist_export.ps1 -Start 2026-11-05 -End 2026-11-05
#     匯整段                     powershell -File hist_export.ps1 -Start 2024-01-01 -End 2026-11-05
#     空調監控主機（2026-11-14）：-HistDir auto 自動找 .lgh 所在資料夾；-MergeTo 指定合併檔放哪（不找 Google 雲端）
param(
  [string]$Start = '', [string]$End = '',
  [string[]]$Tags = @('F0_B1P2_EACMP_1_CHU2_KW', 'F0_B1P2_EACMP_1_CHU2_KWH', 'F0_B1P2_EACMP_1_KWH'),
  [string]$Prefix = 'EACMP',
  [string]$Interval = '15m',          # HistData 取樣間隔
  [string]$Duration = '24h',          # 每個檔涵蓋的長度
  [string]$DateFmt = '',              # 空白 = 用 Windows 的簡短日期格式
  [string]$Out = 'C:\BMS_Export\hist',
  [string]$HistDir = 'D:\History',   # 歷史檔資料夾（HistData 的 DataDir）；auto = 自動找 .lgh 最多的資料夾
  [string]$DbDir = '',                # InTouch 應用程式資料夾（有 tagname.x 的地方；HistData 的 DBDir）；空白＝自動找
  [int]$TimeoutS = 300,
  [switch]$Probe,
  [switch]$Diag,
  [switch]$Merge,                     # 把每天的檔合併成一個含時間欄的 CSV，放到 Google 雲端 BMS自動匯出
  [string]$MergeTo = '',              # 合併檔改放這個資料夾（空白＝找 Google 雲端）
  [switch]$ThenMerge                  # 匯完接著合併（給 sched_cmd 用，要配 -MergeTo）
)
$ErrorActionPreference = 'Stop'

$src = @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class CticHist {
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
 static Cb keep = (t,f,hc,h1,h2,hd,d1,d2) => IntPtr.Zero;
 static uint id = 0; static IntPtr conv = IntPtr.Zero;
 public static bool Open(string svc,string topic){
  if(DdeInitializeW(ref id,keep,0x10,0)!=0) return false;
  IntPtr s=DdeCreateStringHandleW(id,svc,1200), tp=DdeCreateStringHandleW(id,topic,1200);
  conv=DdeConnect(id,s,tp,IntPtr.Zero); DdeFreeStringHandle(id,s); DdeFreeStringHandle(id,tp);
  return conv!=IntPtr.Zero;
 }
 public static bool Poke(string item,string val){
  IntPtr it=DdeCreateStringHandleW(id,item,1200); uint res;
  byte[] b=Encoding.Default.GetBytes(val+"\0");
  bool ok=DdePoke(b,(uint)b.Length,conv,it,1,0x4090,10000,out res)!=IntPtr.Zero;
  DdeFreeStringHandle(id,it); return ok;
 }
 public static string Get(string item){
  IntPtr it=DdeCreateStringHandleW(id,item,1200); uint res;
  IntPtr h=DdeClientTransaction(IntPtr.Zero,0,conv,it,1,0x20B0,10000,out res);
  DdeFreeStringHandle(id,it); if(h==IntPtr.Zero) return null;
  uint n=DdeGetData(h,null,0,0); var b=new byte[n]; DdeGetData(h,b,n,0); DdeFreeDataHandle(h);
  return Encoding.Default.GetString(b).TrimEnd('\0','\r','\n',' ');
 }
 public static void Close(){ if(conv!=IntPtr.Zero) DdeDisconnect(conv); if(id!=0) DdeUninitialize(id); conv=IntPtr.Zero; id=0; }
}
"@
Add-Type -TypeDefinition $src

function Ensure-HistData {
  if (Get-Process -Name histdata -ErrorAction SilentlyContinue) { return }
  $exe = @('C:\Program Files (x86)\Wonderware\InTouch\histdata.exe', 'C:\Program Files\Wonderware\InTouch\histdata.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $exe) { throw '找不到 histdata.exe（Wonderware\InTouch）' }
  Start-Process $exe -WindowStyle Minimized
  Start-Sleep -Seconds 5
}

function Find-DbDir {
  $cache = Join-Path (Split-Path $Out) 'hist_dbdir.txt'
  if (Test-Path $cache) { $c = (Get-Content $cache -TotalCount 1).Trim(); if ($c -and (Test-Path (Join-Path $c 'tagname.x'))) { return $c } }
  Write-Host '尋找 InTouch 應用程式資料夾（tagname.x），第一次要幾分鐘…'
  $hits = @(Get-ChildItem C:\, D:\ -Recurse -Filter tagname.x -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  foreach ($h in $hits) { Write-Host ("  找到 {0}  {1:yyyy-MM-dd HH:mm}" -f $h.DirectoryName, $h.LastWriteTime) }
  if (-not $hits.Count) { throw '找不到 tagname.x，請用 -DbDir 指定 InTouch 應用程式資料夾' }
  $hits[0].DirectoryName | Out-File $cache -Encoding utf8
  return $hits[0].DirectoryName
}

function Find-HistDir {
  $cache = Join-Path (Split-Path $Out) 'hist_histdir.txt'
  if (Test-Path $cache) { $c = (Get-Content $cache -TotalCount 1).Trim(); if ($c -and (Get-ChildItem $c -Filter *.lgh -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $c } }
  Write-Host '尋找 InTouch 歷史檔資料夾（*.lgh），第一次要幾分鐘…'
  $roots = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 -and $_.Root -match '^[A-Z]:\\$' } | ForEach-Object { $_.Root })
  $g = @(Get-ChildItem $roots -Recurse -Filter *.lgh -ErrorAction SilentlyContinue | Group-Object DirectoryName | Sort-Object Count -Descending)
  foreach ($x in $g) { $f = @($x.Group | Sort-Object Name); Write-Host ("  {0}  {1} 個  {2} ~ {3}" -f $x.Name, $x.Count, $f[0].Name, $f[-1].Name) }
  if (-not $g.Count) { throw '找不到任何 .lgh 歷史檔' }
  $g[0].Name | Out-File $cache -Encoding utf8
  return $g[0].Name
}

if ($Merge) {
  $drive = $null
  if ($MergeTo) { if (-not (Test-Path $MergeTo)) { throw "沒有 $MergeTo" }; $drive = $MergeTo }
  if (-not $drive) { foreach ($r in (Get-PSDrive -PSProvider FileSystem | % Root)) {
    foreach ($sub in '我的雲端硬碟', 'My Drive') {
      $base = Join-Path $r $sub
      if (Test-Path $base) { $hit = Get-ChildItem $base -Directory -Filter 'BMS*' | Select-Object -First 1; if ($hit) { $drive = $hit.FullName; break } }
    }
    if ($drive) { break }
  } }
  if (-not $drive) { throw '找不到 Google 雲端的 BMS自動匯出 資料夾' }
  $step = [int]($Interval -replace '[^0-9]', ''); if ($Interval -match 'h$') { $step *= 60 }
  $files = @(Get-ChildItem $Out -Filter "$($Prefix)_*.csv" | Sort-Object Name)
  if (-not $files.Count) { throw "沒有 $Prefix 的日檔" }
  $first = $files[0].BaseName.Substring($Prefix.Length + 1); $last = $files[-1].BaseName.Substring($Prefix.Length + 1)
  $dest = Join-Path $drive ("hist_{0}_{1}_{2}.csv" -f $Prefix, $first, $last)
  $sb = New-Object System.Text.StringBuilder
  $perDay = [int](1440 / $step)
  $hdr = $false
  foreach ($f in $files) {
    $day = [datetime]::ParseExact($f.BaseName.Substring($Prefix.Length + 1), 'yyyy-MM-dd', $null)
    $lines = @(Get-Content $f.FullName)
    if ($lines.Count -lt 2) { continue }
    if (-not $hdr) { [void]$sb.AppendLine('time,' + $lines[0]); $hdr = $true }
    for ($i = 1; $i -lt [math]::Min($lines.Count, $perDay + 1); $i++) {
      [void]$sb.AppendLine(('{0:yyyy-MM-dd HH:mm},' -f $day.AddMinutes(($i - 1) * $step)) + $lines[$i])
    }
  }
  [IO.File]::WriteAllText($dest, $sb.ToString(), [Text.Encoding]::ASCII)
  "合併 $($files.Count) 天 → $dest（$([math]::Round((Get-Item $dest).Length/1MB,1)) MB）"
  return
}

Ensure-HistData
if (-not [CticHist]::Open('HistData', 'Tagname')) { throw '連不上 HistData（DDE HistData|Tagname）' }
try {
  $items = 'DBDir', 'DataDir', 'Tags', 'StartDate', 'StartTime', 'Duration', 'Interval', 'FileName', 'WriteFile', 'Error'
  if ($Probe) {
    foreach ($i in $items) { $v = [CticHist]::Get($i); "{0,-10} = {1}" -f $i, $(if ($null -eq $v) { '(讀取失敗)' } elseif ($v -eq '') { '(空白)' } else { $v }) }
    "日期格式（Windows 簡短日期）：$([Globalization.CultureInfo]::CurrentCulture.DateTimeFormat.ShortDatePattern)"
    return
  }
  if ($Diag) {
    # 找出 HistData 接受的點位欄位名稱與格式
    foreach ($name in 'TagNames', 'Tagnames', 'TagName', 'Tagname', 'Tags', 'Tag') {
      foreach ($v in @($Tags[0], ($Tags -join ','), ('$' + $Tags[0]))) {
        $ok = [CticHist]::Poke($name, $v)
        "{0,-9} <- {1,-40} poke={2}  讀回={3}  Error={4}" -f $name, $v, [int]$ok, [CticHist]::Get($name), [CticHist]::Get('Error')
      }
    }
    foreach ($v in '1', '1.0', 'On', 'TRUE') { "WriteFile <- {0,-5} poke={1}  Error={2}" -f $v, [int]([CticHist]::Poke('WriteFile', $v)), [CticHist]::Get('Error') }
    return
  }
  if (-not $Start -or -not $End) { throw '請給 -Start 與 -End（yyyy-MM-dd），或用 -Probe' }
  if (-not $DateFmt) { $DateFmt = [Globalization.CultureInfo]::CurrentCulture.DateTimeFormat.ShortDatePattern }
  New-Item -ItemType Directory -Force -Path $Out | Out-Null
  if (-not $DbDir) { $DbDir = Find-DbDir }
  if ($HistDir -eq 'auto') { $HistDir = Find-HistDir }
  "InTouch 應用程式資料夾：$DbDir；歷史檔資料夾：$HistDir"
  $d = [datetime]::ParseExact($Start, 'yyyy-MM-dd', $null); $e = [datetime]::ParseExact($End, 'yyyy-MM-dd', $null)
  $okN = 0; $failN = 0
  while ($d -le $e) {
    $f = Join-Path $Out ("{0}_{1:yyyy-MM-dd}.csv" -f $Prefix, $d)
    if (Test-Path $f) { $d = $d.AddDays(1); continue }
    $lgh = Join-Path $HistDir ("{0:yyMMdd}00.lgh" -f $d)
    if (-not (Test-Path $lgh)) { "{0:yyyy-MM-dd}  沒有歷史檔，跳過" -f $d; $d = $d.AddDays(1); continue }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # 點位欄位叫 Tags（2026-11-06 診斷確認）；日期格式依序試，找到可用的就記住
    $p = @(
      [CticHist]::Poke('DBDir', $DbDir),
      [CticHist]::Poke('DataDir', $HistDir),
      [CticHist]::Poke('Tags', ($Tags -join ',')),
      [CticHist]::Poke('StartTime', '00:00:00'),
      [CticHist]::Poke('Duration', $Duration),
      [CticHist]::Poke('Interval', $Interval),
      [CticHist]::Poke('FileName', $f))
    $fmts = @($DateFmt) + @('M/d/yyyy', 'MM/dd/yyyy', 'MM/dd/yy', 'M/d/yy', 'yyyy/MM/dd') | Select-Object -Unique
    $wf = $false
    foreach ($fmt in $fmts) {
      $p1 = [CticHist]::Poke('StartDate', $d.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture))
      $wf = [CticHist]::Poke('WriteFile', '1')
      if ($wf) { $script:DateFmt = $fmt; break }
      "  日期格式 {0} 不行：{1}" -f $fmt, [CticHist]::Get('Error')
    }
    $p += $wf
    $done = $false
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutS) {
      Start-Sleep -Milliseconds 500
      if ([CticHist]::Get('WriteFile') -eq '0') { $done = $true; break }
    }
    $err = [CticHist]::Get('Error')
    $rows = $(if (Test-Path $f) { (Get-Content $f | Measure-Object).Count } else { 0 })
    "{0:yyyy-MM-dd}  日期格式={6}  poke={1}  完成={2}  列數={3}  {4:N0} 秒  Error={5}" -f $d, (($p | % { [int]$_ }) -join ''), $done, $rows, $sw.Elapsed.TotalSeconds, $err, $DateFmt
    if ($rows -gt 1) { $okN++ } else { $failN++; if ($failN -ge 3 -and $okN -eq 0) { throw '連續 3 天匯不出資料，先停下來檢查' } }
    $d = $d.AddDays(1)
  }
  "完成：成功 $okN 天，失敗 $failN 天，檔案在 $Out"
} finally { [CticHist]::Close() }
if ($ThenMerge) { & $PSCommandPath -Merge -Prefix $Prefix -Interval $Interval -Out $Out -MergeTo $MergeTo }
