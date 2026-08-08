#!/usr/bin/python3
"""Compile validated merged TSV into the deterministic MyIME SQLite schema."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path


SCHEMA = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE entries(
  id INTEGER PRIMARY KEY,
  word TEXT NOT NULL,
  pinyin TEXT NOT NULL,
  py_key TEXT NOT NULL,
  initials TEXT NOT NULL,
  weight INTEGER NOT NULL CHECK(weight BETWEEN 0 AND 65535),
  source_mask INTEGER NOT NULL
);
CREATE UNIQUE INDEX idx_word_pykey ON entries(word, py_key);
CREATE INDEX idx_pykey ON entries(py_key);
CREATE INDEX idx_pyprefix ON entries(py_key, weight DESC);
CREATE INDEX idx_initials ON entries(initials, weight DESC);
CREATE TABLE language_ngram(ngram TEXT PRIMARY KEY, score REAL NOT NULL);
"""

SOURCES = (
    ("rime_ice", 1, "GPL-3.0"),
    ("zhwiki", 4, "Unlicense-and-Wikimedia-terms"),
    ("jingxing", 8, "Jinghang-custom-2025-2026.5"),
    ("renfei_dict", 32, "MIT"),
    ("project_seed", 128, "project-authored"),
    ("cc_cedict", 256, "CC-BY-SA-4.0"),
    ("jieba", 512, "MIT"),
    ("thuocl", 1024, "MIT"),
)


def load(path: Path) -> list[tuple[str, str, str, str, int, int]]:
    rows: dict[tuple[str, str], tuple[str, str, str, str, int, int]] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 4:
            raise ValueError(f"{path}:{number}: expected four TSV fields")
        word, pinyin, weight_text, mask_text = fields
        if not word or not pinyin or any(c not in "abcdefghijklmnopqrstuvwxyz'" for c in pinyin):
            raise ValueError(f"{path}:{number}: invalid word or pinyin")
        weight, mask = int(weight_text), int(mask_text)
        py_key = pinyin.replace("'", "")
        initials = "".join(part[0] for part in pinyin.split("'") if part)
        rows[(word, py_key)] = (word, pinyin, py_key, initials, weight, mask)
    return sorted(rows.values(), key=lambda row: (row[0], row[2]))


def compile_database(source: Path, output: Path, language_model: Path | None = None) -> None:
    rows = load(source)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    built_at = datetime.fromtimestamp(epoch, timezone.utc).isoformat()
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix="system-", suffix=".sqlite", dir=output.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        connection = sqlite3.connect(temporary)
        connection.executescript("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;" + SCHEMA)
        connection.executemany(
            "INSERT INTO entries(word,pinyin,py_key,initials,weight,source_mask) VALUES(?,?,?,?,?,?)",
            rows,
        )
        if language_model:
            language_rows = []
            for number, line in enumerate(language_model.read_text(encoding="utf-8").splitlines(), 1):
                fields = line.split("\t")
                if len(fields) != 2 or len(fields[0]) not in (2, 3):
                    raise ValueError(f"{language_model}:{number}: invalid language model row")
                language_rows.append((fields[0], float(fields[1])))
            connection.executemany("INSERT INTO language_ngram VALUES(?,?)", language_rows)
        manifest = {"sources": [
            {
                "id": source_id,
                "license": license_name,
                "kept": sum(1 for row in rows if row[5] & source_mask),
            }
            for source_id, source_mask, license_name in SOURCES
        ]}
        connection.executemany("INSERT INTO meta VALUES(?,?)", [
            ("schema_version", "2"), ("build_hash", digest),
            ("source_manifest", json.dumps(manifest, ensure_ascii=False, sort_keys=True)),
            ("entry_count", str(len(rows))),
            ("language_ngram_count", str(len(language_rows) if language_model else 0)),
            ("built_at", built_at),
        ])
        connection.commit()
        connection.execute("PRAGMA optimize")
        connection.execute("VACUUM")
        result = connection.execute("PRAGMA integrity_check").fetchone()[0]
        connection.close()
        if result != "ok":
            raise RuntimeError(f"integrity_check failed: {result}")
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--language-model", type=Path)
    arguments = parser.parse_args()
    compile_database(arguments.input, arguments.output, arguments.language_model)
