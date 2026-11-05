"""中創園區 本機即時能源網站（在監控電腦執行，只在內網看）。

每 5 秒用 DDE 唯讀讀 InTouch 的總電表瞬時 kW（F0_B2P2_MCB_KW_PV），
每 30 秒讀空調監控主機共用資料夾的 ac_latest.json（冰桶液位、磁浮負載），
算出台電 15 分鐘需量（本時段平均、推估、今日最高）並與當下時段的契約容量比較，
用內建網頁伺服器在 http://<監控電腦>:8088/ 顯示，每 5 秒自動更新。

需要：InTouch WindowViewer 開著、系統管理員權限（與 view.exe 同權限才能 DDE）、pywin32。
用法：
    python local_live.py           # 啟動網站（前景）
    python local_live.py --test    # 讀一次並印出，不啟動網站
"""
import datetime as dt
import json
import os
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "local_live_state.json")
LOG = os.path.join(HERE, "local_live.log")
PORT = 8088
MAIN_TAG = "F0_B2P2_MCB_KW_PV"
TAIPOWER_OFFSET = 10.0          # 台電電表比 BMS 高約 10 kW（2026-11 對帳確認）
AC_JSON = r"\\10.10.2.4\AC_Export\ac_latest.json"
SAMPLE_S = 5
HISTORY = 2 * 3600 // SAMPLE_S  # 網頁趨勢圖保留 2 小時


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


# ---------------- 網頁 ----------------
STATE_LOCK = threading.Lock()
LIVE = {"ok": False, "error": "啟動中"}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/live"):
            with STATE_LOCK:
                body = json.dumps(LIVE, ensure_ascii=False).encode("utf-8")
            ctype = "application/json; charset=utf-8"
        elif self.path in ("/", "/index.html"):
            body = PAGE.encode("utf-8")
            ctype = "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
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
.err{color:var(--bad)}
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
        return

    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log(f"本機即時網站啟動：http://localhost:{PORT}/")
    ac, ac_at = None, 0.0
    while True:
        t0 = time.time()
        now = dt.datetime.now()
        try:
            kw = reader.main_kw() + TAIPOWER_OFFSET
            dem.add(now, kw)
            if t0 - ac_at > 30:
                ac, ac_at = read_ac(), t0
            snap = dem.snapshot(now)
            with STATE_LOCK:
                LIVE.clear()
                LIVE.update({"ok": True, "time": now.strftime("%H:%M:%S"), "offset": TAIPOWER_OFFSET,
                             "demand": snap, "trend": list(dem.trend), "ac": ac})
        except Exception as e:
            with STATE_LOCK:
                LIVE.clear()
                LIVE.update({"ok": False, "error": f"讀不到 InTouch（WindowViewer 有開嗎？）{type(e).__name__}"})
            log(f"讀取失敗：{type(e).__name__}: {e}")
            time.sleep(25)
        time.sleep(max(0.5, SAMPLE_S - (time.time() - t0)))


if __name__ == "__main__":
    main()
