#!/usr/bin/env python3
"""Add CC-CEDICT English definitions to an existing MyIME dictionary.

Uses the same pinned CC BY-SA 4.0 source as the pronunciation pipeline.
Only exact simplified headwords are matched; no sentence translation is inferred.
"""
import argparse
import gzip
import hashlib
import re
import sqlite3
from pathlib import Path


def definitions(path):
    result = {}
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        for line in stream:
            match = re.match(r"\S+ (\S+) \[[^]]+\] /(.*)/\s*$", line)
            if not match:
                continue
            word, senses = match.groups()
            for sense in senses.split("/"):
                # References and grammatical annotations aren't translations.
                if re.search(r"^(CL:|variant of|old variant|see |also written|surname |used |particle|grammatical)", sense, re.I):
                    continue
                if re.search(r"[\u3400-\u9fff]|\[[^]]+\]", sense):
                    continue
                sense = re.sub(r"\s*\([^)]*\)", "", sense).strip()
                if sense and len(sense) <= 100:
                    result.setdefault(word, sense)
                    break
    return result


def enrich(database, source):
    glossary = definitions(source)
    with sqlite3.connect(database) as connection:
        words = {row[0] for row in connection.execute("SELECT DISTINCT word FROM entries")}
        before = connection.execute("SELECT count(*) FROM gloss_en").fetchone()[0]
        rows = [(word, gloss) for word, gloss in sorted(glossary.items()) if word in words]
        connection.executemany("INSERT OR REPLACE INTO gloss_en(word,gloss) VALUES(?,?)", rows)
        after = connection.execute("SELECT count(*) FROM gloss_en").fetchone()[0]
        connection.executemany("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [
            ("english_gloss_count", str(after)),
            ("cedict_gloss_count", str(len(rows))),
            ("cedict_gloss_sha256", hashlib.sha256(source.read_bytes()).hexdigest()),
        ])
        assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    print(f"CC-CEDICT exact headwords: {len(rows)}; gloss coverage: {before} -> {after}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("cedict", type=Path)
    args = parser.parse_args()
    enrich(args.database, args.cedict)
