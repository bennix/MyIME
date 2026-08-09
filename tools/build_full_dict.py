#!/usr/bin/python3
"""Merge pinned dictionary sources into MyIME merged.tsv."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import re
from pathlib import Path


CEDICT_LINE = re.compile(r"^\S+\s+(\S+)\s+\[([^]]+)]")
CHINESE_WORD = re.compile(r"^[\u3400-\u9fff]+$")
TONED_SYLLABLE = re.compile(
    r"[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüa-z]+",
    re.IGNORECASE,
)

SOURCE_SC_DICTIONARY = 2048
SOURCE_XINHUA = 4096
SOURCE_SEMANTIC_KB = 8192


def normalize_pinyin(value: str) -> str | None:
    syllables: list[str] = []
    for raw in value.split():
        syllable = raw.lower().replace("u:", "v").replace("ü", "v")
        syllable = re.sub(r"[1-5]$", "", syllable)
        if not syllable or not re.fullmatch(r"[a-z]+", syllable):
            return None
        syllables.append(syllable)
    return "'".join(syllables) if syllables else None


def normalize_toned_pinyin(value: str) -> str | None:
    table = str.maketrans({
        "ā": "a", "á": "a", "ǎ": "a", "à": "a",
        "ē": "e", "é": "e", "ě": "e", "è": "e",
        "ī": "i", "í": "i", "ǐ": "i", "ì": "i",
        "ō": "o", "ó": "o", "ǒ": "o", "ò": "o",
        "ū": "u", "ú": "u", "ǔ": "u", "ù": "u",
        "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v", "ü": "v",
    })
    parts = TONED_SYLLABLE.findall(value.lower())
    if not parts:
        return None
    syllables = []
    for part in parts:
        syllable = part.translate(table)
        syllable = re.sub(r"[1-5]$", "", syllable)
        if not re.fullmatch(r"[a-z]+", syllable):
            return None
        syllables.append(syllable)
    return "'".join(syllables)


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


class TraditionalConverter:
    def __init__(self, phrase_path: Path | None, character_path: Path | None) -> None:
        self.phrases: dict[str, str] = {}
        self.characters: dict[str, str] = {}
        self.max_phrase = 1
        if phrase_path and phrase_path.exists():
            for line in phrase_path.read_text(encoding="utf-8").splitlines():
                if not line or line.startswith("#"):
                    continue
                fields = line.split("\t")
                if len(fields) != 2:
                    continue
                traditional, simplified = fields[0], fields[1].split()[0]
                self.phrases[traditional] = simplified
                self.max_phrase = max(self.max_phrase, len(traditional))
        if character_path and character_path.exists():
            for line in character_path.read_text(encoding="utf-8").splitlines():
                if not line or line.startswith("#"):
                    continue
                fields = line.split("\t")
                if len(fields) != 2:
                    continue
                self.characters[fields[0]] = fields[1].split()[0]

    def convert(self, text: str) -> str:
        if not self.phrases and not self.characters:
            return text
        parts: list[str] = []
        index = 0
        length = len(text)
        while index < length:
            matched = False
            upper = min(self.max_phrase, length - index)
            for size in range(upper, 1, -1):
                piece = text[index:index + size]
                if piece in self.phrases:
                    parts.append(self.phrases[piece])
                    index += size
                    matched = True
                    break
            if matched:
                continue
            char = text[index]
            parts.append(self.characters.get(char, char))
            index += 1
        return "".join(parts)


def pronunciations_for(
    word: str,
    pronunciations: dict[str, set[str]],
    character_readings: dict[str, str],
) -> set[str]:
    if word in pronunciations:
        return pronunciations[word]
    inferred = [character_readings.get(character, "") for character in word]
    if all(inferred):
        return {"'".join(inferred)}
    return set()


def add_word_lists(entries: dict[tuple[str, str], tuple[str, int, int]], specs: list[str],
                   pronunciations: dict[str, set[str]],
                   converter: TraditionalConverter | None = None) -> None:
    # Exact lexicon pronunciations only: character-wise inference on huge sogou dumps
    # creates millions of noisy homophones and bloats the bundled database.
    for spec in specs:
        mask_text, directory_text = spec.split(":", 1)
        source_mask = int(mask_text)
        kept = 0
        for path in Path(directory_text).rglob("*.txt"):
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                word = line.strip()
                if converter:
                    word = converter.convert(word)
                if not CHINESE_WORD.fullmatch(word) or not (1 <= len(word) <= 12):
                    continue
                for pinyin in pronunciations.get(word, []):
                    merge_entry(entries, word, pinyin, 12_000, source_mask)
                    kept += 1
        print(f"word-list mask={source_mask} kept_rows={kept}")


def add_thuocl(entries: dict[tuple[str, str], tuple[str, int, int]], directory: Path,
               pronunciations: dict[str, set[str]], character_readings: dict[str, str]) -> None:
    rows: list[tuple[str, int, set[str]]] = []
    for path in sorted(directory.glob("THUOCL_*.txt")):
        for line in path.read_text(encoding="utf-8-sig", errors="strict").splitlines():
            fields = line.split()
            if len(fields) != 2 or not fields[1].isdigit():
                continue
            word, frequency_text = fields
            if not CHINESE_WORD.fullmatch(word) or len(word) > 12:
                continue
            word_pronunciations = pronunciations_for(word, pronunciations, character_readings)
            if word_pronunciations:
                rows.append((word, int(frequency_text), word_pronunciations))

    scale = math.log1p(max((frequency for _, frequency, _ in rows), default=1))
    for word, frequency, word_pronunciations in rows:
        weight = round(10_000 + 30_000 * math.log1p(frequency) / scale)
        for pinyin in word_pronunciations:
            merge_entry(entries, word, pinyin, weight, 1024)
    print(f"THUOCL kept {len(rows)} of 157173 rows")


def add_sc_dictionary(
    entries: dict[tuple[str, str], tuple[str, int, int]],
    path: Path,
    pronunciations: dict[str, set[str]],
    character_readings: dict[str, str],
    converter: TraditionalConverter,
) -> None:
    kept = 0
    seen: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        word = converter.convert(line.strip())
        if not CHINESE_WORD.fullmatch(word) or not (2 <= len(word) <= 12):
            continue
        if word in seen:
            continue
        seen.add(word)
        exact = pronunciations.get(word, set())
        # Infer short words only; long inferred phrases are usually wrong for IME ranking.
        candidates = exact if exact or len(word) > 4 else pronunciations_for(word, pronunciations, character_readings)
        for pinyin in candidates:
            merge_entry(entries, word, pinyin, 11_000, SOURCE_SC_DICTIONARY)
            kept += 1
    print(f"sc-dictionary unique_words={len(seen)} kept_rows={kept}")


def add_chinese_xinhua(
    entries: dict[tuple[str, str], tuple[str, int, int]],
    data_dir: Path,
    pronunciations: dict[str, set[str]],
    character_readings: dict[str, str],
) -> None:
    idiom_path = data_dir / "idiom.json"
    ci_path = data_dir / "ci.json"
    word_path = data_dir / "word.json"
    idiom_kept = ci_kept = char_kept = 0

    if idiom_path.exists():
        for item in json.loads(idiom_path.read_text(encoding="utf-8")):
            word = item.get("word", "")
            pinyin = normalize_toned_pinyin(item.get("pinyin", ""))
            if (not pinyin or not CHINESE_WORD.fullmatch(word) or len(word) > 12
                    or len(pinyin.split("'")) != len(word)):
                continue
            merge_entry(entries, word, pinyin, 18_000, SOURCE_XINHUA)
            pronunciations.setdefault(word, set()).add(pinyin)
            idiom_kept += 1

    if word_path.exists():
        for item in json.loads(word_path.read_text(encoding="utf-8")):
            word = item.get("word", "")
            pinyin = normalize_toned_pinyin(item.get("pinyin", ""))
            if not pinyin or not CHINESE_WORD.fullmatch(word) or len(word) != 1:
                continue
            merge_entry(entries, word, pinyin, 14_000, SOURCE_XINHUA)
            pronunciations.setdefault(word, set()).add(pinyin)
            character_readings.setdefault(word, pinyin)
            char_kept += 1

    if ci_path.exists():
        for item in json.loads(ci_path.read_text(encoding="utf-8")):
            word = item.get("ci", "")
            if not CHINESE_WORD.fullmatch(word) or not (2 <= len(word) <= 12):
                continue
            for pinyin in pronunciations_for(word, pronunciations, character_readings):
                merge_entry(entries, word, pinyin, 12_500, SOURCE_XINHUA)
                ci_kept += 1

    print(f"chinese-xinhua idioms={idiom_kept} chars={char_kept} ci_rows={ci_kept}")


def add_semantic_kb(
    entries: dict[tuple[str, str], tuple[str, int, int]],
    dict_dir: Path,
    pronunciations: dict[str, set[str]],
    character_readings: dict[str, str],
    converter: TraditionalConverter,
) -> None:
    words: set[str] = set()

    def absorb(raw: str) -> None:
        word = converter.convert(raw.strip())
        if CHINESE_WORD.fullmatch(word) and 1 <= len(word) <= 12:
            words.add(word)

    synonym = dict_dir / "同义关系库.txt"
    antonym = dict_dir / "反义关系库.txt"
    abstract = dict_dir / "抽象关系库.txt"
    abbrev = dict_dir / "简称关系库.txt"
    for path, kind in (
        (synonym, "同义"),
        (abstract, "抽象"),
        (abbrev, "简称"),
    ):
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            fields = line.split(",")
            if len(fields) != 3 or fields[1] != kind:
                continue
            absorb(fields[0])
            absorb(fields[2])

    if antonym.exists():
        for line in antonym.read_text(encoding="utf-8").splitlines():
            if "@" not in line:
                continue
            left, right = line.split("@", 1)
            absorb(left)
            absorb(right)

    for name in ("节日时间词.txt", "否定词.txt", "情态词.txt", "程度副词.txt", "修饰副词.txt", "数量介词.txt", "量比词.txt"):
        path = dict_dir / name
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            fields = re.split(r"[\s,，]+", line.strip())
            if fields:
                absorb(fields[0])

    kept = 0
    for word in words:
        exact = pronunciations.get(word, set())
        candidates = exact if exact or len(word) > 4 else pronunciations_for(word, pronunciations, character_readings)
        for pinyin in candidates:
            merge_entry(entries, word, pinyin, 10_500, SOURCE_SEMANTIC_KB)
            kept += 1
    print(f"ChineseSemanticKB unique_words={len(words)} kept_rows={kept}")


def build_character_readings(
    pronunciations: dict[str, set[str]],
    rime_rows: list[tuple[str, str, int, int]],
) -> dict[str, str]:
    character_readings: dict[str, tuple[int, str]] = {}
    for word, pinyin, weight, _ in rime_rows:
        if len(word) != 1 or "'" in pinyin:
            continue
        if word not in character_readings or weight > character_readings[word][0]:
            character_readings[word] = (weight, pinyin)
    readings = {word: pinyin for word, (_, pinyin) in character_readings.items()}
    for word, values in pronunciations.items():
        if len(word) == 1 and word not in readings and values:
            readings[word] = sorted(values)[0]
    return readings


def build(
    cedict_path: Path,
    jieba_path: Path,
    seed_path: Path,
    output_path: Path,
    rime_paths: list[Path],
    word_list_specs: list[str],
    thuocl_dir: Path | None,
    sc_dictionary: Path | None,
    xinhua_dir: Path | None,
    semantic_kb_dir: Path | None,
    opencc_ts_phrases: Path | None,
    opencc_ts_characters: Path | None,
) -> None:
    pronunciations = load_cedict(cedict_path)
    entries: dict[tuple[str, str], tuple[str, int, int]] = {}
    converter = TraditionalConverter(opencc_ts_phrases, opencc_ts_characters)

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

    character_readings = build_character_readings(pronunciations, rime_rows)
    add_word_lists(entries, word_list_specs, pronunciations, converter)
    if thuocl_dir:
        add_thuocl(entries, thuocl_dir, pronunciations, character_readings)
    if xinhua_dir:
        add_chinese_xinhua(entries, xinhua_dir, pronunciations, character_readings)
        character_readings = build_character_readings(pronunciations, rime_rows)
    if sc_dictionary:
        add_sc_dictionary(entries, sc_dictionary, pronunciations, character_readings, converter)
    if semantic_kb_dir:
        add_semantic_kb(entries, semantic_kb_dir, pronunciations, character_readings, converter)

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
    print(f"merged entries={len(entries)} -> {output_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cedict", type=Path)
    parser.add_argument("jieba", type=Path)
    parser.add_argument("seed", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--rime", type=Path, nargs="*", default=[])
    parser.add_argument("--word-list-dir", nargs="*", default=[])
    parser.add_argument("--thuocl-dir", type=Path)
    parser.add_argument("--sc-dictionary", type=Path)
    parser.add_argument("--xinhua-dir", type=Path)
    parser.add_argument("--semantic-kb-dir", type=Path)
    parser.add_argument("--opencc-ts-phrases", type=Path)
    parser.add_argument("--opencc-ts-characters", type=Path)
    args = parser.parse_args()
    build(
        args.cedict,
        args.jieba,
        args.seed,
        args.output,
        args.rime,
        args.word_list_dir,
        args.thuocl_dir,
        args.sc_dictionary,
        args.xinhua_dir,
        args.semantic_kb_dir,
        args.opencc_ts_phrases,
        args.opencc_ts_characters,
    )
