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
CREATE TABLE word_unigram(word TEXT PRIMARY KEY, score REAL NOT NULL);
CREATE TABLE word_bigram(
  prev TEXT NOT NULL,
  word TEXT NOT NULL,
  score REAL NOT NULL,
  PRIMARY KEY(prev, word)
);
CREATE INDEX idx_word_bigram_prev ON word_bigram(prev, score DESC);
CREATE TABLE traditional_map(
  simplified TEXT PRIMARY KEY,
  traditional TEXT NOT NULL
);
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
    ("sc_dictionary", 2048, "CC-BY-3.0"),
    ("chinese_xinhua", 4096, "MIT"),
    ("chinese_semantic_kb", 8192, "upstream-no-SPDX-author-attribution"),
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


def load_opencc(paths: list[Path]) -> list[tuple[str, str]]:
    mappings: dict[str, str] = {}
    for path in paths:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 2 or not fields[0] or not fields[1]:
                raise ValueError(f"{path}:{number}: invalid OpenCC mapping")
            mappings[fields[0]] = fields[1].split()[0]
    return sorted(mappings.items())


def load_score_tsv(path: Path | None, columns: int) -> list[tuple]:
    if path is None or not path.exists():
        return []
    rows = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != columns:
            raise ValueError(f"{path}:{number}: expected {columns} columns")
        if columns == 2:
            if not fields[0]:
                raise ValueError(f"{path}:{number}: empty key")
            rows.append((fields[0], float(fields[1])))
        else:
            if not fields[0] or not fields[1]:
                raise ValueError(f"{path}:{number}: empty bigram key")
            rows.append((fields[0], fields[1], float(fields[2])))
    return rows


def recalibrate_weights(
    rows: list[tuple[str, str, str, str, int, int]],
    unigrams: list[tuple[str, float]],
) -> list[tuple[str, str, str, str, int, int]]:
    if not unigrams:
        return rows
    scores = {word: score for word, score in unigrams}
    recalibrated = []
    for word, pinyin, py_key, initials, weight, mask in rows:
        corpus = scores.get(word)
        if corpus is None:
            # High-weight multi-character words the corpus never produced are
            # dictionary noise; damp them so they stop crowding SQL pre-selection.
            if len(word) >= 2 and weight > 20_000:
                weight = 20_000 + int((weight - 20_000) * 0.55)
            recalibrated.append((word, pinyin, py_key, initials, weight, mask))
            continue
        # Blend dictionary weight with corpus unigram evidence.
        blended = int(round(weight * 0.55 + corpus * 65_535 * 0.45))
        recalibrated.append((word, pinyin, py_key, initials, max(1, min(65_535, blended)), mask))
    return recalibrated


def compile_database(
    source: Path,
    output: Path,
    language_model: Path | None = None,
    unigram_model: Path | None = None,
    bigram_model: Path | None = None,
    opencc_paths: list[Path] | None = None,
) -> None:
    rows = load(source)
    traditional_rows = load_opencc(opencc_paths or [])
    language_rows = load_score_tsv(language_model, 2)
    if language_rows and any(len(row[0]) not in (2, 3) for row in language_rows):
        raise ValueError("character language model rows must be 2 or 3 characters")
    unigram_rows = load_score_tsv(unigram_model, 2)
    bigram_rows = load_score_tsv(bigram_model, 3)
    rows = recalibrate_weights(rows, unigram_rows)
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
        connection.executemany("INSERT INTO language_ngram VALUES(?,?)", language_rows)
        connection.executemany("INSERT INTO word_unigram VALUES(?,?)", unigram_rows)
        connection.executemany("INSERT INTO word_bigram VALUES(?,?,?)", bigram_rows)
        connection.executemany("INSERT INTO traditional_map VALUES(?,?)", traditional_rows)
        manifest = {"sources": [
            {
                "id": source_id,
                "license": license_name,
                "kept": sum(1 for row in rows if row[5] & source_mask),
            }
            for source_id, source_mask, license_name in SOURCES
        ]}
        connection.executemany("INSERT INTO meta VALUES(?,?)", [
            ("schema_version", "4"), ("build_hash", digest),
            ("source_manifest", json.dumps(manifest, ensure_ascii=False, sort_keys=True)),
            ("entry_count", str(len(rows))),
            ("language_ngram_count", str(len(language_rows))),
            ("word_unigram_count", str(len(unigram_rows))),
            ("word_bigram_count", str(len(bigram_rows))),
            ("traditional_mapping_count", str(len(traditional_rows))),
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
    parser.add_argument("--unigram-model", type=Path)
    parser.add_argument("--bigram-model", type=Path)
    parser.add_argument("--opencc", type=Path, nargs="*", default=[])
    arguments = parser.parse_args()
    compile_database(
        arguments.input,
        arguments.output,
        arguments.language_model,
        arguments.unigram_model,
        arguments.bigram_model,
        arguments.opencc,
    )
