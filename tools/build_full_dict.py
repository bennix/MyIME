#!/usr/bin/python3
"""Merge pinned CC-CEDICT pronunciations with jieba frequencies."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import math
import re
from pathlib import Path


CEDICT_LINE = re.compile(r"^\S+\s+(\S+)\s+\[([^]]+)]")
CHINESE_WORD = re.compile(r"^[\u3400-\u9fff]+$")


def normalize_pinyin(value: str) -> str | None:
    syllables: list[str] = []
    for raw in value.split():
        syllable = raw.lower().replace("u:", "v").replace("ü", "v")
        syllable = re.sub(r"[1-5]$", "", syllable)
        if not syllable or not re.fullmatch(r"[a-z]+", syllable):
            return None
        syllables.append(syllable)
    return "'".join(syllables) if syllables else None


def load_cedict(path: Path) -> dict[str, set[str]]:
    pronunciations: dict[str, set[str]] = {}
    with gzip.open(path, "rt", encoding="utf-8") as source:
        for line in source:
            if line.startswith("#"):
                continue
            match = CEDICT_LINE.match(line)
            if not match:
                continue
            word, raw_pinyin = match.groups()
            pinyin = normalize_pinyin(raw_pinyin)
            if (pinyin and CHINESE_WORD.fullmatch(word) and len(word) <= 12
                    and len(pinyin.split("'")) == len(word)):
                pronunciations.setdefault(word, set()).add(pinyin)
    return pronunciations


def merge_entry(entries: dict[tuple[str, str], tuple[str, int, int]], word: str, pinyin: str,
                weight: int, source_mask: int) -> None:
    key = (word, pinyin.replace("'", ""))
    old_pinyin, old_weight, old_mask = entries.get(key, (pinyin, 0, 0))
    entries[key] = (old_pinyin, max(old_weight, weight), old_mask | source_mask)


def load_rime(paths: list[Path]) -> list[tuple[str, str, int, int]]:
    rows: list[tuple[str, str, int, int]] = []
    for path in paths:
        in_data = False
        with path.open(encoding="utf-8") as source:
            for line in source:
                if not in_data:
                    in_data = line.strip() == "..."
                    continue
                if not line.strip() or line.startswith("#"):
                    continue
                fields = line.rstrip().split("\t")
                if len(fields) < 2:
                    continue
                word = fields[0]
                pinyin = normalize_pinyin(fields[1])
                if (not pinyin or not CHINESE_WORD.fullmatch(word) or len(word) > 12
                        or len(pinyin.split("'")) != len(word)):
                    continue
                weight = int(fields[2]) if len(fields) > 2 and fields[2].isdigit() else 0
                identity = f"{word}\0{pinyin}".encode()
                sample = int.from_bytes(hashlib.blake2b(identity, digest_size=8).digest(), "big")
                if "base" in path.name and weight < 1_000:
                    continue
                if "ext" in path.name and sample % 4 != 0:
                    continue
                if "zhwiki" in path.name and sample % 64 != 0:
                    continue
                source_mask = 4 if "zhwiki" in path.name else 1
                rows.append((word, pinyin, weight, source_mask))
    return rows


def add_word_lists(entries: dict[tuple[str, str], tuple[str, int, int]], specs: list[str],
                   pronunciations: dict[str, set[str]]) -> None:
    for spec in specs:
        mask_text, directory_text = spec.split(":", 1)
        source_mask = int(mask_text)
        for path in Path(directory_text).rglob("*.txt"):
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                word = line.strip()
                if not CHINESE_WORD.fullmatch(word) or len(word) > 12:
                    continue
                for pinyin in pronunciations.get(word, []):
                    merge_entry(entries, word, pinyin, 12_000, source_mask)


def add_thuocl(entries: dict[tuple[str, str], tuple[str, int, int]], directory: Path,
               pronunciations: dict[str, set[str]], rime_rows: list[tuple[str, str, int, int]]) -> None:
    character_readings: dict[str, tuple[int, str]] = {}
    for word, pinyin, weight, _ in rime_rows:
        if len(word) != 1 or "'" in pinyin:
            continue
        if word not in character_readings or weight > character_readings[word][0]:
            character_readings[word] = (weight, pinyin)

    rows: list[tuple[str, int, set[str]]] = []
    for path in sorted(directory.glob("THUOCL_*.txt")):
        for line in path.read_text(encoding="utf-8-sig", errors="strict").splitlines():
            fields = line.split()
            if len(fields) != 2 or not fields[1].isdigit():
                continue
            word, frequency_text = fields
            if not CHINESE_WORD.fullmatch(word) or len(word) > 12:
                continue
            word_pronunciations = pronunciations.get(word)
            if not word_pronunciations:
                inferred = [character_readings.get(character, (0, ""))[1] for character in word]
                if all(inferred):
                    word_pronunciations = {"'".join(inferred)}
            if word_pronunciations:
                rows.append((word, int(frequency_text), word_pronunciations))

    scale = math.log1p(max((frequency for _, frequency, _ in rows), default=1))
    for word, frequency, word_pronunciations in rows:
        weight = round(10_000 + 30_000 * math.log1p(frequency) / scale)
        for pinyin in word_pronunciations:
            merge_entry(entries, word, pinyin, weight, 1024)
    print(f"THUOCL kept {len(rows)} of 157173 rows")


def build(cedict_path: Path, jieba_path: Path, seed_path: Path, output_path: Path,
          rime_paths: list[Path], word_list_specs: list[str], thuocl_dir: Path | None) -> None:
    pronunciations = load_cedict(cedict_path)
    entries: dict[tuple[str, str], tuple[str, int, int]] = {}

    for word, values in pronunciations.items():
        base_weight = min(16_000, 9_000 + len(word) * 700)
        for pinyin in values:
            merge_entry(entries, word, pinyin, base_weight, 256)

    jieba_rows: list[tuple[str, int]] = []
    with jieba_path.open(encoding="utf-8") as source:
        for line in source:
            fields = line.rstrip().split()
            if len(fields) < 2 or fields[0] not in pronunciations:
                continue
            jieba_rows.append((fields[0], int(fields[1])))
    max_frequency = max((frequency for _, frequency in jieba_rows), default=1)
    scale = math.log1p(max_frequency)
    for word, frequency in jieba_rows:
        weight = round(18_000 + 47_535 * math.log1p(frequency) / scale)
        for pinyin in pronunciations[word]:
            merge_entry(entries, word, pinyin, weight, 512)

    rime_rows = load_rime(rime_paths)
    for word, pinyin, _, source_mask in rime_rows:
        if source_mask == 1:
            pronunciations.setdefault(word, set()).add(pinyin)
    max_rime_weight = max((weight for _, _, weight, _ in rime_rows), default=1)
    rime_scale = math.log1p(max_rime_weight)
    for word, pinyin, raw_weight, source_mask in rime_rows:
        weight = 14_000 if raw_weight == 0 else round(22_000 + 43_535 * math.log1p(raw_weight) / rime_scale)
        merge_entry(entries, word, pinyin, weight, source_mask)

    add_word_lists(entries, word_list_specs, pronunciations)
    if thuocl_dir:
        add_thuocl(entries, thuocl_dir, pronunciations, rime_rows)

    for number, line in enumerate(seed_path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 4:
            raise ValueError(f"{seed_path}:{number}: expected four TSV fields")
        word, pinyin, weight, source_mask = fields
        merge_entry(entries, word, pinyin, int(weight), int(source_mask))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="\n") as output:
        for (word, _), (pinyin, weight, source_mask) in sorted(entries.items()):
            output.write(f"{word}\t{pinyin}\t{weight}\t{source_mask}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cedict", type=Path)
    parser.add_argument("jieba", type=Path)
    parser.add_argument("seed", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--rime", type=Path, nargs="*", default=[])
    parser.add_argument("--word-list-dir", nargs="*", default=[])
    parser.add_argument("--thuocl-dir", type=Path)
    args = parser.parse_args()
    build(args.cedict, args.jieba, args.seed, args.output, args.rime, args.word_list_dir, args.thuocl_dir)
