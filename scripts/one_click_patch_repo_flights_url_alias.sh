#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
BK="_migrated/patch_repo_flights_url_alias_${TS}"
mkdir -p "$BK"

F="src/travel_tracker/storage/repository.py"
cp -f "$F" "$BK/repository.py.bak"
echo "[OK] backup -> $BK/repository.py.bak"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/storage/repository.py")
s = p.read_text(encoding="utf-8")

if "class Repository" not in s:
    raise SystemExit("[ERR] repository.py not found or unexpected content")

m = re.search(r"\n\s+def insert_flight_quote\s*\(", s)
if not m:
    raise SystemExit("[ERR] cannot find def insert_flight_quote(...) in repository.py")

start = m.start()
# find next method at same indent (4 spaces) after start
m2 = re.search(r"\n    def \w+\s*\(", s[m.end():])
end = (m.end() + m2.start()) if m2 else len(s)

replacement = r'''
    def insert_flight_quote(
        self,
        *,
        provider: str,
        origin: str,
        destination: str,
        route_id: str,
        source_url: str | None = None,
        url: str | None = None,  # alias (pipeline may still use url)
        status_code: int | None = None,
        parse_ok: int = 0,
        min_price_currency: str | None = None,
        min_price_value: float | None = None,
        raw_path: str | None = None,
        notes: str | None = None,
        created_at: str | None = None,
    ) -> None:
        """
        Canonical naming:
          - DB column: source_url
          - Accepts url as alias for backward/forward compatibility
        """
        cols = self._table_cols("flights_quotes")

        # Normalize URL
        _source_url = source_url or url
        if not _source_url:
            # keep it explicit; if schema is NOT NULL, failing early is better than silent garbage
            raise ValueError("insert_flight_quote(): missing source_url/url")

        _created_at = created_at or _now_iso()

        col_names: list[str] = []
        values: list[object] = []

        def add(col: str, val: object) -> None:
            if col in cols:
                col_names.append(col)
                values.append(val)

        add("provider", provider)
        add("origin", origin)
        add("destination", destination)
        add("route_id", route_id)

        # Prefer canonical column name
        if "source_url" in cols:
            add("source_url", _source_url)
        elif "url" in cols:
            add("url", _source_url)

        add("status_code", status_code)
        add("parse_ok", parse_ok)
        add("min_price_currency", min_price_currency)
        add("min_price_value", min_price_value)
        add("raw_path", raw_path)
        add("notes", notes)
        add("created_at", _created_at)

        placeholders = ",".join(["?"] * len(values))
        sql = f"INSERT INTO flights_quotes({','.join(col_names)}) VALUES ({placeholders})"
        self.conn.execute(sql, tuple(values))
'''.lstrip("\n")

s2 = s[:start] + "\n" + replacement + s[end:]
p.write_text(s2, encoding="utf-8")
print("[OK] patched repository.py: insert_flight_quote() now supports url alias")
PY

python3 -m py_compile src/travel_tracker/storage/repository.py
echo "[OK] py_compile passed"
