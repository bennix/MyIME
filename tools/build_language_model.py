#!/usr/bin/python3
"""Build character trigrams plus word-level unigram/bigram models from corpora."""

from __future__ import annotations

import argparse
import codecs
import gzip
import heapq
import io
import json
import math
import re
import struct
import zipfile
import zlib
from collections import Counter
from pathlib import Path
from typing import Iterable, TextIO


CHINESE_RUN = re.compile(r"[\u3400-\u9fff]+")
TEXT_FIELDS = ("title", "text", "content", "desc", "answer", "chinese")


def dictionary_rows(path: Path) -> Iterable[tuple[str, int]]:
    with path.open(encoding="utf-8") as source:
        for line in source:
            word, _, weight, _ = line.rstrip("\n").split("\t")
            yield word, max(1, int(weight))


def build_vocab(path: Path) -> tuple[set[str], int, Counter[str]]:
    vocab: set[str] = set()
    seed_counts: Counter[str] = Counter()
    max_len = 1
    for word, weight in dictionary_rows(path):
        vocab.add(word)
        max_len = max(max_len, len(word))
        seed_counts[word] += max(1, weight // 1_000)
    return vocab, min(max_len, 6), seed_counts


def segment_chinese(text: str, vocab: set[str], max_len: int) -> list[str]:
    words: list[str] = []
    index = 0
    length = len(text)
    while index < length:
        matched = False
        upper = min(max_len, length - index)
        for size in range(upper, 0, -1):
            piece = text[index:index + size]
            if piece in vocab:
                words.append(piece)
                index += size
                matched = True
                break
        if not matched:
            words.append(text[index])
            index += 1
    return words


def add_char_trigrams(counts: Counter[str], text: str, weight: int = 1) -> None:
    for run in CHINESE_RUN.findall(text):
        if len(run) < 3:
            continue
        for index in range(len(run) - 2):
            counts[run[index:index + 3]] += weight


def add_word_counts(
    unigrams: Counter[str],
    bigrams: Counter[tuple[str, str]],
    text: str,
    vocab: set[str],
    max_len: int,
    weight: int = 1,
) -> None:
    for run in CHINESE_RUN.findall(text):
        words = segment_chinese(run, vocab, max_len)
        previous = None
        for word in words:
            unigrams[word] += weight
            if previous is not None:
                bigrams[(previous, word)] += weight
            previous = word


def text_streams(path: Path) -> Iterable[TextIO]:
    with path.open("rb") as source:
        signature = source.read(4)
    if signature.startswith(b"PK"):
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                if not name.endswith("/"):
                    with archive.open(name) as source:
                        yield io.TextIOWrapper(source, encoding="utf-8", errors="ignore")
    elif signature.startswith(b"\x1f\x8b"):
        with gzip.open(path, "rt", encoding="utf-8", errors="ignore") as source:
            yield source
    else:
        with path.open(encoding="utf-8", errors="ignore") as source:
            yield source


def partial_zip_lines(path: Path) -> Iterable[str]:
    with path.open("rb") as archive:
        while True:
            header = archive.read(30)
            if len(header) < 30 or header[:4] != b"PK\x03\x04":
                return
            _, _, flags, method, _, _, _, compressed_size, uncompressed_size, name_size, extra_size = struct.unpack(
                "<IHHHHHIIIHH", header
            )
            archive.read(name_size)
            extra = archive.read(extra_size)
            if compressed_size == 0xFFFFFFFF or uncompressed_size == 0xFFFFFFFF:
                cursor = 0
                while cursor + 4 <= len(extra):
                    kind, size = struct.unpack("<HH", extra[cursor:cursor + 4])
                    value = extra[cursor + 4:cursor + 4 + size]
                    cursor += 4 + size
                    if kind != 1:
                        continue
                    value_cursor = 0
                    if uncompressed_size == 0xFFFFFFFF:
                        uncompressed_size = struct.unpack("<Q", value[value_cursor:value_cursor + 8])[0]
                        value_cursor += 8
                    if compressed_size == 0xFFFFFFFF:
                        compressed_size = struct.unpack("<Q", value[value_cursor:value_cursor + 8])[0]
                    break
            if flags & 0x08 or method not in (0, 8):
                return

            decoder = codecs.getincrementaldecoder("utf-8")("ignore")
            decompressor = zlib.decompressobj(-zlib.MAX_WBITS) if method == 8 else None
            remaining = compressed_size
            text_buffer = ""
            complete = True
            while remaining:
                chunk = archive.read(min(1 << 20, remaining))
                if not chunk:
                    complete = False
                    break
                remaining -= len(chunk)
                decoded = decompressor.decompress(chunk) if decompressor else chunk
                text_buffer += decoder.decode(decoded)
                lines = text_buffer.split("\n")
                text_buffer = lines.pop()
                yield from lines
            if complete:
                decoded = decompressor.flush() if decompressor else b""
                text_buffer += decoder.decode(decoded, final=True)
            if text_buffer:
                yield text_buffer
            if not complete:
                return


def texts_from_lines(lines: Iterable[str]) -> Iterable[str]:
    for line in lines:
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            yield line
            continue
        if isinstance(value, dict):
            for field in TEXT_FIELDS:
                text = value.get(field)
                if isinstance(text, str) and text:
                    yield text


def corpus_texts(path: Path) -> Iterable[str]:
    if path.suffix == ".part":
        yield from texts_from_lines(partial_zip_lines(path))
        return
    for source in text_streams(path):
        yield from texts_from_lines(source)


def prune_counter(counter: Counter, keep: int) -> Counter:
    if len(counter) <= keep:
        return counter
    return Counter(dict(counter.most_common(keep)))


def write_normalized(path: Path, items: list[tuple[str, int]]) -> None:
    if not items:
        path.write_text("", encoding="utf-8")
        return
    maximum = max(count for _, count in items)
    denominator = math.log1p(maximum)
    with path.open("w", encoding="utf-8", newline="\n") as destination:
        for key, count in sorted(items, key=lambda item: item[0]):
            destination.write(f"{key}\t{math.log1p(count) / denominator:.8f}\n")


def write_conditional_bigrams(
    path: Path,
    bigrams: Counter[tuple[str, str]],
    unigrams: Counter[str],
    limit: int,
) -> None:
    if not bigrams:
        path.write_text("", encoding="utf-8")
        return
    selected = bigrams.most_common(limit)
    alpha = 0.1
    with path.open("w", encoding="utf-8", newline="\n") as destination:
        for (prev, word), count in sorted(selected, key=lambda item: (item[0][0], item[0][1])):
            previous_count = max(1, unigrams[prev])
            probability = (count + alpha) / (previous_count + alpha * 64)
            score = min(1.0, math.log1p(probability * 100) / math.log1p(100))
            destination.write(f"{prev}\t{word}\t{score:.8f}\n")


def build(
    dictionary: Path,
    corpora: list[Path],
    char_output: Path,
    unigram_output: Path,
    bigram_output: Path,
    char_limit: int,
    unigram_limit: int,
    bigram_limit: int,
) -> None:
    vocab, max_len, seed_unigrams = build_vocab(dictionary)
    char_counts: Counter[str] = Counter()
    unigrams: Counter[str] = Counter(seed_unigrams)
    bigrams: Counter[tuple[str, str]] = Counter()

    for word, weight in seed_unigrams.items():
        add_char_trigrams(char_counts, word, weight)

    seen = 0
    working_char = max(char_limit * 2, char_limit + 50_000)
    working_unigram = max(unigram_limit * 2, unigram_limit + 50_000)
    working_bigram = max(bigram_limit * 2, bigram_limit + 100_000)

    for corpus in corpora:
        for text in corpus_texts(corpus):
            add_char_trigrams(char_counts, text)
            add_word_counts(unigrams, bigrams, text, vocab, max_len)
            seen += 1
            if seen % 100_000 == 0:
                if len(char_counts) > working_char:
                    char_counts = prune_counter(char_counts, working_char)
                if len(unigrams) > working_unigram:
                    unigrams = prune_counter(unigrams, working_unigram)
                if len(bigrams) > working_bigram:
                    bigrams = prune_counter(bigrams, working_bigram)
                print(
                    f"  @{seen}: chars={len(char_counts)} unigrams={len(unigrams)} bigrams={len(bigrams)}",
                    flush=True,
                )
        char_counts = prune_counter(char_counts, working_char)
        unigrams = prune_counter(unigrams, working_unigram)
        bigrams = prune_counter(bigrams, working_bigram)
        print(f"processed {corpus} ({seen} text fields)", flush=True)

    char_output.parent.mkdir(parents=True, exist_ok=True)
    top_chars = char_counts.most_common(char_limit)
    write_normalized(char_output, top_chars)

    top_unigrams = unigrams.most_common(unigram_limit)
    write_normalized(unigram_output, [(word, count) for word, count in top_unigrams])
    write_conditional_bigrams(bigram_output, bigrams, unigrams, bigram_limit)
    print(
        f"wrote {len(top_chars)} char trigrams, {len(top_unigrams)} unigrams, "
        f"{min(bigram_limit, len(bigrams))} bigrams",
        flush=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dictionary", type=Path)
    parser.add_argument("char_output", type=Path)
    parser.add_argument("--unigram-output", type=Path, required=True)
    parser.add_argument("--bigram-output", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, nargs="*", default=[])
    parser.add_argument("--char-limit", type=int, default=300_000)
    parser.add_argument("--unigram-limit", type=int, default=180_000)
    parser.add_argument("--bigram-limit", type=int, default=600_000)
    arguments = parser.parse_args()
    build(
        arguments.dictionary,
        arguments.corpus,
        arguments.char_output,
        arguments.unigram_output,
        arguments.bigram_output,
        arguments.char_limit,
        arguments.unigram_limit,
        arguments.bigram_limit,
    )
