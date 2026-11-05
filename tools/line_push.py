"""LINE 推播（LINE 官方帳號 Messaging API broadcast：加官方帳號為好友的人都會收到）。

由 local_live.py 每 5 秒呼叫 Notifier.tick()；同資料夾沒有 line_token.txt 就完全不動作。
推播內容：
1. 需量警報：15 分鐘推估達契約 90% / 95% / 100%，同一個 15 分鐘時段每個等級只推一次。
2. 磁浮自動控制（mag_auto.ps1 -Live）實際寫入時：時間、調到幾 %、原因。
3. 系統異常與恢復：讀不到 InTouch、空調監控主機資料超過 10 分鐘沒更新、自動控制程式沒回應、「是否啟用」被取消。
4. 每日摘要：08:00（昨天）、19:10（今天）。
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


def _f(v, n=0):
    return "—" if v is None else f"{v:,.{n}f}"


class Notifier:
    def __init__(self):
        self.token = None
        if os.path.exists(TOKEN_FILE):
            with open(TOKEN_FILE, encoding="utf-8") as f:
                self.token = f.read().strip() or None
        self.state = {"day": None, "count": 0, "sent_levels": {}, "faults": {}, "last_mag_action": None,
                      "summary": {}, "days": {}}
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
            if not faults.get(key) and (now - since).total_seconds() >= hold_s:
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
            prev_live = (days.get(day) or {}).get("live", False)
            days[day] = {"peak": ems.get("today_peak_kw"), "peak_at": ems.get("today_peak_at"),
                         "kwh": ems.get("today_kwh"), "mag": ems.get("mag_today"), "live": live or prev_live,
                         "wd": now.weekday() < 5}
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
                           f"用電 {_f(d['kwh'])} 度\n磁浮運轉 {_f(m.get('run_hours'), 1)} h・{_f(m.get('kwh'))} 度\n"
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
