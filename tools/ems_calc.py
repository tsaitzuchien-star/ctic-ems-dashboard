"""（本檔由 Smart-Energy-Dashboard/build_ems_live.py 複製計算部分，給監控電腦本機網站 local_live.py 用；
改計算邏輯時兩邊要一起改。）

把監控電腦每 15 分鐘匯出的全園區度數（BMS自動匯出/Circuit_YYYY-MM-DD.csv）整理成
ctic-ems-dashboard 網站用的公開總覽 live.json。

live.json 是園區層級的彙總（總需量、各樓層、各用途、空調主機房設備）；
rooms.json 是各分路的 [最近15分kW, 今日kWh, 本月kWh, 夜間基載kW, 上班平均kW]，給網站的房間卡片用（依園區決定公開，不加密）。

來源檔：circuit_export.py 每列一個時間點、每欄一個 InTouch 累積度數標籤（kWh）。
兩列相減 ÷ 分鐘數 × 60 ＝ 該時段平均 kW。
"""
import csv
import io
import json
import os
import re
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta



# ---- 台電高壓三段式（同 forecast.py；契約：尖峰 452／半尖峰 516／週六半尖峰與離峰 616） ----
def _is_summer(d):
    return (5, 16) <= (d.month, d.day) <= (10, 15)


def tou_period(d, hour):
    wd = d.weekday()
    if wd == 6:
        return "離峰"
    if _is_summer(d):
        if wd == 5:
            return "週六半尖峰" if hour >= 9 else "離峰"
        if 16 <= hour < 22:
            return "尖峰"
        return "半尖峰" if hour >= 9 else "離峰"
    in_day = 6 <= hour < 11 or hour >= 14
    if wd == 5:
        return "週六半尖峰" if in_day else "離峰"
    return "半尖峰" if in_day else "離峰"


_PERIOD_LIMIT = {"尖峰": 452, "半尖峰": 516, "週六半尖峰": 616, "離峰": 616}

SHEET_ID = "1NZ0OPky-I-oWXfFTeVR8qpFT1pFBwQvRoSerJYJJMwY"
COMPARE_TAB = "預測與實測比對"
MAIN_KW = "F0_B2P2_MCB_KW_PV"        # 總表即時 kW（BMS 畫面那顆）
MAIN_KWH = "F0_B2P2_MCB_KWH"         # 總表累積度數（＝DataLogger KmTagx020，比 BMS 即時值高約 10 kW）
PLANT_FEEDER = "F0_B2P2_ACB2_1_KWH"  # 低壓總盤到空調主機房的饋線（＝EACMP_1＋ACMP_2＋ACMP_G1）
METER_OFFSET_KW = 10.0               # 預測模型以 BMS 為準，顯示時加回，與總表、台電同基準

# 空調主機房（B1 B1P2 盤）設備：只列實際設備，不列上層彙總（ACMP_1、ACMP_B…），避免重複
PLANT = {
    "ACMP_A_CHU1": "冰水主機 CHU-1",
    "EACMP_1_CHU2": "冰水主機 CHU-2",
    "ACMP_B_BCU1": "滷水主機 BCU-1（儲冰）",
    "ACMP_1_CHP1": "冰水泵 CHP-1", "ACMP_1_CHP2": "冰水泵 CHP-2",
    "EACMP_1_CHP3": "冰水泵 CHP-3", "EACMP_1_CHP4": "冰水泵 CHP-4",
    "ACMP_1_CWP1": "冷卻水泵 CWP-1", "ACMP_1_CWP2": "冷卻水泵 CWP-2",
    "EACMP_1_CWP3": "冷卻水泵 CWP-3", "EACMP_1_CWP4": "冷卻水泵 CWP-4",
    "ACMP_B_CWP5": "冷卻水泵 CWP-5", "ACMP_B_CWP6": "冷卻水泵 CWP-6",
    "ACMP_B_BP1": "滷水泵 BP-1", "ACMP_B_BP2": "滷水泵 BP-2",
    "ACMP_1_BP5": "滷水泵 BP-5", "ACMP_1_BP6": "滷水泵 BP-6",
}
FLOOR_NAME = {"F0": "B1", "F1": "1F", "F2": "2F", "F3": "3F", "F4": "4F"}
CIRCUIT_RE = re.compile(r"^(F\d)_([A-Z0-9]+)_(.+?)_B\d+_KWH_\d+$")
PANEL_IN_RE = re.compile(r"^(F[1-4])_([A-Z]\dP1|G_P1)_(.+?)_I1_KWH$")   # 1–4F 各盤進線電表


def category(panel):
    """盤名 → 用途。E 開頭是緊急電源盤，用途同去掉 E 的盤。"""
    p = panel[1:] if panel.startswith("E") and not panel.startswith("EACMP") else panel
    if p.startswith("LPV") or p.startswith("MLPV"):
        return "其他"
    if p.startswith("L"):
        return "照明"
    if p.startswith("R"):
        return "插座"
    if p.startswith("SP"):
        return "空調箱"
    if p.startswith("P"):
        return "動力"
    return "其他"


# ---------------- 讀檔與計算 ----------------
def parse_wide(text):
    """Circuit CSV → [(datetime, {tag: kWh})]，空值略過。"""
    rows = []
    reader = csv.reader(io.StringIO(text.lstrip("﻿")))
    head = next(reader, None)
    if not head:
        return rows
    for r in reader:
        try:
            ts = datetime.strptime(r[0][:19], "%Y/%m/%d %H:%M:%S")
        except (ValueError, IndexError):
            continue
        vals = {}
        for tag, v in zip(head[1:], r[1:]):
            if v:
                try:
                    vals[tag] = float(v)
                except ValueError:
                    pass
        rows.append((ts, vals))
    rows.sort(key=lambda x: x[0])
    return rows


def kw_between(a, b, mins, max_kw=2000):
    """兩個累積讀值 → 平均 kW；倒退、跳表或超過上限回傳 None。"""
    if a is None or b is None:
        return None
    kw = (b - a) / mins * 60
    if kw < -0.05 or kw > max_kw:
        return None
    return max(kw, 0.0)


def intervals(rows):
    """相鄰兩列 → [(區間起點, {tag: kW})]，只收 10–20 分鐘間隔。"""
    out = []
    for (t0, v0), (t1, v1) in zip(rows, rows[1:]):
        mins = (t1 - t0).total_seconds() / 60
        if not 10 <= mins <= 20:
            continue
        out.append((t0, {k: kw for k in v1 if (kw := kw_between(v0.get(k), v1[k], mins)) is not None}))
    return out


def aggregate(kw):
    """單一時段各標籤 kW → 彙總。"""
    floors, cats, plant = defaultdict(float), defaultdict(float), {}
    for tag, v in kw.items():
        m = PANEL_IN_RE.match(tag)
        if m:
            floors[FLOOR_NAME[m.group(1)]] += v
            cats[category(m.group(3))] += v
            continue
        m = CIRCUIT_RE.match(tag)
        if m and m.group(1) == "F0":           # B1 沒有進線電表，用各分路加總
            floors["B1"] += v
            cats[category(m.group(3))] += v
    for key, name in PLANT.items():
        tag = f"F0_B1P2_{key}_KWH"
        if tag in kw:
            plant[name] = kw[tag]
    total = kw.get(MAIN_KWH)
    feeders = {}
    if total is not None and PLANT_FEEDER in kw:
        feeders = {"空調主機房": kw[PLANT_FEEDER], "其他用電": max(total - kw[PLANT_FEEDER], 0.0)}
    return {"total": total, "floors": dict(floors), "cats": dict(cats), "plant": plant, "feeders": feeders}


# ---------------- 儲冰與磁浮運轉（由迴路功率判斷） ----------------
BCU_TAG = "F0_B1P2_ACMP_B_BCU1_KWH"    # 滷水主機 BCU-1：製冰約 240 kW，待機只有零點幾 kW
MAG_TAG = "F0_B1P2_EACMP_1_CHU2_KWH"   # 磁浮冰水主機 CHU-2（240 RT）
ICE_ON_KW = 30.0                       # BCU-1 超過這個值算「製冰中」
MAG_ON_KW = 5.0                        # CHU-2 超過這個值算「運轉中」


def ice_runs(iv, tag=BCU_TAG, on_kw=ICE_ON_KW):
    """連續超過 on_kw 的 15 分鐘區間合併成一次製冰 → [{start, end, hours, kwh, avg_kw}]。
    跨午夜的整晚製冰算同一次；中間斷超過 20 分鐘就分開。"""
    runs, cur = [], None
    for t, kw in iv:
        v = kw.get(tag)
        if v is not None and v > on_kw:
            end = t + timedelta(minutes=15)
            if cur and t - cur["end"] <= timedelta(minutes=20):
                cur["end"], cur["kwh"] = end, cur["kwh"] + v / 4
            else:
                cur = {"start": t, "end": end, "kwh": v / 4}
                runs.append(cur)
    out = []
    for r in runs:
        h = (r["end"] - r["start"]).total_seconds() / 3600
        out.append({"start": r["start"].strftime("%m/%d %H:%M"), "end": r["end"].strftime("%m/%d %H:%M"),
                    "hours": round(h, 2), "kwh": round(r["kwh"], 1), "avg_kw": round(r["kwh"] / h, 1)})
    return out


def mag_today(iv, tag=MAG_TAG, on_kw=MAG_ON_KW):
    """今天磁浮 {kwh, max_kw, run_hours}；沒有讀值回傳 None。"""
    vals = [kw[tag] for _, kw in iv if tag in kw]
    if not vals:
        return None
    return {"kwh": round(sum(vals) / 4, 1), "max_kw": round(max(vals), 1),
            "run_hours": round(sum(1 for v in vals if v > on_kw) / 4, 2)}


def build(rows, forecast=None, now=None):
    now = now or datetime.utcnow() + timedelta(hours=8)
    today = now.date()
    raw_iv = intervals(rows)
    today_raw = [(t, kw) for t, kw in raw_iv if t.date() == today]
    iv = [(t, aggregate(kw)) for t, kw in today_raw]
    last_t, last_v = rows[-1] if rows else (None, {})
    hour = (last_t or now).hour
    period = tou_period(today, hour)
    limit = _PERIOD_LIMIT[period]
    latest = iv[-1][1] if iv else {"total": None, "floors": {}, "cats": {}, "plant": {}, "feeders": {}}
    totals = [a["total"] for _, a in iv if a["total"] is not None]
    peak = max(((a["total"], t) for t, a in iv if a["total"] is not None), default=(None, None))

    def series(key):
        names = sorted({n for _, a in iv for n in a[key]})
        return {n: [round(a[key].get(n, 0.0), 1) for _, a in iv] for n in names}

    return {
        "updated": (last_t or now).strftime("%Y-%m-%d %H:%M"),
        "generated": now.strftime("%Y-%m-%d %H:%M"),
        "now_kw": round(last_v[MAIN_KW], 1) if MAIN_KW in last_v else None,
        "last15_kw": round(latest["total"], 1) if latest["total"] is not None else None,
        "period": period,
        "limit_kw": limit,
        "today_peak_kw": round(peak[0], 1) if peak[0] is not None else None,
        "today_peak_at": peak[1].strftime("%H:%M") if peak[1] else None,
        "today_kwh": round(sum(totals) / 4, 0) if totals else None,
        "times": [t.strftime("%H:%M") for t, _ in iv],
        "total": [round(a["total"], 1) if a["total"] is not None else None for _, a in iv],
        "floors": series("floors"),
        "cats": series("cats"),
        "feeders": series("feeders"),
        "plant_now": {k: round(v, 1) for k, v in sorted(latest["plant"].items(), key=lambda x: -x[1])},
        "plant": series("plant"),
        "ice_runs": ice_runs(raw_iv),
        "mag_today": mag_today(today_raw),
        "forecast": forecast or {},
        "limits": {p: v for p, v in _PERIOD_LIMIT.items()},
    }


# ---------------- 各迴路（給房間卡片） ----------------
CIRCUIT_KEY_RE = re.compile(r"^F\d_(?:G_P1|[A-Z]\dP\d)_(.+?)_B\d+_KWH_(\d+)$")
P2_CIRCUIT_RE = re.compile(r"^F\d_[A-Z]\dP2_(.+?)_KWH_(\d+)$")       # 少數 P2 盤沒有 _B1_，例如 F0_B2P2_PB1B_KWH_1
P2_TOTAL_RE = re.compile(r"^F\d_[A-Z]\dP2_(.+?)_KWH$")                  # P2 的盤總表／設備表，例如 F0_B2P2_ATS_1_3_KWH


def circuit_key(tag):
    """F1_A1P1_EL1B_B1_KWH_10 → "EL1B_10"（網站用 盤名_迴路，盤名的 - 換成 _）。

    沒有分路電表的盤（ATS1-3、PB1A、ER2A-1、EACMP-1）只有盤總表，用 "#盤名" 給網站當共用參考：
    F0_B2P2_ATS_1_3_KWH → "#ATS_1_3"。
    """
    m = CIRCUIT_KEY_RE.match(tag) or P2_CIRCUIT_RE.match(tag)
    if m:
        return f"{m.group(1)}_{int(m.group(2))}"
    m = P2_TOTAL_RE.match(tag)
    return f"#{m.group(1)}" if m else None


def window_kw(rows, h0, h1, min_hours, weekday_only=False):
    """最近一天 h0–h1 時之間的平均 kW（用累積讀值頭尾相減）→ (日期, {tag: kW})；不足 min_hours 小時的日子略過。"""
    by_day = defaultdict(list)
    for t, v in rows:
        if h0 <= t.hour + t.minute / 60 <= h1:
            by_day[t.date()].append((t, v))
    for day in sorted(by_day, reverse=True):
        if weekday_only and day.weekday() >= 5:
            continue
        (t0, v0), (t1, v1) = by_day[day][0], by_day[day][-1]
        hours = (t1 - t0).total_seconds() / 3600
        if hours < min_hours:
            continue
        out = {k: kw for k in v1 if (kw := kw_between(v0.get(k), v1[k], hours * 60)) is not None}
        return day, out
    return None, {}


def circuit_stats(rows, month_first=None):
    """各迴路 {key: [最近15分kW, 今日kWh, 本月kWh, 夜間基載kW, 上班平均kW]}；讀不到或倒退的給 None。

    今日＝最後讀值－今天第一筆；本月＝最後讀值－本月第一筆（month_first 是本月第一列的讀值）。
    夜間基載＝最近一晚 00:00–06:00 平均 kW；上班平均＝最近一個平日 09:00–17:00 平均 kW。
    """
    if not rows:
        return {}
    last_t, last = rows[-1]
    day0 = next((v for t, v in rows if t.date() == last_t.date()), {})
    month0 = month_first or next((v for t, v in rows if t.month == last_t.month and t.year == last_t.year), {})
    iv = intervals(rows)
    kw_last = iv[-1][1] if iv and iv[-1][0] + timedelta(minutes=20) >= last_t else {}

    def diff(a, b):
        if a is None or b is None or b < a - 0.05:
            return None
        return round(max(b - a, 0.0), 1)

    _, night = window_kw(rows, 0, 6, 4)
    _, work = window_kw(rows, 9, 17, 6, weekday_only=True)

    def r2(x):
        return round(x, 2) if x is not None else None

    out = {}
    for tag, v in last.items():
        key = circuit_key(tag)
        if not key:
            continue
        out[key] = [r2(kw_last.get(tag)), diff(day0.get(tag), v), diff(month0.get(tag), v),
                    r2(night.get(tag)), r2(work.get(tag))]
    return out


def diagnostics(rows):
    """只印彙總檢查（公開 log 不印個別迴路）。"""
    iv = intervals(rows)
    print(f"讀值 {len(rows)} 列，可算區間 {len(iv)} 個")
    if not iv:
        return
    t, kw = iv[-1]
    a = aggregate(kw)
    print(f"最後區間 {t:%H:%M}：總表 {a['total']}；樓層合計 {sum(a['floors'].values()):.1f}；"
          f"用途合計 {sum(a['cats'].values()):.1f}；主機房設備合計 {sum(a['plant'].values()):.1f}")
    print("樓層", {k: round(v, 1) for k, v in a["floors"].items()})
    print("用途", {k: round(v, 1) for k, v in a["cats"].items()})
    acb = {k: round(v, 1) for k, v in kw.items() if k.startswith("F0_B2P2_") and k.endswith("_KWH")}
    print("B2P2 低壓總盤各饋線", acb)
    parents = {k: round(v, 1) for k, v in kw.items()
               if re.match(r"F0_B1P2_E?ACMP_[A-Z0-9]+_KWH$", k) or k == "F0_B1P2_ACMP_G1_KWH"}
    print("主機房上層彙總", parents)


# ---------------- 空調監控主機（ac_logger.ps1 每分鐘一列） ----------------
AC_KEYS = ["ice01_pct", "ice02_pct", "mag_c1_pct", "mag_c2_pct", "mag_c1_kw", "mag_c2_kw",
           "mag_limit_pct", "mag_chws_c", "mag_chwr_c", "flow_m3h", "tank_out_c", "tank_in_c",
           "ice_low_sp", "bcu_chws_c", "cop", "kw_per_rt"]


def parse_ac(texts):
    """AC_*.csv → [(datetime, {欄位: float})]，只收 viewer_ok=1 的列。"""
    out = {}
    for text in texts:
        lines = [l for l in text.splitlines() if l.strip()]
        if not lines:
            continue
        head = lines[0].split(",")
        for line in lines[1:]:
            cells = line.split(",")
            if len(cells) != len(head):
                continue
            rec = dict(zip(head, cells))
            if rec.get("viewer_ok") != "1":
                continue
            try:
                t = datetime.strptime(rec["time"], "%Y-%m-%d %H:%M:%S")
            except (KeyError, ValueError):
                continue
            vals = {}
            for k in AC_KEYS:
                try:
                    vals[k] = float(rec[k])
                except (KeyError, ValueError):
                    pass
            out[t] = vals
    return sorted(out.items())


def ac_summary(rows, now):
    """最新讀值 + 今天每 15 分鐘一點的冰桶液位、磁浮負載 %、磁浮 kW；沒資料回傳 None。"""
    if not rows:
        return None
    t_last, last = rows[-1]

    def r1(x):
        return None if x is None else round(x, 1)

    def mag_pct(v):
        a = [v[k] for k in ("mag_c1_pct", "mag_c2_pct") if k in v]
        return sum(a) / len(a) if a else None

    def mag_kw(v):
        a = [v[k] for k in ("mag_c1_kw", "mag_c2_kw") if k in v]
        return sum(a) if a else None

    def ice(v):
        a = [v[k] for k in ("ice01_pct", "ice02_pct") if k in v]
        return sum(a) / len(a) if a else None

    buckets = {}
    for t, v in rows:
        if t.date() != now.date():
            continue
        key = t.replace(minute=t.minute - t.minute % 15, second=0)
        buckets.setdefault(key, []).append(v)
    times, ice_s, pct_s, kw_s = [], [], [], []
    for key in sorted(buckets):
        vs = buckets[key]

        def avg(f):
            a = [x for x in (f(v) for v in vs) if x is not None]
            return r1(sum(a) / len(a)) if a else None
        times.append(key.strftime("%H:%M"))
        ice_s.append(avg(ice))
        pct_s.append(avg(mag_pct))
        kw_s.append(avg(mag_kw))
    return {
        "time": t_last.strftime("%m/%d %H:%M"),
        "age_min": round((now - t_last).total_seconds() / 60),
        "latest": {k: r1(v) for k, v in last.items()},
        "ice_pct": r1(ice(last)),
        "mag_pct": r1(mag_pct(last)),
        "mag_kw": r1(mag_kw(last)),
        "series": {"times": times, "ice_pct": ice_s, "mag_pct": pct_s, "mag_kw": kw_s},
    }


