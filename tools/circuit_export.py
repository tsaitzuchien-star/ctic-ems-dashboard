"""每 15 分鐘從 InTouch（WindowViewer）用 DDE 讀所有分路 kWh，寫到 Google 雲端「BMS自動匯出」。

在監控電腦執行，需要：
- InTouch WindowViewer 開著；本程式要用「系統管理員」權限執行（與 view.exe 同權限才能 DDE）。
- pywin32（python -m pip install pywin32）。
- 同資料夾的 circuit_tags.txt（每行一個標籤名稱）。

輸出：<BMS自動匯出>\\Circuit_YYYY-MM-DD.csv，每天一個檔，每次執行附加一列：
DateTime, <tag1>, <tag2>, ...（讀不到的留空）。
寫完後把空調監控主機共用資料夾 \\\\10.10.2.4\\AC_Export 的 AC_*.csv（今天、昨天）與 ac_latest.json
複製到同一個 BMS自動匯出 資料夾（需先用 cmdkey 存好 ctic_reader 認證；讀不到只記 log）。
若同資料夾有 github_token.txt（只開 Smart-Energy-Dashboard 的 Actions 寫入權限的 fine-grained token），
會等 3 分鐘讓 Google 雲端同步，再觸發 ems_live 工作流程更新網站；GitHub 自己的排程常延誤數小時。
匯出歷史（2026-11-21 起，Cliff 授權「執行」）：每次執行順便讀 ems-commands 分支 commands/bms_hist.json，
有新的 id、在核准期限內、set 在 HIST_SETS 白名單，就在背景用同資料夾的 hist_export.ps1 只讀匯出監控電腦
InTouch 歷史（D:\\History），跑完合併成 <BMS自動匯出>\\hist_<set>_<起>_<迄>.csv，進度記在 <BMS自動匯出>\\hist_<set>.log。
用法：
    python circuit_export.py          # 正式執行一次
    python circuit_export.py --test   # 只讀前 50 個標籤，印出結果與耗時，不寫檔
"""
import csv
import datetime as dt
import os
import string
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "circuit_export.log")


def log(msg):
    line = f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def find_out_dir():
    """找 Google 雲端硬碟裡名稱以 BMS 開頭的資料夾（與 bms_export.ps1 相同規則）。"""
    for letter in string.ascii_uppercase[3:]:          # D: 之後
        root = f"{letter}:\\"
        if not os.path.isdir(root):
            continue
        for sub in ("我的雲端硬碟", "My Drive"):
            base = os.path.join(root, sub)
            if os.path.isdir(base):
                for name in os.listdir(base):
                    if name.startswith("BMS") and os.path.isdir(os.path.join(base, name)):
                        return os.path.join(base, name)
    raise SystemExit("找不到 Google 雲端硬碟的 BMS自動匯出 資料夾")


def connect():
    import win32ui  # noqa: F401  必須先 import，dde 才能用
    import dde
    server = dde.CreateServer()
    server.Create("CircuitExport")
    conv = dde.CreateConversation(server)
    conv.ConnectTo("VIEW", "TAGNAME")
    return server, conv


def read(conv, tag):
    try:
        v = conv.Request(tag).strip("\x00 \r\n")
        return f"{float(v):.2f}"
    except Exception:
        return ""


DISPATCH_URL = ("https://api.github.com/repos/tsaitzuchien-star/Smart-Energy-Dashboard"
                "/actions/workflows/ems_live.yml/dispatches")


def trigger_site_update(wait=180):
    """有 github_token.txt 才觸發網站更新；失敗只記 log，不影響匯出。"""
    path = os.path.join(HERE, "github_token.txt")
    if not os.path.exists(path):
        return
    import json
    import urllib.request
    with open(path, encoding="utf-8") as f:
        token = f.read().strip()
    time.sleep(wait)
    req = urllib.request.Request(DISPATCH_URL, data=json.dumps({"ref": "main"}).encode(), method="POST", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": "ctic-circuit-export"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            log(f"site update triggered ({r.status})")
            return
    except Exception as e:
        err = e
    # 公司網路會攔截 SSL，Python 不認得公司憑證；改用 Windows 自己的 PowerShell 送出。
    import subprocess
    import base64
    ps = ("[Net.ServicePointManager]::SecurityProtocol='Tls12';"
          "$h=@{Authorization='Bearer '+$env:GH_TOKEN;Accept='application/vnd.github+json';"
          "'User-Agent'='ctic-circuit-export'};"
          "$r=Invoke-WebRequest -UseBasicParsing -Method Post -Uri $env:GH_URL -Headers $h "
          "-Body '{\"ref\":\"main\"}' -ContentType 'application/json';$r.StatusCode")
    enc = base64.b64encode(ps.encode("utf-16-le")).decode()
    env = dict(os.environ, GH_TOKEN=token, GH_URL=DISPATCH_URL)
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", enc],
                             env=env, capture_output=True, text=True, timeout=60)
        code = out.stdout.strip().splitlines()[-1] if out.stdout.strip() else ""
        if code == "204":
            log("site update triggered (204, powershell)")
        else:
            log(f"site update trigger failed: python {err}; powershell {code} {out.stderr.strip()[:200]}")
    except Exception as e2:
        log(f"site update trigger failed: python {err}; powershell {e2}")


# ---- 匯出歷史（監控電腦 InTouch，只讀） ----
HIST_CMD_URL = "https://raw.githubusercontent.com/tsaitzuchien-star/ctic-ems-dashboard/ems-commands/commands/bms_hist.json"
HIST_SETS = {   # 只允許這些點位組合；要加新的組合要改程式、經 Cliff 同意
    "ACMP": ["F0_B1P2_ACMP_1_KWH", "F0_B1P2_ACMP_2_KWH", "F0_B1P2_ACMP_G1_KWH"],
}
HIST_DONE = os.path.join(HERE, "bms_hist_done.txt")


def _fetch_text(url):
    """先用 Python 抓；公司網路攔 SSL 時改用 PowerShell。"""
    import urllib.request
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "ctic-circuit-export"}), timeout=30) as r:
            return r.read().decode("utf-8-sig")
    except Exception:
        pass
    import subprocess
    import base64
    ps = ("[Net.ServicePointManager]::SecurityProtocol='Tls12';"
          "[Console]::OutputEncoding=[Text.Encoding]::UTF8;"
          "(Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri $env:CTIC_URL).Content")
    enc = base64.b64encode(ps.encode("utf-16-le")).decode()
    out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", enc],
                         env=dict(os.environ, CTIC_URL=url), capture_output=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.decode("utf-8", "replace").strip()[:200])
    return out.stdout.decode("utf-8", "replace").lstrip("\ufeff")


def check_hist_command(out_dir):
    """有新的匯出歷史指令就在背景開始跑；任何問題只記 log，不影響迴路匯出。"""
    import json
    import subprocess
    try:
        cmd = json.loads(_fetch_text(HIST_CMD_URL))
    except Exception as e:
        log(f"hist cmd: cannot read ({type(e).__name__})")
        return
    cid = str(cmd.get("id", "")).strip()
    if not cid:
        return
    done = set()
    if os.path.exists(HIST_DONE):
        with open(HIST_DONE, encoding="utf-8") as f:
            done = {x.strip() for x in f}
    if cid in done:
        return

    def finish(msg):
        with open(HIST_DONE, "a", encoding="utf-8") as f:
            f.write(cid + "\n")
        log(f"hist cmd {cid}: {msg}")

    try:
        apv = dt.datetime.fromisoformat(str(cmd["approved_at"]))
        exp = dt.datetime.fromisoformat(str(cmd["expires"]))
        start = dt.date.fromisoformat(str(cmd["start"]))
        end = dt.date.fromisoformat(str(cmd["end"]))
    except Exception:
        return finish("rejected: bad approved_at/expires/start/end")
    now = dt.datetime.now(dt.timezone(dt.timedelta(hours=8)))
    if exp.tzinfo is None or apv.tzinfo is None:
        return finish("rejected: times need +08:00")
    if now > exp:
        return finish("rejected: expired")
    if (exp - apv).total_seconds() > 24 * 3600:
        return finish("rejected: expires more than 24 h after approval")
    hset = str(cmd.get("set", ""))
    if hset not in HIST_SETS:
        return finish(f"rejected: set {hset} not in whitelist")
    if not (dt.date(2021, 1, 1) <= start <= end <= dt.date.today()):
        return finish("rejected: bad date range")
    script = os.path.join(HERE, "hist_export.ps1")
    if not os.path.exists(script):
        return finish("rejected: hist_export.ps1 missing")
    lock = os.path.join(HERE, f"hist_{hset}.running")
    if os.path.exists(lock) and time.time() - os.path.getmtime(lock) < 6 * 3600:
        log(f"hist cmd {cid}: another {hset} export still running, wait")
        return
    hlog = os.path.join(out_dir, f"hist_{hset}.log")
    tags = ",".join(HIST_SETS[hset])
    ps = (f"$ErrorActionPreference='Continue'; New-Item -ItemType File -Force '{lock}' | Out-Null; "
          f"try {{ & '{script}' -Start {start:%Y-%m-%d} -End {end:%Y-%m-%d} -Prefix {hset} -Tags {tags}; "
          f"& '{script}' -Merge -Prefix {hset} }} finally {{ Remove-Item '{lock}' -ErrorAction SilentlyContinue; "
          f"'完成 ' + (Get-Date -f 'yyyy-MM-dd HH:mm') }}")
    with open(hlog, "a", encoding="utf-8") as f:
        f.write(f"{dt.datetime.now():%Y-%m-%d %H:%M} 開始 {cid} set={hset} {start}~{end}\n")
    try:
        lf = open(hlog, "a", encoding="utf-8")
        subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
                         stdout=lf, stderr=subprocess.STDOUT, cwd=HERE,
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "DETACHED_PROCESS", 0))
    except Exception as e:
        return finish(f"failed to start: {e}")
    finish(f"started {hset} {start}~{end} -> {hlog}")


AC_SHARE = r"\\10.10.2.4\AC_Export"


def copy_ac_files(out_dir):
    """把空調監控主機的每分鐘記錄複製到雲端資料夾；讀不到就記一筆，不影響迴路匯出。"""
    import shutil
    today = dt.date.today()
    names = [f"{p}_{d:%Y-%m-%d}.csv" for p in ("AC", "PLANT", "FCU", "mag_auto", "fcu_guard") for d in (today - dt.timedelta(days=1), today)]
    names += ["ac_latest.json", "mag_auto_status.json", "fcu_guard_status.json",
              "sched_cmd_result.json", "sched_cmd.log", "sched_changes.log"]
    try:   # 匯出歷史（sched_cmd kind=hist）的合併檔與進度紀錄
        names += [n for n in os.listdir(AC_SHARE) if n.startswith("hist_") and (n.endswith(".csv") or n.endswith(".log"))]
    except OSError:
        pass
    copied = 0
    try:
        for n in names:
            src = os.path.join(AC_SHARE, n)
            if not os.path.exists(src):
                continue
            dst = os.path.join(out_dir, n)
            st = os.stat(src)
            if os.path.exists(dst) and os.path.getsize(dst) == st.st_size and os.path.getmtime(dst) >= st.st_mtime:
                continue
            shutil.copy2(src, dst)
            copied += 1
        sd = os.path.join(AC_SHARE, "shots")   # 截圖（sched_cmd kind=screenshot）
        if os.path.isdir(sd):
            od = os.path.join(out_dir, "shots")
            os.makedirs(od, exist_ok=True)
            for n in os.listdir(sd):
                if n.startswith("shot_") and n.endswith(".png") and not os.path.exists(os.path.join(od, n)):
                    shutil.copy2(os.path.join(sd, n), os.path.join(od, n))
                    copied += 1
        log(f"AC files copied: {copied}")
    except OSError as e:
        log(f"AC copy failed: {e}")


def main():
    test = "--test" in sys.argv
    with open(os.path.join(HERE, "circuit_tags.txt"), encoding="utf-8") as f:
        tags = [t.strip() for t in f if t.strip()]
    if test:
        tags = tags[:50]

    now = dt.datetime.now().replace(second=0, microsecond=0)
    now -= dt.timedelta(minutes=now.minute % 15)      # 對齊整 15 分
    t0 = time.time()
    server, conv = connect()
    values = [read(conv, t) for t in tags]
    server.Destroy()
    secs = time.time() - t0
    ok = sum(1 for v in values if v)

    if test:
        for t, v in zip(tags, values):
            print(f"{t:40s} {v}")
        print(f"\n讀到 {ok}/{len(tags)} 個，耗時 {secs:.1f} 秒")
        return

    out = os.path.join(find_out_dir(), f"Circuit_{now:%Y-%m-%d}.csv")
    new = not os.path.exists(out)
    with open(out, "a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["DateTime"] + tags)
        w.writerow([f"{now:%Y/%m/%d %H:%M:%S}"] + values)
    log(f"OK {ok}/{len(tags)} tags in {secs:.0f}s -> {out}")
    copy_ac_files(os.path.dirname(out))
    try:
        check_hist_command(os.path.dirname(out))
    except Exception as e:
        log(f"hist cmd error: {type(e).__name__}: {e}")
    trigger_site_update()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        log(f"ERROR {type(e).__name__}: {e}")
        raise
