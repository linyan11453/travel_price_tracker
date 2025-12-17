from __future__ import annotations

from pathlib import Path
import sqlite3
from datetime import datetime, timedelta
from typing import Optional

from fastapi import FastAPI, Query, HTTPException
from fastapi.responses import HTMLResponse, PlainTextResponse

from travel_tracker.storage.db import SQLITE_PATH


APP_TITLE = "travel_price_tracker API"
DB_PATH = Path(SQLITE_PATH)

app = FastAPI(title=APP_TITLE)


def _conn() -> sqlite3.Connection:
    if not DB_PATH.exists():
        raise HTTPException(status_code=500, detail=f"DB not found: {DB_PATH}")
    c = sqlite3.connect(str(DB_PATH))
    c.row_factory = sqlite3.Row
    return c


def _date_floor(days: int) -> str:
    # run_date 是 'YYYY-MM-DD'，用字串比較可行（同格式）
    d = datetime.now() - timedelta(days=days)
    return d.strftime("%Y-%m-%d")


@app.get("/health")
def health() -> dict:
    try:
        c = _conn()
        try:
            c.execute("select 1").fetchone()
        finally:
            c.close()
    except Exception as e:
        return {"ok": False, "db": str(DB_PATH), "error": repr(e)}

    latest = Path("reports/latest.md")
    return {
        "ok": True,
        "db": str(DB_PATH),
        "reports_latest_exists": latest.exists(),
        "reports_latest_path": str(latest.resolve()) if latest.exists() else None,
        "ts": datetime.now().isoformat(timespec="seconds"),
    }


@app.get("/signals/news")
def signals_news(
    city: str = Query(..., description="例如 SIN / KUL / TPE"),
    days: int = Query(7, ge=1, le=90),
    limit: int = Query(50, ge=1, le=500),
    source_id: Optional[str] = Query(None),
) -> dict:
    floor = _date_floor(days)
    c = _conn()
    try:
        sql = """
        select id, run_date, city_code, city_name_zh, source_id, source, title, url, published_at, created_at
        from signals_news
        where city_code = ?
          and run_date >= ?
        """
        params: list = [city, floor]
        if source_id:
            sql += " and source_id = ? "
            params.append(source_id)

        sql += " order by id desc limit ? "
        params.append(limit)

        rows = [dict(r) for r in c.execute(sql, params).fetchall()]
        return {"city": city, "days": days, "limit": limit, "count": len(rows), "rows": rows}
    finally:
        c.close()


@app.get("/signals/weather")
def signals_weather(
    city: str = Query(...),
    days: int = Query(7, ge=1, le=90),
    limit: int = Query(50, ge=1, le=500),
) -> dict:
    floor = _date_floor(days)
    c = _conn()
    try:
        rows = [dict(r) for r in c.execute(
            """
            select id, run_date, city_code, city_name_zh, source_id, source, title, url, published_at, created_at
            from signals_weather
            where city_code = ?
              and run_date >= ?
            order by id desc
            limit ?
            """,
            (city, floor, limit),
        ).fetchall()]
        return {"city": city, "days": days, "limit": limit, "count": len(rows), "rows": rows}
    finally:
        c.close()


@app.get("/signals/safety")
def signals_safety(
    city: str = Query(...),
    days: int = Query(30, ge=1, le=365),
    limit: int = Query(50, ge=1, le=500),
) -> dict:
    floor = _date_floor(days)
    c = _conn()
    try:
        rows = [dict(r) for r in c.execute(
            """
            select id, run_date, city_code, city_name_zh, source_id, source, title, url, published_at, created_at
            from signals_safety
            where city_code = ?
              and run_date >= ?
            order by id desc
            limit ?
            """,
            (city, floor, limit),
        ).fetchall()]
        return {"city": city, "days": days, "limit": limit, "count": len(rows), "rows": rows}
    finally:
        c.close()


@app.get("/runs")
def runs(limit: int = Query(30, ge=1, le=500)) -> dict:
    c = _conn()
    try:
        rows = [dict(r) for r in c.execute(
            """
            select *
            from runs
            order by id desc
            limit ?
            """,
            (limit,),
        ).fetchall()]
        return {"limit": limit, "count": len(rows), "rows": rows}
    finally:
        c.close()


@app.get("/reports/latest", response_class=PlainTextResponse)
def reports_latest() -> str:
    p = Path("reports/latest.md")
    if not p.exists():
        raise HTTPException(status_code=404, detail="reports/latest.md not found")
    return p.read_text(encoding="utf-8")


@app.get("/ui", response_class=HTMLResponse)
def ui() -> str:
    # 最小展示頁：選城市 + 直接看 news
    return """
<!doctype html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>travel_price_tracker Dashboard</title>
  <style>
    body{font-family: -apple-system, BlinkMacSystemFont, "PingFang TC", "Noto Sans TC", sans-serif; margin:24px;}
    .row{display:flex; gap:12px; align-items:center; flex-wrap:wrap;}
    select,input,button{padding:8px 10px; font-size:14px;}
    table{border-collapse:collapse; width:100%; margin-top:12px;}
    th,td{border-bottom:1px solid #ddd; padding:10px; vertical-align:top;}
    th{text-align:left; background:#f6f6f6;}
    .muted{color:#666;}
    a{word-break:break-all;}
  </style>
</head>
<body>
  <h1>travel_price_tracker Dashboard</h1>
  <div class="row">
    <label>城市</label>
    <select id="city">
      <option value="SIN">SIN 新加坡</option>
      <option value="KUL">KUL 吉隆坡</option>
      <option value="PEN">PEN 檳城</option>
      <option value="BKK">BKK 曼谷</option>
      <option value="TPE">TPE 台北</option>
      <option value="KHH">KHH 高雄</option>
      <option value="TNN">TNN 台南</option>
    </select>

    <label>天數</label>
    <input id="days" type="number" value="7" min="1" max="90" />

    <label>筆數</label>
    <input id="limit" type="number" value="50" min="1" max="500" />

    <button onclick="loadNews()">載入新聞</button>
    <button onclick="loadLatest()">最新報表</button>
  </div>

  <p class="muted" id="status"></p>
  <div id="latest" style="white-space:pre-wrap; background:#fafafa; padding:12px; border:1px solid #eee; display:none;"></div>

  <table id="tbl" style="display:none;">
    <thead>
      <tr>
        <th>run_date</th>
        <th>source_id</th>
        <th>title</th>
        <th>url</th>
      </tr>
    </thead>
    <tbody></tbody>
  </table>

<script>
async function loadNews(){
  const city = document.getElementById("city").value;
  const days = document.getElementById("days").value;
  const limit = document.getElementById("limit").value;
  document.getElementById("status").textContent = "載入中...";
  document.getElementById("latest").style.display="none";

  const r = await fetch(`/signals/news?city=${encodeURIComponent(city)}&days=${encodeURIComponent(days)}&limit=${encodeURIComponent(limit)}`);
  const j = await r.json();

  const tbl = document.getElementById("tbl");
  const tb = tbl.querySelector("tbody");
  tb.innerHTML = "";
  for (const row of j.rows){
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${row.run_date || ""}</td>
      <td>${row.source_id || ""}</td>
      <td>${(row.title || "").replaceAll("<","&lt;")}</td>
      <td><a href="${row.url}" target="_blank" rel="noopener">${row.url}</a></td>
    `;
    tb.appendChild(tr);
  }
  tbl.style.display = "";
  document.getElementById("status").textContent = `OK：${j.count} 筆`;
}

async function loadLatest(){
  document.getElementById("status").textContent = "載入 latest.md...";
  const r = await fetch(`/reports/latest`);
  if(!r.ok){
    document.getElementById("status").textContent = "找不到 reports/latest.md";
    return;
  }
  const t = await r.text();
  const box = document.getElementById("latest");
  box.textContent = t;
  box.style.display = "";
  document.getElementById("tbl").style.display="none";
  document.getElementById("status").textContent = "OK：latest.md";
}
</script>
</body>
</html>
"""


