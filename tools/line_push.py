"""LINE 推播（LINE 官方帳號 Messaging API broadcast：加官方帳號為好友的人都會收到）。

由 local_live.py 每 5 秒呼叫 Notifier.tick()；同資料夾沒有 line_token.txt 就完全不動作。
推播內容：
1. 需量警報：15 分鐘推估達契約 90% / 95% / 100%，同一個 15 分鐘時段每個等級只推一次。
2. 磁浮自動控制（mag_auto.ps1 -Live）實際寫入時：時間、調到幾 %、原因。
3. 系統異常與恢復：讀不到 InTouch、空調監控主機資料超過 10 分鐘沒更新、自動控制程式沒回應、「是否啟用」被取消。
4. 每日摘要：08:00（昨天）、19:10（今天）。
5. 製冰／磁浮防超約（2026-11-07）：製冰主機 BCU-1 在白天（07:30–22:00）運轉就立刻推播（磁浮同時開會寫出來），
   夏月平日 16:00–22:00 磁浮還在轉也推播；製冰／融冰／磁浮排程一被修改就推播新舊值與檢查結果；
   每天 21:30 檢查今晚製冰與明天融冰／磁浮排程，有問題才推播。全部只讀，不會去動任何設備。
6. 排程指令信箱（sched_cmd.ps1）的執行結果：已執行／被擋下／沒完成，每筆推一次。
為了守住免費方案每月 200 則（則數 × 好友人數），每天最多推 MAX_PER_DAY 則（摘要不受限）。

測試：python line_push.py --test   （先印出方案上限／本月已用／好友數，再送一則測試訊息）
      python line_push.py --test --quota   （只看用量，不送）
"""
import datetime as dt
import json
import os
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE = os.path.join(HERE, "line_token.txt")
STATE_FILE = os.path.join(HERE, "line_state.json")
LOG = os.path.join(HERE, "line_push.log")
URL = "https://api.line.me/v2/bot/message/broadcast"
MAX_PER_DAY = 12
LEVELS = (1.00, 0.95, 0.90)
SUMMARY_AM, SUMMARY_PM = "08:00", "19:10"


def _log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {msg}\n")
    except OSError:
        pass


def send(text, token):
    """先用 Python 送；公司網路攔 SSL 時改用 Windows PowerShell 送。回傳 True/False。"""
    import urllib.request
    body = json.dumps({"messages": [{"type": "text", "text": text[:4900]}]}, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(URL, data=body, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            _log(f"sent ({r.status}) {text[:40]!r}")
            return True
    except Exception as e:
        err = e
    if os.name != "nt":
        _log(f"send failed: {err}")
        return False
    import base64
    import subprocess
    import tempfile
    with tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False) as f:
        f.write(body)
        path = f.name
    ps = ("[Net.ServicePointManager]::SecurityProtocol='Tls12';"
          "$b=[IO.File]::ReadAllBytes($env:LINE_BODY);"
          "$r=Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://api.line.me/v2/bot/message/broadcast' "
          "-Headers @{Authorization='Bearer '+$env:LINE_TOKEN} -ContentType 'application/json; charset=utf-8' -Body $b;"
          "$r.StatusCode")
    enc = base64.b64encode(ps.encode("utf-16-le")).decode()
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", enc],
                             env=dict(os.environ, LINE_TOKEN=token, LINE_BODY=path),
                             capture_output=True, text=True, timeout=60, creationflags=0x08000000)
        ok = out.stdout.strip().endswith("200")
        _log(f"sent via powershell ({out.stdout.strip()[-3:]}) {text[:40]!r}" if ok else
             f"send failed: python {err}; powershell {out.stdout.strip()[-200:]} {out.stderr.strip()[:200]}")
        return ok
    except Exception as e2:
        _log(f"send failed: python {err}; powershell {e2}")
        return False
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


# ---- 製冰／磁浮防超約（只讀檢查） ----
ICE_ON_KW = 30.0               # BCU-1 超過這個值算製冰中（製冰約 240 kW，待機只有零點幾 kW）
MAG_ON_KW = 10.0               # 磁浮兩台壓縮機合計超過這個值算運轉中
ICE_OK_FROM, ICE_OK_TO = "22:00", "07:30"   # 允許製冰的時段（跨午夜）；以外就是白天，會和上班空調疊在一起
ICE_REPEAT_MIN, ICE_REPEAT_MAX = 10, 3      # 白天製冰沒停：每 10 分鐘再推一次，最多 3 次
SCHED_CHECK_AT = "21:30"       # 每天檢查今晚製冰與明天融冰／磁浮排程（製冰通常 23:55 開始）
WD = "一二三四五六日"
SCHED_NAMES = {"ice": "製冰", "melt": "融冰", "chu2": "磁浮"}
CMD_RESULT = r"\\10.10.2.4\AC_Export\sched_cmd_result.json"   # 空調監控主機 sched_cmd.ps1（指令信箱）的執行結果


def is_summer(d):
    return (5, 16) <= (d.month, d.day) <= (10, 15)


def ice_running(ac):
    kw = ac.get("bcu_kw")
    if kw is not None:
        return kw >= ICE_ON_KW, kw
    return ac.get("bcu_st") == 1, None


def mag_kw(ac):
    a, b = ac.get("mag_c1_kw"), ac.get("mag_c2_kw")
    if a is None and b is None:
        return None
    return (a or 0) + (b or 0)


def in_ice_window(hm):
    return hm >= ICE_OK_FROM or hm < ICE_OK_TO


def _hm_ok(x):
    try:
        h, m = x.split(":")
        return 0 <= int(h) <= 23 and 0 <= int(m) <= 59
    except (AttributeError, ValueError):
        return False


def _entry(sched, kind, wd):
    """wd = Python weekday（0 = 星期一）。回傳 InTouch 該天排程 {on, off, en} 或 None。"""
    return ((sched or {}).get(kind) or {}).get(str(wd + 1))


def _fmt(e):
    if not e:
        return "讀不到"
    return f"{e.get('on')}–{e.get('off')}{'（有勾）' if e.get('en') == 1 else '（沒勾）'}"


def ice_entry_problem(e):
    """製冰排程有勾、但開始或結束時間跑進 07:30–22:00 → 回傳說明。"""
    if not e or e.get("en") != 1:
        return None
    on, off = e.get("on"), e.get("off")
    if not (_hm_ok(on) and _hm_ok(off)):
        return f"時間數值異常（{on}–{off}）"
    if off <= on:                                   # 跨午夜，例如 23:55–07:00
        bad = on < ICE_OK_FROM or off > ICE_OK_TO
    else:                                           # 同一天內，例如 00:30–06:00 或 13:00–15:00
        bad = not (on >= ICE_OK_FROM or off <= ICE_OK_TO)
    if bad:
        return f"{on}–{off} 跑進白天（{ICE_OK_TO}–{ICE_OK_FROM}），會和上班空調、磁浮同時開"
    return None


def sched_problems(sched, now, nightly=False):
    """檢查今晚製冰與明天融冰／磁浮排程，回傳問題清單（字串）。nightly=True 才報「該做沒做」類的提醒。"""
    out = []
    if not sched:
        return out
    for wd in range(7):                             # 任何一天的製冰排程跑進白天都要報
        p = ice_entry_problem(_entry(sched, "ice", wd))
        if p:
            out.append(f"🚨 星期{WD[wd]}製冰排程 {p}")
    for kind in ("melt", "chu2"):
        for wd in range(7):
            e = _entry(sched, kind, wd)
            if e and e.get("en") == 1 and not (_hm_ok(e.get("on")) and _hm_ok(e.get("off"))):
                out.append(f"⚠️ 星期{WD[wd]}{SCHED_NAMES[kind]}排程時間數值異常（{e.get('on')}–{e.get('off')}）")
    tmr = (now + dt.timedelta(days=1)).date()
    tonight = now.weekday()
    if nightly and tmr.weekday() < 5:
        ice = _entry(sched, "ice", tonight)
        melt, chu2 = _entry(sched, "melt", tmr.weekday()), _entry(sched, "chu2", tmr.weekday())
        if is_summer(tmr):
            if ice and ice.get("en") != 1:
                out.append(f"⚠️ 今晚（星期{WD[tonight]}）沒有勾製冰，明天下午尖峰只能靠磁浮硬撐（像 10/2 那次）。明天若放假可忽略")
            if melt and melt.get("en") != 1:
                out.append(f"⚠️ 明天（星期{WD[tmr.weekday()]}）融冰排程沒勾，16:00 磁浮關掉後會沒有冷源")
            elif melt and _hm_ok(melt.get("on")) and _hm_ok(melt.get("off")) and (melt["on"] > "16:00" or melt["off"] < "19:00"):
                out.append(f"⚠️ 明天融冰排程 {melt['on']}–{melt['off']} 沒有涵蓋 16:00–19:00（程序是 10:50–19:00）")
            if chu2 and chu2.get("en") == 1 and _hm_ok(chu2.get("off")) and chu2["off"] > "16:00":
                out.append(f"⚠️ 明天磁浮排程到 {chu2['off']}，夏月 16:00 尖峰起磁浮必須關、改融冰供冷")
        elif ice and ice.get("en") == 1:
            out.append(f"ℹ️ 今晚（星期{WD[tonight]}）有勾製冰 {ice.get('on')}–{ice.get('off')}；非夏月通常不製冰，請確認是否需要")
    return out


def sched_diff(old, new):
    """兩份排程的差異（只列製冰／融冰／磁浮有變的天）。"""
    out = []
    for kind, name in SCHED_NAMES.items():
        for wd in range(7):
            a, b = _entry(old, kind, wd), _entry(new, kind, wd)
            if (a or {}) != (b or {}):
                out.append(f"星期{WD[wd]}{name}：{_fmt(a)} → {_fmt(b)}")
    return out


def _f(v, n=0):
    return "—" if v is None else f"{v:,.{n}f}"


class Notifier:
    def __init__(self):
        self.token = None
        if os.path.exists(TOKEN_FILE):
            with open(TOKEN_FILE, encoding="utf-8") as f:
                self.token = f.read().strip() or None
        self.state = {"day": None, "count": 0, "sent_levels": {}, "faults": {}, "last_mag_action": None,
                      "summary": {}, "days": {}, "ice": {}, "sched": None, "sched_check": None, "cmd_seen": None}
        try:
            with open(STATE_FILE, encoding="utf-8") as f:
                self.state.update(json.load(f))
        except (OSError, ValueError):
            pass
        self.fault_since = {}
        self.saved_at = dt.datetime.min

    @property
    def enabled(self):
        return bool(self.token)

    def _save(self):
        try:
            with open(STATE_FILE + ".tmp", "w", encoding="utf-8") as f:
                json.dump(self.state, f, ensure_ascii=False)
            os.replace(STATE_FILE + ".tmp", STATE_FILE)
        except OSError:
            pass

    def _push(self, text, force=False):
        today = dt.date.today().isoformat()
        if self.state["day"] != today:
            self.state["day"], self.state["count"] = today, 0
        if not force and self.state["count"] >= MAX_PER_DAY:
            _log(f"daily cap reached, skipped {text[:40]!r}")
            return
        self.state["count"] += 1
        self._save()
        threading.Thread(target=send, args=("【中創能管】" + text, self.token), daemon=True).start()

    # ---- 各類事件 ----
    def _demand(self, snap):
        if not snap or not snap.get("limit"):
            return
        r = snap["projected"] / snap["limit"]
        if snap.get("elapsed_s", 0) < 120 and r < 1.0:
            return                                    # 時段剛開始，推估還不穩
        win = snap["window"]
        sent = self.state["sent_levels"]
        for lv in LEVELS:
            if r >= lv:
                key = f"{dt.date.today()} {win}"
                if sent.get(key, 0) >= lv:
                    return
                sent.clear()
                sent[key] = lv
                head = "⚠️ 推估會超約" if lv >= 1.0 else f"需量已達契約 {int(lv * 100)}%"
                self._push(f"{head}\n時段 {win}（{snap['period']}，契約 {snap['limit']} kW）\n"
                           f"推估 {_f(snap['projected'], 1)} kW，目前 {_f(snap['now_kw'], 1)} kW\n"
                           f"距契約 {_f(snap['margin'], 1)} kW", force=lv >= 1.0)
                return

    def _mag(self, mag):
        if not mag or mag.get("mode") != "LIVE":
            return
        act, at = mag.get("last_action"), mag.get("last_action_at")
        if act and at and at != self.state["last_mag_action"]:
            self.state["last_mag_action"] = at
            self._push(f"磁浮自動控制 {at[11:16]}\n{act}\n出水 {_f(mag.get('chws_c'), 1)}°C（目標 {_f(mag.get('chws_target'), 1)}）")

    def _fault(self, key, bad, msg_bad, msg_ok, now, hold_s):
        faults = self.state["faults"]
        if bad:
            since = self.fault_since.setdefault(key, now)
            # 兩台電腦每天約 07:00 自動重開機：06:45–07:25 之間先不報，07:25 後仍異常才推播
            reboot = (6, 45) <= (now.hour, now.minute) < (7, 25)
            if not faults.get(key) and not reboot and (now - since).total_seconds() >= hold_s:
                faults[key] = now.strftime("%H:%M")
                self._push("❗ " + msg_bad, force=True)
        else:
            self.fault_since.pop(key, None)
            if faults.get(key):
                self._push(f"✅ {msg_ok}（{faults[key]} 起異常，已恢復）", force=True)
                faults[key] = None

    def _summary(self, now, snap, ems, mag):
        day = now.date().isoformat()
        days = self.state["days"]
        if ems and ems.get("updated", "")[:10] == day:
            live = bool(mag and mag.get("mode") == "LIVE" and not mag.get("off"))
            prev = days.get(day) or {}
            prev_live = prev.get("live", False)
            pv = ems.get("pv") or {}
            pv_kwh = pv.get("today_kwh") if (pv.get("updated") or "")[:10] == day else prev.get("pv_kwh")
            days[day] = {"peak": ems.get("today_peak_kw"), "peak_at": ems.get("today_peak_at"),
                         "kwh": ems.get("today_kwh"), "mag": ems.get("mag_today"), "live": live or prev_live,
                         "wd": now.weekday() < 5, "pv_kwh": pv_kwh}
        for k in sorted(days)[:-60]:              # 保留 60 天，給「節電成效」比較人工時期
            days.pop(k)
        hm = now.strftime("%H:%M")
        done = self.state["summary"]
        if hm >= SUMMARY_AM and done.get("am") != day:
            done["am"] = day
            y = (now.date() - dt.timedelta(days=1)).isoformat()
            d = days.get(y)
            if d:
                m = d.get("mag") or {}
                self._push(f"昨日摘要 {y[5:]}\n最高 15 分鐘需量 {_f(d['peak'], 1)} kW（{d['peak_at'] or '—'}）\n"
                           + self._kwh_lines(d) + "\n" + f"磁浮運轉 {_f(m.get('run_hours'), 1)} h・{_f(m.get('kwh'))} 度\n"
                           + self._savings(y, d), force=True)
            else:
                self._save()
        if hm >= SUMMARY_PM and done.get("pm") != day:
            done["pm"] = day
            d = days.get(day)
            if d:
                m = d.get("mag") or {}
                lines = [f"今日摘要 {day[5:]}", f"最高 15 分鐘需量 {_f(d['peak'], 1)} kW（{d['peak_at'] or '—'}）",
                         f"用電至今 {_f(d['kwh'])} 度", f"磁浮運轉 {_f(m.get('run_hours'), 1)} h・{_f(m.get('kwh'))} 度"]
                if mag:
                    lines.append(f"磁浮控制：{'自動' if mag.get('mode') == 'LIVE' else '試跑'}，上限 {_f(mag.get('limit_read'))}%")
                self._push("\n".join(lines), force=True)
            else:
                self._save()

    @staticmethod
    def _kwh_lines(d):
        """用電：台電電表（買電）＋太陽能（全部自發自用、在總表後面）＝ 總用電。"""
        pv = d.get("pv_kwh")
        if d.get("kwh") is None:
            return "用電 — 度"
        if pv is None:
            return f"台電電表 {_f(d['kwh'])} 度\n總用電 —（太陽能資料缺）"
        return f"台電電表 {_f(d['kwh'])} 度＋太陽能 {_f(pv)} 度\n總用電 {_f(d['kwh'] + pv)} 度"

    def _savings(self, day, d):
        """節電成效：自動控制當天的磁浮度數 vs 人工時期同類日（平日／假日）最近 10 天平均。"""
        if not d.get("live"):
            return "節電成效：尚未由自動控制接手（試跑／人工）"
        days = self.state["days"]
        ref = [v["mag"]["kwh"] for k, v in sorted(days.items()) if k < day and not v.get("live")
               and v.get("wd") == d.get("wd") and (v.get("mag") or {}).get("kwh")][-10:]
        live_days = [(k, v) for k, v in sorted(days.items()) if k <= day and v.get("live") and (v.get("mag") or {}).get("kwh")]
        mk = (d.get("mag") or {}).get("kwh")
        if len(ref) < 3 or mk is None:
            return "節電成效：人工時期基準資料不足（需至少 3 天），暫不計算"
        base = sum(ref) / len(ref)
        save = base - mk
        cum = sum(base - v["mag"]["kwh"] for k, v in live_days if v.get("wd") == d.get("wd"))
        return (f"節電成效（磁浮，對比人工時期 {len(ref)} 天平均 {_f(base)} 度）\n"
                f"昨日{'省' if save >= 0 else '多用'} {_f(abs(save))} 度（{_f(abs(save) / base * 100, 1)}%）\n"
                f"接手以來累計 {_f(cum)} 度・約 {_f(cum * 4)} 元\n※ 未做天氣校正，僅供參考")

    def _ice_guard(self, now, ac, snap):
        """製冰主機白天運轉（尤其和磁浮同時開）立刻推播；夏月平日尖峰磁浮還在轉也推播。"""
        try:
            age = (now - dt.datetime.strptime(ac.get("time", ""), "%Y-%m-%d %H:%M:%S")).total_seconds()
        except ValueError:
            return
        if not ac.get("viewer_ok") or age > 180:
            return                                   # 資料太舊時不判斷（另有「資料沒更新」警報）
        st = self.state["ice"]
        hm = now.strftime("%H:%M")
        on, bkw = ice_running(ac)
        mkw = mag_kw(ac)
        mag_on = (mkw is not None and mkw >= MAG_ON_KW) or ac.get("chu2_st") == 1
        dem = ""
        if snap and snap.get("limit"):
            dem = (f"\n15 分鐘推估 {_f(snap['projected'], 1)} kW／契約 {snap['limit']} kW（{snap['period']}），"
                   f"目前 {_f(snap['now_kw'], 1)} kW")
        if on and not in_ice_window(hm):
            last = st.get("day_at")
            n = st.get("day_n", 0)
            due = last is None or (n < ICE_REPEAT_MAX and
                                   (now - dt.datetime.fromisoformat(last)).total_seconds() >= ICE_REPEAT_MIN * 60)
            if due:
                st["day_at"], st["day_n"] = now.isoformat(timespec="seconds"), n + 1
                st.setdefault("day_since", hm)
                head = "🚨 製冰主機和磁浮同時運轉" if mag_on else "🚨 製冰主機在白天運轉"
                self._push(f"{head}（{st['day_since']} 起{'，第 ' + str(n + 1) + ' 次通知' if n else ''}）\n"
                           f"製冰 BCU-1 {_f(bkw)} kW" + (f"、磁浮 {_f(mkw)} kW" if mag_on else "") + dem +
                           "\n製冰主機約 240 kW，和上班空調疊在一起很容易超約。\n"
                           "請立即到【空調監控主機】把 BCU 製冰停掉，並檢查製冰排程有沒有被勾到白天。", force=True)
        elif st.get("day_at"):
            self._push(f"✅ 製冰主機已停止（{st.get('day_since', '—')} 起白天運轉）", force=True)
            st.pop("day_at", None), st.pop("day_n", None), st.pop("day_since", None)
        peak = is_summer(now) and now.weekday() < 5 and "16:00" <= hm < "22:00"
        if peak and mag_on:
            since = st.setdefault("peak_since", now.isoformat(timespec="seconds"))
            if st.get("peak_day") != now.date().isoformat() and \
                    (now - dt.datetime.fromisoformat(since)).total_seconds() >= 300:
                st["peak_day"] = now.date().isoformat()
                self._push(f"⚠️ 夏月尖峰（16:00–22:00）磁浮還在運轉：{_f(mkw)} kW{dem}\n"
                           "程序規定尖峰時段磁浮要關、由融冰供冷，請確認。", force=True)
        else:
            st.pop("peak_since", None)

    def _sched_guard(self, now, ac):
        """排程被修改 → 推播新舊值與檢查結果；每天 21:30 檢查今晚／明天的排程，有問題才推播。"""
        sched = ac.get("sched")
        if not sched or not ac.get("viewer_ok"):
            return
        view = {k: sched.get(k) for k in SCHED_NAMES}
        old = self.state.get("sched")
        if old is None:
            self.state["sched"] = view
            self._save()
        elif view != old:
            diff = sched_diff(old, view)
            self.state["sched"] = view
            if diff:
                probs = sched_problems(view, now)
                self._push("📝 空調主機排程被修改（" + now.strftime("%H:%M") + " 前後）\n" + "\n".join(diff[:10]) +
                           ("\n" + "\n".join(probs[:8]) if probs else "\n檢查結果：沒有跑進白天的製冰排程"), force=True)
        day = now.date().isoformat()
        if now.strftime("%H:%M") >= SCHED_CHECK_AT and self.state.get("sched_check") != day:
            self.state["sched_check"] = day
            probs = sched_problems(view, now, nightly=True)
            if probs:
                self._push(f"排程檢查 {now:%m-%d %H:%M}\n" + "\n".join(probs[:8]), force=True)
            else:
                self._save()

    def _cmd_result(self, now):
        """指令信箱執行結果：每個指令 id＋狀態只推一次。每 30 秒看一次檔案。"""
        if (now - getattr(self, "_cmd_at", dt.datetime.min)).total_seconds() < 30:
            return
        self._cmd_at = now
        try:
            with open(CMD_RESULT, encoding="utf-8-sig") as f:
                r = json.load(f)
        except (OSError, ValueError):
            return
        key = f"{r.get('id')}|{r.get('status')}"
        if not r.get("id") or key == self.state.get("cmd_seen"):
            return
        first = self.state.get("cmd_seen") is None
        self.state["cmd_seen"] = key
        if first and r.get("time", "")[:10] != now.date().isoformat():
            self._save()
            return                                   # 第一次啟動時不重推以前的舊結果
        head = {"done": "✅ 排程指令已執行", "rejected": "⛔ 排程指令被擋下（沒有寫入）",
                "failed": "❌ 排程指令沒有完成", "dry_run": "🧪 排程指令試跑（只檢查，沒有寫入）"}.get(r.get("status"), "排程指令")
        lines = r.get("lines") or []
        if isinstance(lines, str):
            lines = [lines]
        self._push(f"{head}（{r.get('time', '')[11:16]}，編號 {r.get('id')}）\n" + "\n".join(lines[:12]) +
                   (f"\n說明：{r['note']}" if r.get("note") else ""), force=True)

    def tick(self, now, live_ok, snap, ac, mag, ems):
        if not self.enabled:
            return
        try:
            if live_ok:
                self._demand(snap)
            self._fault("intouch", not live_ok, "監控電腦讀不到 InTouch 總電表（WindowViewer 有開嗎？）",
                        "監控電腦 InTouch 讀取恢復", now, 120)
            ac_age = None
            if ac and ac.get("time"):
                try:
                    ac_age = (now - dt.datetime.strptime(ac["time"], "%Y-%m-%d %H:%M:%S")).total_seconds()
                except ValueError:
                    pass
            ac_bad = ac is None or not ac.get("viewer_ok") or (ac_age is not None and ac_age > 600)
            self._fault("ac", ac_bad, "空調監控主機資料超過 10 分鐘沒更新（WindowViewer 或記錄程式停了？）",
                        "空調監控主機資料恢復", now, 600)
            if mag is not None:
                mag_age = None
                try:
                    mag_age = (now - dt.datetime.strptime(mag.get("time", ""), "%Y-%m-%d %H:%M:%S")).total_seconds()
                except ValueError:
                    pass
                self._fault("mag", mag_age is not None and mag_age > 300, "磁浮自動控制程式超過 5 分鐘沒回應",
                            "磁浮自動控制程式恢復", now, 0)
                self._fault("mag_enabled", mag.get("enabled") is False and mag.get("mode") == "LIVE",
                            "中控「是否啟用」未打勾，負載限制不會作用", "中控「是否啟用」已打勾", now, 60)
                self._mag(mag)
            if ac:
                self._ice_guard(now, ac, snap if live_ok else None)
                self._sched_guard(now, ac)
            self._cmd_result(now)
            self._summary(now, snap, ems, mag)
            if (now - self.saved_at).total_seconds() >= 300:
                self.saved_at = now
                self._save()
        except Exception as e:                      # 推播出錯不能影響網站
            _log(f"tick error {type(e).__name__}: {e}")


if __name__ == "__main__":
    if "--test" in sys.argv:
        n = Notifier()
        if not n.enabled:
            raise SystemExit(f"找不到 {TOKEN_FILE}")
        import subprocess
        ps = ("[Net.ServicePointManager]::SecurityProtocol='Tls12';$h=@{Authorization='Bearer '+$env:LINE_TOKEN};"
              "$q=Invoke-RestMethod -Uri 'https://api.line.me/v2/bot/message/quota' -Headers $h;"
              "$c=Invoke-RestMethod -Uri 'https://api.line.me/v2/bot/message/quota/consumption' -Headers $h;"
              "$f=Invoke-RestMethod -Uri 'https://api.line.me/v2/bot/insight/followers?date='+(Get-Date).AddDays(-1).ToString('yyyyMMdd') -Headers $h;"
              "'方案上限 '+$q.value+' 則／月（'+$q.type+'），本月已用 '+$c.totalUsage+' 則，好友 '+$f.followers+' 人'")
        try:
            out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], env=dict(os.environ, LINE_TOKEN=n.token),
                                 capture_output=True, text=True, timeout=60)
            print(out.stdout.strip() or out.stderr.strip()[:300])
        except Exception as e:
            print(f"查不到用量：{e}")
        if "--quota" in sys.argv:
            raise SystemExit
        ok = send("【中創能管】測試訊息：LINE 推播設定成功 👍", n.token)
        print("送出成功" if ok else f"送出失敗，請看 {LOG}")
