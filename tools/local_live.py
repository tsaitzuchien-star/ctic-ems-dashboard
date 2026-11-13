r"""中創園區 本機即時能源網站（在監控電腦執行，只給監控電腦與空調監控主機看）。

每 5 秒用 DDE 唯讀讀 InTouch 的總電表瞬時 kW（F0_B2P2_MCB_KW_PV），
每 30 秒讀空調監控主機共用資料夾的 ac_latest.json（冰桶液位、磁浮負載），
算出台電 15 分鐘需量（本時段平均、推估、今日最高）並與當下時段的契約容量比較，
每 60 秒用 DDE 讀全部 6,618 個迴路度數（circuit_tags.txt），配合 G: 的 Circuit_*.csv 歷史，
在本機算出跟雲端版一樣的總覽與房間資料（/api/ems/live.json、/api/ems/rooms.json），不連雲端。
用內建網頁伺服器在 http://<監控電腦>:8088/ 提供完整園區能源網站（與雲端版相同，另多一個
「即時監控」分頁每 5 秒更新），精簡版即時頁在 /live。
網站檔案（index.html、data\*.json）放在本程式旁的 site\ 資料夾。
只放行 ALLOW_IPS 裡的電腦（本機與空調監控主機）與 allow_ips.txt 列的 IP／網段（例如 Tailscale 手機），其他一律 403。

需要：InTouch WindowViewer 開著、系統管理員權限（與 view.exe 同權限才能 DDE）、pywin32。
用法：
    python local_live.py           # 啟動網站（前景）
    python local_live.py --test    # 讀一次並印出，不啟動網站
"""
import datetime as dt
import json
import os
import re
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import ems_calc
import line_push

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "local_live_state.json")
LOG = os.path.join(HERE, "local_live.log")
PORT = 8088
MAIN_TAG = "F0_B2P2_MCB_KW_PV"
TAIPOWER_OFFSET = 10.0          # 台電電表比 BMS 高約 10 kW（2026-11 對帳確認）
AC_SHARE = r"\\10.10.2.4\AC_Export"
AC_JSON = os.path.join(AC_SHARE, "ac_latest.json")
MAG_JSON = os.path.join(AC_SHARE, "mag_auto_status.json")   # 磁浮自動控制 mag_auto.ps1 的狀態
GUARD_JSON = os.path.join(AC_SHARE, "fcu_guard_status.json")   # 送風機巡檢 fcu_guard.ps1 的狀態
SAMPLE_S = 5
HISTORY = 2 * 3600 // SAMPLE_S  # 網頁趨勢圖保留 2 小時
SITE_DIR = os.path.join(HERE, "site")
CIRCUIT_S = 60                  # 全迴路讀取間隔
ALLOW_IPS = {"127.0.0.1", "::1", "10.10.2.20", "10.10.2.4"}   # 監控電腦本機、空調監控主機
ALLOW_FILE = os.path.join(HERE, "allow_ips.txt")   # 另外允許的 IP 或網段（每行一個，例如 Tailscale 手機 100.101.102.103）


def load_allow_nets():
    import ipaddress
    nets = []
    try:
        with open(ALLOW_FILE, encoding="utf-8-sig") as f:
            for line in f:
                t = line.split("#", 1)[0].strip()
                if t:
                    try:
                        nets.append(ipaddress.ip_network(t, strict=False))
                    except ValueError:
                        pass
    except OSError:
        pass
    return nets


ALLOW_NETS = load_allow_nets()


def allowed(ip):
    if ip in ALLOW_IPS:
        return True
    import ipaddress
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(a in n for n in ALLOW_NETS)
AC_TREND_KEYS = ["mag_c1_pct", "mag_c2_pct", "mag_c1_kw", "mag_c2_kw", "ice01_pct", "ice02_pct",
                 "mag_chws_c", "mag_chwr_c", "flow_m3h", "mag_limit_pct", "chws_target"]


def log(msg):
    line = f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ---------------- 契約容量（台電高壓三段式，112 年制） ----------------
CONTRACT = {"尖峰": 452, "半尖峰": 516, "離峰": 616}


def tou_period(t):
    """回傳時段名稱。國定假日未列入（當作平日），週日全日離峰。"""
    summer = (t.month, t.day) >= (5, 16) and (t.month, t.day) <= (10, 15)
    h, wd = t.hour, t.weekday()
    if wd == 6:
        return "離峰"
    if wd == 5:
        if summer:
            return "半尖峰" if h >= 9 else "離峰"
        return "半尖峰" if (6 <= h < 11 or h >= 14) else "離峰"
    if summer:
        if 16 <= h < 22:
            return "尖峰"
        return "半尖峰" if h >= 9 else "離峰"
    return "半尖峰" if (6 <= h < 11 or h >= 14) else "離峰"


def contract_limit(t):
    """週六半尖峰與離峰都適用 616。"""
    p = tou_period(t)
    if t.weekday() == 5 and p == "半尖峰":
        return p, CONTRACT["離峰"]
    return p, CONTRACT[p]


# ---------------- 需量計算 ----------------
class Demand:
    def __init__(self):
        self.win_start = None
        self.samples = []                 # 本 15 分鐘時段的 (t, kW 台電基準)
        self.today = {}                   # "HH:MM" -> 15 分鐘平均
        self.day = dt.date.today().isoformat()
        self.trend = deque(maxlen=HISTORY)
        self.last = None
        self.load()

    def load(self):
        try:
            with open(STATE, encoding="utf-8") as f:
                s = json.load(f)
            if s.get("day") == self.day:
                self.today = s.get("today", {})
        except (OSError, ValueError):
            pass

    def save(self):
        try:
            with open(STATE + ".tmp", "w", encoding="utf-8") as f:
                json.dump({"day": self.day, "today": self.today}, f)
            os.replace(STATE + ".tmp", STATE)
        except OSError:
            pass

    @staticmethod
    def window_of(t):
        return t.replace(minute=t.minute - t.minute % 15, second=0, microsecond=0)

    def add(self, t, kw):
        w = self.window_of(t)
        if self.win_start is not None and w != self.win_start and self.samples:
            avg = sum(k for _, k in self.samples) / len(self.samples)
            d = self.win_start.date().isoformat()
            if d != self.day:
                self.day, self.today = d, {}
            self.today[self.win_start.strftime("%H:%M")] = round(avg, 1)
            self.samples = []
            self.save()
        if t.date().isoformat() != self.day:          # 跨日：今天重新累計
            self.day, self.today = t.date().isoformat(), {}
        self.win_start = w
        self.samples.append((t, kw))
        self.trend.append((t.strftime("%H:%M:%S"), round(kw, 1)))
        self.last = (t, kw)

    def snapshot(self, t):
        if not self.samples:
            return None
        avg = sum(k for _, k in self.samples) / len(self.samples)
        elapsed = (t - self.win_start).total_seconds()
        remain = max(0.0, 900 - elapsed)
        cur = self.last[1]
        proj = (avg * elapsed + cur * remain) / 900 if elapsed > 0 else cur
        period, limit = contract_limit(self.win_start)
        peak_at, peak = (max(self.today.items(), key=lambda x: x[1]) if self.today else (None, None))
        return {
            "now_kw": round(cur, 1),
            "window": f"{self.win_start:%H:%M}–{self.win_start + dt.timedelta(minutes=15):%H:%M}",
            "window_avg": round(avg, 1),
            "projected": round(proj, 1),
            "elapsed_s": int(elapsed),
            "period": period,
            "limit": limit,
            "margin": round(limit - proj, 1),
            "today_peak": peak,
            "today_peak_at": peak_at,
            "today": self.today,
        }


# ---------------- 讀資料 ----------------
class Reader:
    def __init__(self):
        self.server = self.conv = None

    def connect(self):
        import win32ui  # noqa: F401  必須先 import，dde 才能用
        import dde
        self.server = dde.CreateServer()
        self.server.Create("LocalLive")
        self.conv = dde.CreateConversation(self.server)
        self.conv.ConnectTo("VIEW", "TAGNAME")

    def main_kw(self):
        for attempt in range(2):
            try:
                if self.conv is None:
                    self.connect()
                return float(self.conv.Request(MAIN_TAG).strip("\x00 \r\n"))
            except Exception as e:
                if attempt:
                    raise
                log(f"DDE 重新連線：{e}")
                try:
                    if self.server:
                        self.server.Destroy()
                except Exception:
                    pass
                self.server = self.conv = None


def read_ac():
    try:
        with open(AC_JSON, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_mag():
    try:
        with open(MAG_JSON, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_guard():
    try:
        with open(GUARD_JSON, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def load_site_json(name):
    """網站資料夾 site\\data\\name（沒有就找本程式旁邊），讀不到回傳 None。"""
    for p in (os.path.join(SITE_DIR, "data", name), os.path.join(HERE, name)):
        try:
            with open(p, encoding="utf-8-sig") as f:
                return json.load(f)
        except (OSError, ValueError):
            continue
    return None


# ---------------- 需量預測（只有這一項來自雲端：預測系統在 GitHub 上每天 17:47 計算） ----------------
FORECAST_URL = "https://raw.githubusercontent.com/tsaitzuchien-star/Smart-Energy-Dashboard/ems-live/live.json"
FORECAST = {"day": None, "data": None, "at": 0.0}


def fetch_forecast():
    """每 15 分鐘抓一次雲端 live.json 裡的 forecast（逐時預測 kW）和太陽能 pv。抓不到就沿用舊的，網站其他部分不受影響。"""
    import subprocess
    import urllib.request
    while True:
        d = None
        try:
            with urllib.request.urlopen(FORECAST_URL, timeout=20) as r:
                d = json.load(r)
        except Exception:
            try:                                   # 公司網路攔 SSL：改用 PowerShell
                ps = ("[Net.ServicePointManager]::SecurityProtocol='Tls12';"
                      f"(Invoke-WebRequest -UseBasicParsing -Uri '{FORECAST_URL}').Content")
                out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, timeout=60,
                                     creationflags=0x08000000 if os.name == "nt" else 0)
                d = json.loads(out.stdout.decode("utf-8", "replace"))
            except Exception as e:
                log(f"抓不到雲端預測：{type(e).__name__}: {e}")
        if d and d.get("forecast"):
            FORECAST.update(day=(d.get("updated") or "")[:10], data=d["forecast"], at=time.time())
        if d and d.get("pv"):                      # 太陽能（T-REC 只有雲端有）：一起帶回來
            FORECAST.update(pv=d["pv"], pv_day=(d["pv"].get("updated") or d.get("updated") or "")[:10])
        time.sleep(900)


# ---------------- 全迴路（本機版總覽與房間資料） ----------------
# 即時前 10 名／夜間異常另外要看的盤進線（不是分路，也不是 "#盤" 總表）
FAST_EXTRA = {"F0_B1P1_ESP_2B1_1_I1_KWH": "@ESP_2B1_1"}   # 冷卻水泵 CWP-7/8
class Circuits:
    """15 分鐘整點讀值（G: 的 Circuit_*.csv＋本程式自己每 15 分鐘補的一列）＋最新一次讀值。"""

    def __init__(self):
        with open(os.path.join(HERE, "circuit_tags.txt"), encoding="utf-8") as f:
            self.tags = [t.strip() for t in f if t.strip()]
        try:
            from circuit_export import find_out_dir
            self.out_dir = find_out_dir()
        except BaseException as e:            # find_out_dir 找不到會 SystemExit
            log(f"找不到 BMS自動匯出 資料夾，只用本程式自己的讀值：{e}")
            self.out_dir = None
        self.csv_rows = {}                    # 檔名 -> (mtime, rows)
        self.own = {}                         # 15 分鐘時段 -> (實際讀取時間, 讀值)（本程式自己讀的）
        self.month_first = {}                 # "YYYY-MM" -> 本月第一列讀值
        self.day_first = {}                   # Circuit 檔路徑 -> 第一列 (時間, 讀值)
        self.live = None                      # (時間, 讀值)
        self.recent = deque(maxlen=20)        # 最近 20 次（每分鐘）讀值，算滾動 15 分鐘 kW

    def read(self, conv, now):
        vals = {}
        for tag in self.tags:
            try:
                vals[tag] = float(conv.Request(tag).strip("\x00 \r\n"))
            except Exception:
                pass
        if len(vals) < len(self.tags) * 0.5:
            raise RuntimeError(f"全迴路只讀到 {len(vals)}/{len(self.tags)}")
        self.live = (now, vals)
        self.recent.append((now, vals))
        slot = now.replace(minute=now.minute - now.minute % 15, second=0, microsecond=0)
        if now - slot <= dt.timedelta(minutes=3) and slot not in self.own:
            self.own[slot] = (now, vals)      # 用實際讀取時間，算 kW 時分鐘數才準
        for k in [k for k in self.own if k < now - dt.timedelta(days=2)]:
            del self.own[k]

    def _csv(self, day):
        if not self.out_dir:
            return []
        path = os.path.join(self.out_dir, f"Circuit_{day:%Y-%m-%d}.csv")
        try:
            mt = os.path.getmtime(path)
        except OSError:
            return []
        hit = self.csv_rows.get(path)
        if hit and hit[0] == mt:
            return hit[1]
        with open(path, encoding="utf-8-sig") as f:
            rows = ems_calc.parse_wide(f.read())
        self.csv_rows = {p: v for p, v in self.csv_rows.items()
                         if os.path.basename(p) >= f"Circuit_{day - dt.timedelta(days=1):%Y-%m-%d}.csv"}
        self.csv_rows[path] = (mt, rows)
        return rows

    def _month_first(self, now):
        key = f"{now:%Y-%m}"
        if key in self.month_first:
            return self.month_first[key]
        first = None
        if self.out_dir:
            names = sorted(n for n in os.listdir(self.out_dir) if n.startswith(f"Circuit_{key}-") and n.endswith(".csv"))
            for n in names:
                with open(os.path.join(self.out_dir, n), encoding="utf-8-sig") as f:
                    head = f.readline() + f.readline()
                rows = ems_calc.parse_wide(head)
                if rows:
                    first = rows[0][1]
                    break
        if first is None:
            return None                       # 下次再找（例如月初 G: 還沒有檔）
        self.month_first[key] = first
        return first

    def month_daily(self, now, known=None):
        """本月每天總表 kWh：known（雲端歷史補的）優先，其餘用每天 Circuit 檔第一列的累積度數相減，今天用即時讀值。"""
        key = f"{now:%Y-%m}"
        firsts = {}
        if self.out_dir:
            for n in sorted(os.listdir(self.out_dir)):
                if not (n.startswith(f"Circuit_{key}-") and n.endswith(".csv")):
                    continue
                day = n[8:18]
                path = os.path.join(self.out_dir, n)
                hit = self.day_first.get(path)
                if hit is None:
                    with open(path, encoding="utf-8-sig") as f:
                        rows = ems_calc.parse_wide(f.readline() + f.readline())
                    hit = rows[0] if rows else None
                    if hit is not None:
                        self.day_first[path] = hit
                if hit and ems_calc.MAIN_KWH in hit[1]:
                    firsts[day] = (hit[0], hit[1][ems_calc.MAIN_KWH])
        out = dict(known or {})
        days = sorted(firsts)
        for i, d in enumerate(days):
            if d in out:
                continue
            t0, v0 = firsts[d]
            if t0.hour > 0 or t0.minute > 20:          # 這天的檔不是從午夜開始（例如 11/5 14:00 才開始），不算
                continue
            if i + 1 < len(days):
                v1 = firsts[days[i + 1]][1]
            elif d == now.date().isoformat() and self.live and ems_calc.MAIN_KWH in self.live[1]:
                v1 = self.live[1][ems_calc.MAIN_KWH]
            else:
                continue
            if 0 <= v1 - v0 < 20000:
                out[d] = round(v1 - v0, 1)
        return out

    def rows(self, now):
        """昨天＋今天的 15 分鐘整點讀值，CSV 優先，缺的用本程式自己讀的補。"""
        merged = dict(self._csv(now.date() - dt.timedelta(days=1)) + self._csv(now.date()))
        for t, v in self.own.values():
            near = any(abs((t - c).total_seconds()) <= 180 for c in merged)
            if t.date() >= now.date() - dt.timedelta(days=1) and not near:
                merged[t] = v
        return sorted(merged.items())

    def build(self, now, ac_rows):
        rows = self.rows(now)
        fc = FORECAST.get("data") if FORECAST.get("day") == now.date().isoformat() else None
        data = ems_calc.build(rows, fc, now)
        data["source"] = "local"
        if self.live and ems_calc.MAIN_KW in self.live[1]:
            data["now_kw"] = round(self.live[1][ems_calc.MAIN_KW], 1)
        data["ac"] = ems_calc.ac_summary(ac_rows, now) if ac_rows else None
        data["pv"] = FORECAST.get("pv") if FORECAST.get("pv_day") == now.date().isoformat() else None
        fcu, fcu_rooms = read_fcu(now)
        data["fcu"] = fcu
        try:                                   # 節電成效、-2.1% 目標、控制程式狀態（2026-11-06）
            today_raw = [(t, kw) for t, kw in ems_calc.intervals(rows) if t.date() == now.date()]
            sbase = load_site_json("savings_baseline.json")
            data["savings"] = ems_calc.savings(today_raw, now, sbase)
            if data["savings"]:
                data["savings"]["weather"] = ems_calc.savings_weather(fcu, sbase)
            tcfg = load_site_json("target.json")
            data["target"] = ems_calc.target_status(self.month_daily(now, (tcfg or {}).get("known_days")), now, tcfg)
            data["mag_ctl"] = read_mag()
            data["fcu_guard"] = read_guard()
        except Exception as e:
            log(f"節電成效計算失敗：{type(e).__name__}: {e}")
        # 房間卡片：kW 用最近 15 分鐘滾動（今天最後一列換成即時讀值，前一列換成約 15 分鐘前的讀值）
        room_rows = rows
        if self.live:
            t_live = self.live[0]
            ago = [r for r in self.recent if dt.timedelta(minutes=10) <= t_live - r[0] <= dt.timedelta(minutes=20)]
            keep = {t: v for t, v in rows if t < t_live - dt.timedelta(minutes=10)}
            if ago:
                keep[ago[-1][0]] = ago[-1][1]
            keep[t_live] = self.live[1]
            room_rows = sorted(keep.items())
        rooms = {"updated": (self.live[0] if self.live else now).strftime("%Y-%m-%d %H:%M"), "fcu": fcu_rooms,
                 "circuits": ems_calc.circuit_stats(room_rows, self._month_first(now)), "fast": self.fast_kw()}
        return data, rooms

    def fast_kw(self):
        """即時前 10 名用：各迴路最近約 5 分鐘平均 kW（每分鐘更新）。分路電表每格 0.1 度，5 分鐘約 ±1.2 kW。"""
        if not self.live:
            return None
        t1, v1 = self.live
        prev = [r for r in self.recent if dt.timedelta(minutes=4) <= t1 - r[0] <= dt.timedelta(minutes=8)]
        if not prev:
            return None
        t0, v0 = min(prev, key=lambda r: abs((t1 - r[0]).total_seconds() - 300))
        mins = (t1 - t0).total_seconds() / 60
        kw = {}
        for tag, b in v1.items():
            key = FAST_EXTRA.get(tag) or ems_calc.circuit_key(tag)
            if key:
                x = ems_calc.kw_between(v0.get(tag), b, mins)
                if x:
                    kw[key] = round(x, 2)
        return {"from": t0.strftime("%H:%M"), "to": t1.strftime("%H:%M"), "min": round(mins, 1), "kw": kw}


def read_ac_rows(now):
    texts = []
    for d in (now.date() - dt.timedelta(days=1), now.date()):
        try:
            with open(os.path.join(AC_SHARE, f"AC_{d:%Y-%m-%d}.csv"), encoding="utf-8-sig") as f:
                texts.append(f.read())
        except OSError:
            pass
    return ems_calc.parse_ac(texts)


FCU_MAP = None
FCU_CACHE = {}                           # 檔名 -> (mtime, rows)


def read_fcu(now):
    """空調監控主機每 5 分鐘的外氣溫溼度與小型送風機（FCU_*.csv）→ (總覽, 各房間)。"""
    global FCU_MAP
    try:
        if FCU_MAP is None:
            FCU_MAP = ems_calc.load_fcu_map(os.path.join(HERE, "fcu_map.json"))
        rows = []
        for d in (now.date() - dt.timedelta(days=1), now.date()):
            path = os.path.join(AC_SHARE, f"FCU_{d:%Y-%m-%d}.csv")
            try:
                mt = os.path.getmtime(path)
            except OSError:
                continue
            hit = FCU_CACHE.get(path)
            if not hit or hit[0] != mt:
                with open(path, encoding="utf-8-sig") as f:
                    hit = (mt, ems_calc.parse_fcu([f.read()]))
                FCU_CACHE[path] = hit
            rows += hit[1]
        for p in [p for p in FCU_CACHE if os.path.basename(p) < f"FCU_{now.date() - dt.timedelta(days=1):%Y-%m-%d}.csv"]:
            del FCU_CACHE[p]
        return ems_calc.fcu_summary(rows, FCU_MAP, now)
    except Exception as e:
        log(f"送風機資料讀取失敗：{type(e).__name__}: {e}")
        return None, {}


# ---------------- 網頁 ----------------
STATE_LOCK = threading.Lock()
LIVE = {"ok": False, "error": "啟動中"}
EMS = {"live": None, "rooms": None}         # 本機算的 live.json、rooms.json（bytes）
CIRC = {"obj": None}                        # 全迴路讀值（給 /api/ems/panel 迴路測試頁用）


def _incomer_panel(tag):
    """F2_B2P1_L2C_I1_KWH → "L2C"；不是盤總表（I1）就回 None。"""
    m = re.match(r"^F\d_(?:G_P1|[A-Z]\dP\d)_(.+?)_I1_KWH$", tag)
    return m.group(1).upper() if m else None


def panel_readings(panel, since=None):
    """迴路測試頁用：某一個盤最近約 20 分鐘、每分鐘的各迴路累積度數。panel 用網站寫法（L4C、R4C_1、EP3D_1_B）。

    "I" 是盤總表（0.01 度精度，比分路的 0.1 度準很多）；bg 是測試前 2 小時各迴路平常的 kW，
    用來扣掉「本來就會跳」的背景用電，避免把每 30 分鐘跳一次 0.1 度的迴路誤判成測試負載。
    since＝按「開始測試」的時間：平常用電一律算到這個時間點為止，測試中不會越算越高。
    base_kw＝測試前 2 小時盤總表每 15 分鐘 kW 裡「第二低」的那一段，不會被前一次測試（吹風機）墊高。
    """
    c = CIRC["obj"]
    if not c or not c.recent:
        return None
    want = panel.replace("-", "_").upper()

    def pick(vals, panels=None):
        row = {}
        for tag, v in vals.items():
            ip = _incomer_panel(tag)
            if ip:
                if ip == want:
                    row["I"] = v
                continue
            key = ems_calc.circuit_key(tag)
            if not key or key.startswith("#"):
                continue
            p, _, n = key.rpartition("_")
            if panels is not None:
                panels.add(p)
            if p.upper() == want:
                row[n] = v
        return row

    rows, panels = [], set()
    for t, vals in list(c.recent):
        rows.append([t.strftime("%Y-%m-%d %H:%M:%S"), pick(vals, panels)])
    bg, base_kw = {}, None
    try:
        t_now = c.recent[-1][0]
        t_ref = t_now
        if since:
            try:
                t_ref = min(t_now, dt.datetime.strptime(since, "%Y-%m-%d %H:%M:%S"))
            except ValueError:
                pass
        hist = [(t, pick(v)) for t, v in c.rows(t_now)
                if t_ref - dt.timedelta(minutes=135) <= t <= t_ref - dt.timedelta(minutes=5)]
        if len(hist) >= 2:
            (t0, a), (t1, b) = hist[0], hist[-1]
            hrs = (t1 - t0).total_seconds() / 3600
            if hrs >= 1:
                bg = {k: round((b[k] - a[k]) / hrs, 3) for k in b
                      if k != "I" and k in a and 0 <= b[k] - a[k] < 1000}
            seg = []
            for (ta, va), (tb, vb) in zip(hist, hist[1:]):
                m = (tb - ta).total_seconds() / 60
                if 5 <= m <= 30 and "I" in va and "I" in vb and 0 <= vb["I"] - va["I"] < 1000:
                    seg.append((vb["I"] - va["I"]) / m * 60)
            if seg:
                seg.sort()
                base_kw = round(seg[1] if len(seg) >= 3 else seg[0], 3)
    except Exception as e:                    # 背景用電算不出來不影響測試頁
        log(f"迴路測試頁背景用電計算失敗：{e}")
    return {"panel": want, "rows": rows, "panels": sorted(panels), "bg": bg, "base_kw": base_kw}


TESTLOG_LOCK = threading.Lock()
TESTLOG_NAME = "迴路測試登記.csv"           # 存在 BMS自動匯出（會同步到雲端硬碟），事後用 15 分鐘讀值判斷


def testlog_path():
    c = CIRC["obj"]
    d = (c.out_dir if c and c.out_dir else None) or HERE
    return os.path.join(d, TESTLOG_NAME)


def _clean(v, n):
    return re.sub(r"[\r\n\t]", " ", str(v or "")).strip()[:n]


def testlog_add(data):
    """「插了就走」登記：同仁在現場按一下，記下伺服器時間、動作、房間。只追加，不改舊資料。"""
    import csv
    act = data.get("action")
    tid = str(data.get("id") or "")
    if act not in ("start", "stop") or not re.fullmatch(r"[0-9A-Za-z_-]{1,40}", tid):
        return None
    room, note, who = _clean(data.get("room"), 40), _clean(data.get("note"), 80), _clean(data.get("who"), 20)
    if act == "start" and not room:
        return None
    row = [dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), act, tid, room, note, who]
    path = testlog_path()
    with TESTLOG_LOCK:
        if os.path.exists(path) and os.path.getsize(path) > 5_000_000:
            return None
        new = not os.path.exists(path)
        with open(path, "a", newline="", encoding="utf-8-sig" if new else "utf-8") as f:
            w = csv.writer(f)
            if new:
                w.writerow(["時間", "動作", "編號", "房間或位置", "備註", "登記人"])
            w.writerow(row)
    return row


def testlog_recent(days=2):
    import csv
    path = testlog_path()
    if not os.path.exists(path):
        return []
    cut = (dt.datetime.now() - dt.timedelta(days=days)).strftime("%Y-%m-%d")
    with TESTLOG_LOCK, open(path, encoding="utf-8-sig") as f:
        rows = [r for r in csv.reader(f)][1:]
    return [r for r in rows if len(r) >= 6 and r[0] >= cut]


LOCAL_FLAG = b"<script>window.EMS_LOCAL=true</script>"


CTYPES = {".html": "text/html; charset=utf-8", ".json": "application/json; charset=utf-8",
          ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8"}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        ip = self.client_address[0]
        if ip.startswith("::ffff:"):
            ip = ip[7:]
        if not allowed(ip):
            self.send_error(403, "Only the monitoring PC and AC PC may view this site")
            return
        path = self.path.split("?", 1)[0]
        if path.startswith("/api/live"):
            with STATE_LOCK:
                body = json.dumps(LIVE, ensure_ascii=False).encode("utf-8")
            ctype = CTYPES[".json"]
        elif path == "/api/ems/panel":
            from urllib.parse import parse_qs
            q = parse_qs(self.path.split("?", 1)[1] if "?" in self.path else "")
            data = panel_readings((q.get("p") or [""])[0], (q.get("since") or [None])[0])
            if data is None:
                self.send_error(503, "Circuit data not ready yet")
                return
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            ctype = CTYPES[".json"]
        elif path == "/api/ems/testlog":
            body = json.dumps(testlog_recent(), ensure_ascii=False).encode("utf-8")
            ctype = CTYPES[".json"]
        elif path in ("/api/ems/live.json", "/api/ems/rooms.json"):
            with STATE_LOCK:
                body = EMS["live" if path.endswith("live.json") else "rooms"]
            if body is None:
                self.send_error(503, "Circuit data not ready yet")
                return
            ctype = CTYPES[".json"]
        elif path == "/live" or (path in ("/", "/index.html") and not os.path.exists(os.path.join(SITE_DIR, "index.html"))):
            body = PAGE.encode("utf-8")
            ctype = CTYPES[".html"]
        else:
            rel = "index.html" if path in ("/", "") else path.lstrip("/")
            full = os.path.normpath(os.path.join(SITE_DIR, rel))
            if not full.startswith(os.path.normpath(SITE_DIR) + os.sep) or not os.path.isfile(full):
                self.send_error(404)
                return
            with open(full, "rb") as f:
                body = f.read()
            if full.endswith(os.sep + "index.html") and os.path.dirname(full) == os.path.normpath(SITE_DIR):
                body = body.replace(b"</head>", LOCAL_FLAG + b"</head>", 1)
            ctype = CTYPES.get(os.path.splitext(full)[1].lower(), "application/octet-stream")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        ip = self.client_address[0]
        if ip.startswith("::ffff:"):
            ip = ip[7:]
        if not allowed(ip):
            self.send_error(403, "Only the monitoring PC and AC PC may view this site")
            return
        if self.path.split("?", 1)[0] != "/api/ems/testlog":
            self.send_error(404)
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            data = json.loads(self.rfile.read(min(n, 4096)).decode("utf-8")) if 0 < n <= 4096 else None
            row = testlog_add(data) if isinstance(data, dict) else None
        except Exception as e:
            log(f"迴路測試登記失敗：{e}")
            row = None
        if row is None:
            self.send_error(400, "Bad test log entry")
            return
        body = json.dumps(row, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", CTYPES[".json"])
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


PAGE = r"""<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>中創園區 即時用電（本機）</title>
<style>
:root{--bg:#0f172a;--card:#1e293b;--line:#334155;--t:#e2e8f0;--m:#94a3b8;--ok:#34d399;--warn:#fbbf24;--bad:#f87171;--acc:#38bdf8}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--t);font-family:"Microsoft JhengHei","Noto Sans TC",sans-serif}
header{padding:14px 16px;border-bottom:1px solid var(--line);display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:8px}
h1{font-size:20px;margin:0}.m{color:var(--m);font-size:13px}
main{padding:16px;display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(230px,1fr))}
.c{background:var(--card);border-radius:12px;padding:14px 16px;border-left:4px solid var(--acc)}
.c .l{color:var(--m);font-size:13px}.c .v{font-size:38px;font-weight:700;font-variant-numeric:tabular-nums;margin:4px 0}
.c .v small{font-size:16px;color:var(--m);font-weight:400;margin-left:4px}.wide{grid-column:1/-1}
.bar{height:10px;background:var(--line);border-radius:5px;overflow:hidden;margin-top:8px}.bar i{display:block;height:100%}
.row{display:flex;justify-content:space-between;gap:12px;padding:4px 0;font-size:15px}.row span{white-space:nowrap}.row b{text-align:right}.row b{font-variant-numeric:tabular-nums}
canvas{width:100%;height:240px;display:block}
.ok{border-left-color:var(--ok)}.warn{border-left-color:var(--warn)}.bad{border-left-color:var(--bad)}
.err{color:var(--bad)}@media(min-width:700px){#cAc{grid-column:span 2}}
</style></head><body>
<header><h1>中創園區 即時用電</h1><span class="m" id="upd">連線中…</span></header>
<main>
 <div class="c" id="cNow"><div class="l">總電表瞬時（台電基準）</div><div class="v" id="now">—</div><div class="m" id="nowSub"></div></div>
 <div class="c" id="cProj"><div class="l">本時段 15 分鐘需量推估</div><div class="v" id="proj">—</div><div class="m" id="projSub"></div><div class="bar"><i id="projBar"></i></div></div>
 <div class="c" id="cMargin"><div class="l">距契約容量</div><div class="v" id="margin">—</div><div class="m" id="marginSub"></div></div>
 <div class="c"><div class="l">今日最高 15 分鐘需量</div><div class="v" id="peak">—</div><div class="m" id="peakSub"></div></div>
 <div class="c wide"><div class="l">最近 2 小時瞬時 kW（虛線＝目前契約容量，橘線＝90%）</div><canvas id="chart"></canvas></div>
 <div class="c" id="cAc"><div class="l" id="acT">空調中央監控</div>
  <div class="row"><span>磁浮 CHU-2 負載</span><b id="mag">—</b></div>
  <div class="row"><span>磁浮功率</span><b id="magkw">—</b></div>
  <div class="row"><span>冰桶液位 01／02</span><b id="ice">—</b></div>
  <div class="row"><span>冰水出／回水</span><b id="chw">—</b></div>
  <div class="row"><span>冰水流量</span><b id="flow">—</b></div></div>
 <div class="c wide"><div class="l">今日各 15 分鐘需量（台電基準）</div><canvas id="bars" style="height:160px"></canvas></div>
</main>
<script>
const $=id=>document.getElementById(id);
const f=(v,d=0)=>v==null?'—':Number(v).toLocaleString('zh-TW',{minimumFractionDigits:d,maximumFractionDigits:d});
function cls(el,r){el.classList.remove('ok','warn','bad');el.classList.add(r>=1?'bad':r>=.9?'warn':'ok')}
function css(n){return getComputedStyle(document.documentElement).getPropertyValue(n).trim()}
function line(cv,pts,limit){const r=devicePixelRatio||1,w=cv.clientWidth,h=cv.clientHeight;cv.width=w*r;cv.height=h*r;const x=cv.getContext('2d');x.scale(r,r);x.clearRect(0,0,w,h);
 if(!pts.length)return;const vs=pts.map(p=>p[1]);const hi=Math.max(limit*1.05,...vs),lo=Math.min(...vs)*0.8;const L=40,B=18;
 const X=i=>L+(w-L-6)*i/Math.max(1,pts.length-1),Y=v=>(h-B)-(h-B-6)*(v-lo)/(hi-lo);
 x.fillStyle=css('--m');x.font='11px sans-serif';for(let k=0;k<=4;k++){const v=lo+(hi-lo)*k/4;x.fillText(Math.round(v),2,Y(v)+4);x.strokeStyle=css('--line');x.beginPath();x.moveTo(L,Y(v));x.lineTo(w,Y(v));x.stroke()}
 [[limit,css('--bad'),[6,4]],[limit*.9,css('--warn'),[3,3]]].forEach(([v,c,d])=>{x.setLineDash(d);x.strokeStyle=c;x.beginPath();x.moveTo(L,Y(v));x.lineTo(w,Y(v));x.stroke()});x.setLineDash([]);
 x.strokeStyle=css('--acc');x.lineWidth=2;x.beginPath();pts.forEach((p,i)=>i?x.lineTo(X(i),Y(p[1])):x.moveTo(X(i),Y(p[1])));x.stroke();
 x.fillStyle=css('--m');[0,Math.floor(pts.length/2),pts.length-1].forEach(i=>x.fillText(pts[i][0].slice(0,5),Math.min(X(i),w-34),h-3))}
function bars(cv,today,limit){const r=devicePixelRatio||1,w=cv.clientWidth,h=cv.clientHeight;cv.width=w*r;cv.height=h*r;const x=cv.getContext('2d');x.scale(r,r);
 const ks=Object.keys(today).sort();if(!ks.length)return;const hi=Math.max(limit,...ks.map(k=>today[k]))*1.05,B=16,bw=(w-30)/96;
 ks.forEach(k=>{const [hh,mm]=k.split(':').map(Number),i=hh*4+mm/15,v=today[k],y=(h-B)*(1-v/hi);x.fillStyle=v>=limit?css('--bad'):v>=limit*.9?css('--warn'):css('--acc');x.fillRect(30+i*bw,y,Math.max(1,bw-1),h-B-y)});
 x.fillStyle=css('--m');x.font='11px sans-serif';[0,6,12,18].forEach(hh=>x.fillText(hh+'時',30+hh*4*bw,h-3))}
async function tick(){try{const d=await (await fetch('/api/live',{cache:'no-store'})).json();
 if(!d.ok){$('upd').innerHTML='<span class="err">'+(d.error||'讀不到資料')+'</span>';return}
 const s=d.demand;$('upd').textContent='更新 '+d.time+'・'+s.period+'時段・契約 '+s.limit+' kW';
 $('now').innerHTML=f(s.now_kw,1)+'<small>kW</small>';$('nowSub').textContent='BMS 讀值 '+f(s.now_kw-d.offset,1)+' kW＋'+d.offset;
 $('proj').innerHTML=f(s.projected,1)+'<small>kW</small>';$('projSub').textContent=s.window+'，已過 '+Math.floor(s.elapsed_s/60)+' 分，目前平均 '+f(s.window_avg,1);
 const r=s.projected/s.limit;$('projBar').style.width=Math.min(100,r*100)+'%';$('projBar').style.background=r>=1?css('--bad'):r>=.9?css('--warn'):css('--ok');cls($('cProj'),r);
 $('margin').innerHTML=f(s.margin,1)+'<small>kW</small>';$('marginSub').textContent=r>=1?'推估會超約，請立即降載磁浮':r>=.9?'接近契約容量（≥90%），準備降載':'安全';cls($('cMargin'),r);cls($('cNow'),s.now_kw/s.limit);
 $('peak').innerHTML=f(s.today_peak,1)+'<small>kW</small>';$('peakSub').textContent=s.today_peak_at?('發生在 '+s.today_peak_at+' 起的 15 分鐘'):'今天還沒有完整時段';
 line($('chart'),d.trend,s.limit);bars($('bars'),s.today,s.limit);
 const a=d.ac;if(a){const L=a;const mp=[L.mag_c1_pct,L.mag_c2_pct].filter(v=>v!=null);const mk=[L.mag_c1_kw,L.mag_c2_kw].filter(v=>v!=null);
  $('acT').textContent='空調中央監控 '+(a.time||'').slice(11,16)+(a.viewer_ok?'':'（空調主機 WindowViewer 沒開）');
  $('mag').textContent=(mp.length?f(mp.reduce((p,q)=>p+q,0)/mp.length,0):'—')+'%（限制 '+f(L.mag_limit_pct,0)+'%）';
  $('magkw').textContent=mk.length?f(mk.reduce((p,q)=>p+q,0),0)+' kW':'—';$('ice').textContent=f(L.ice01_pct,1)+'%／'+f(L.ice02_pct,1)+'%';
  $('chw').textContent=f(L.mag_chws_c,1)+'／'+f(L.mag_chwr_c,1)+' °C';$('flow').textContent=f(L.flow_m3h,0)+' m³/h'}
 else $('acT').textContent='空調中央監控（讀不到空調主機）';
}catch(e){$('upd').innerHTML='<span class="err">連不到監控電腦</span>'}}
tick();setInterval(tick,5000);addEventListener('resize',tick);
</script></body></html>"""


def main():
    test = "--test" in sys.argv
    reader, dem = Reader(), Demand()
    if test:
        kw = reader.main_kw()
        ac = read_ac()
        now = dt.datetime.now()
        print(f"總電表 BMS {kw:.1f} kW（台電基準 {kw + TAIPOWER_OFFSET:.1f}）")
        print(f"時段 {contract_limit(now)}")
        print(f"空調：{json.dumps(ac, ensure_ascii=False)[:300] if ac else '讀不到 ' + AC_JSON}")
        circ = Circuits()
        t0 = time.time()
        circ.read(reader.conv, now)
        print(f"全迴路讀到 {len(circ.live[1])}/{len(circ.tags)} 個，耗時 {time.time() - t0:.1f} 秒；"
              f"歷史資料夾 {circ.out_dir}")
        t0 = time.time()
        data, rooms = circ.build(now, read_ac_rows(now))
        print(f"本機計算 {time.time() - t0:.1f} 秒：15 分鐘區間 {len(data['times'])} 個，最近 {data['last15_kw']} kW，"
              f"今日最高 {data['today_peak_kw']} kW @ {data['today_peak_at']}，迴路 {len(rooms['circuits'])} 個，"
              f"空調 {'有' if data['ac'] else '無'}")
        print(f"網站檔案：{'有' if os.path.exists(os.path.join(SITE_DIR, 'index.html')) else '沒有'} {SITE_DIR}\\index.html")
        return

    # 2026-11-13：Windows 上 allow_reuse_address（SO_REUSEADDR）會讓新程式和殘留的舊程式同時綁在 8088，
    # 新程式顯示「啟動」但連線被送去卡住的舊程式。關掉它：連接埠被佔用就寫 log 並結束，不會假裝啟動成功。
    ThreadingHTTPServer.allow_reuse_address = False
    try:
        httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    except OSError as e:
        log(f"❗ 連接埠 {PORT} 被佔用（舊的 local_live 還在跑？），本次不啟動：{e}")
        sys.exit(1)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    threading.Thread(target=fetch_forecast, daemon=True).start()
    log(f"本機即時網站啟動：http://localhost:{PORT}/")
    ac, ac_at, mag = None, 0.0, None
    notifier, ems_data = line_push.Notifier(), None
    log("LINE 推播：" + ("已啟用" if notifier.enabled else "未設定（沒有 line_token.txt）"))
    circ, circ_at = Circuits(), 0.0
    CIRC["obj"] = circ
    ac_trend = deque(maxlen=720)          # 每分鐘一點，保留 12 小時
    while True:
        t0 = time.time()
        now = dt.datetime.now()
        try:
            kw = reader.main_kw() + TAIPOWER_OFFSET
            dem.add(now, kw)
            if t0 - ac_at > 30:
                ac, ac_at, mag = read_ac(), t0, read_mag()
                if ac and ac.get("viewer_ok") and (not ac_trend or ac_trend[-1][0] != ac.get("time", "")[11:16]):
                    src = dict(ac, chws_target=(mag or {}).get("chws_target"))
                    ac_trend.append([ac.get("time", "")[11:16]] + [src.get(k) for k in AC_TREND_KEYS])
            if t0 - circ_at >= CIRCUIT_S:
                circ_at = t0
                try:
                    circ.read(reader.conv, now)
                    data, rooms = circ.build(now, read_ac_rows(now))
                    ems_data = data
                    # 本程式啟動前的時段用全迴路總表度數補（總表 kWh 與台電同基準）
                    if dem.day == now.date().isoformat():
                        for hm, v in zip(data["times"], data["total"]):
                            if v is not None:
                                dem.today.setdefault(hm, v)
                    with STATE_LOCK:
                        EMS["live"] = json.dumps(data, ensure_ascii=False).encode("utf-8")
                        EMS["rooms"] = json.dumps(rooms, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                except Exception as e:
                    log(f"全迴路計算失敗：{type(e).__name__}: {e}")
            snap = dem.snapshot(now)
            with STATE_LOCK:
                LIVE.clear()
                LIVE.update({"ok": True, "time": now.strftime("%H:%M:%S"), "offset": TAIPOWER_OFFSET,
                             "demand": snap, "trend": list(dem.trend), "ac": ac, "mag": mag,
                             "ac_trend_keys": AC_TREND_KEYS, "ac_trend": list(ac_trend)})
            notifier.tick(now, True, snap, ac, mag, ems_data)
        except Exception as e:
            with STATE_LOCK:
                LIVE.clear()
                LIVE.update({"ok": False, "error": f"讀不到 InTouch（WindowViewer 有開嗎？）{type(e).__name__}"})
            notifier.tick(now, False, None, ac, mag, ems_data)
            log(f"讀取失敗：{type(e).__name__}: {e}")
            time.sleep(25)
        time.sleep(max(0.5, SAMPLE_S - (time.time() - t0)))


if __name__ == "__main__":
    main()
