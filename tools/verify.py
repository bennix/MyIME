#!/usr/bin/python3
import sqlite3
import sys
import json

database = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
manifest = json.loads(database.execute("SELECT value FROM meta WHERE key='source_manifest'").fetchone()[0])
manifest_sources = {source["id"] for source in manifest["sources"] if source["kept"] > 0}
checks = {
    "integrity": database.execute("PRAGMA integrity_check").fetchone()[0] == "ok",
    "schema": {"meta", "entries", "language_ngram", "traditional_map"}.issubset({row[0] for row in database.execute("SELECT name FROM sqlite_master WHERE type='table'")}),
    "language_model": database.execute("SELECT count(*) FROM language_ngram").fetchone()[0] >= 200_000,
    "traditional_conversion": database.execute("SELECT count(*) FROM traditional_map").fetchone()[0] >= 50_000,
    "dedup": database.execute("SELECT count(*) FROM entries").fetchone()[0] == database.execute("SELECT count(*) FROM (SELECT DISTINCT word,py_key FROM entries)").fetchone()[0],
    "golden": all(database.execute("SELECT 1 FROM entries WHERE word=? AND py_key=?", item).fetchone() for item in [
        ("你好", "nihao"), ("世界", "shijie"), ("北京", "beijing"), ("中国", "zhongguo"), ("我爱你", "woaini")
    ]),
    "sources": {"rime_ice", "zhwiki", "jingxing", "renfei_dict", "project_seed", "cc_cedict", "jieba", "thuocl"}.issubset(manifest_sources),
    "zhwiki_mask": database.execute("SELECT 1 FROM entries WHERE source_mask & 4 != 0 LIMIT 1").fetchone() is not None,
    "thuocl_mask": database.execute("SELECT 1 FROM entries WHERE source_mask & 1024 != 0 LIMIT 1").fetchone() is not None,
    "thuocl_coverage": all(database.execute("SELECT 1 FROM entries WHERE word=? AND source_mask & 1024 != 0", (word,)).fetchone() for word in [
        "虚拟地址", "有限责任公司", "冬虫夏草", "北京大学", "故作高深"
    ]),
}
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if not all(checks.values()):
    raise SystemExit(1)
