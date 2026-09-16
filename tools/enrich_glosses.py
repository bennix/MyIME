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
                    # CC-CEDICT may list a proper-name reading before the
                    # everyday one (e.g. 水: "Shui ethnic group" before water).
                    penalty = 0
                    if re.search(r"\b(surname|ethnic group|place name|River|Mount|province|county)\b", sense, re.I):
                        penalty = 100
                    score = (penalty, len(sense), sense.lower())
                    previous = result.get(word)
                    if previous is None or score < previous[0]:
                        result[word] = (score, sense)
    return {word: item[1] for word, item in result.items()}


def preferred_glosses(path, words):
    rows = {}
    if path is None:
        return rows
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 2 or not fields[0] or not fields[1]:
            raise ValueError(f"{path}:{number}: expected word and gloss")
        if fields[0] in words:
            rows.setdefault(fields[0], " · ".join(fields[1:3]))
    return rows


def enrich(database, source, preferred=None):
    glossary = definitions(source)
    with sqlite3.connect(database) as connection:
        words = {row[0] for row in connection.execute("SELECT DISTINCT word FROM entries")}
        original = preferred_glosses(preferred, words)
        # Curated source annotations always win. CC-CEDICT fills only words
        # without a supplied gloss, preserving the intended common meaning.
        connection.executemany("INSERT OR REPLACE INTO gloss_en(word,gloss) VALUES(?,?)", sorted(original.items()))
        before = len(original)
        rows = [(word, gloss) for word, gloss in sorted(glossary.items()) if word in words and word not in original]
        connection.executemany("INSERT OR IGNORE INTO gloss_en(word,gloss) VALUES(?,?)", rows)
        after = connection.execute("SELECT count(*) FROM gloss_en").fetchone()[0]
        connection.executemany("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [
            ("english_gloss_count", str(after)),
            ("cedict_gloss_count", str(len(rows))),
            ("cedict_gloss_sha256", hashlib.sha256(source.read_bytes()).hexdigest()),
        ])
        assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    print(f"Curated glosses: {before}; CC-CEDICT additions: {len(rows)}; coverage: {after}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("cedict", type=Path)
    parser.add_argument("--preferred", type=Path)
    args = parser.parse_args()
    enrich(args.database, args.cedict, args.preferred)
