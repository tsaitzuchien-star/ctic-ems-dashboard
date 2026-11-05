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


AC_SHARE = r"\\10.10.2.4\AC_Export"


def copy_ac_files(out_dir):
    """把空調監控主機的每分鐘記錄複製到雲端資料夾；讀不到就記一筆，不影響迴路匯出。"""
    import shutil
    today = dt.date.today()
    names = [f"{p}_{d:%Y-%m-%d}.csv" for p in ("AC", "FCU", "mag_auto") for d in (today - dt.timedelta(days=1), today)]
    names += ["ac_latest.json", "mag_auto_status.json"]
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
    trigger_site_update()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        log(f"ERROR {type(e).__name__}: {e}")
        raise
