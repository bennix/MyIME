#!/usr/bin/python3
"""Build a compact Chinese bigram/trigram model from dictionaries and JSONL corpora."""

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


def add_text(counts: dict[int, Counter[str]], text: str, weight: int = 1) -> None:
    for run in CHINESE_RUN.findall(text):
        for order in (3,):
            for index in range(len(run) - order + 1):
                counts[order][run[index:index + order]] += weight


def dictionary_texts(path: Path) -> Iterable[tuple[str, int]]:
    with path.open(encoding="utf-8") as source:
        for line in source:
            word, _, weight, _ = line.rstrip("\n").split("\t")
            yield word, max(1, int(weight) // 1_000)


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


def prune(counter: Counter[str], keep: int, required: set[str]) -> Counter[str]:
    if len(counter) <= keep:
        return counter
    selected = dict(heapq.nlargest(keep, counter.items(), key=lambda item: (item[1], item[0])))
    selected.update({ngram: counter[ngram] for ngram in required if ngram in counter})
    return Counter(selected)


def build(dictionary: Path, corpora: list[Path], output: Path, limit: int) -> None:
    counts = {3: Counter()}
    for word, weight in dictionary_texts(dictionary):
        add_text(counts, word, weight)
    required = {
        order: {ngram for ngram, _ in heapq.nlargest(limit, counter.items(), key=lambda item: (item[1], item[0]))}
        for order, counter in counts.items()
    }

    seen = 0
    for corpus in corpora:
        for text in corpus_texts(corpus):
            add_text(counts, text)
            seen += 1
            if seen % 250_000 == 0:
                counts = {order: prune(counter, limit * 3, required[order]) for order, counter in counts.items()}
        print(f"processed {corpus} ({seen} text fields)")

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="\n") as destination:
        for order in (3,):
            top = heapq.nlargest(limit, counts[order].items(), key=lambda item: (item[1], item[0]))
            selected = {ngram: count for ngram, count in top}
            selected.update({ngram: counts[order][ngram] for ngram in required[order]})
            maximum = max(selected.values(), default=1)
            denominator = math.log1p(maximum)
            for ngram, count in sorted(selected.items()):
                destination.write(f"{ngram}\t{math.log1p(count) / denominator:.8f}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dictionary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--corpus", type=Path, nargs="*", default=[])
    parser.add_argument("--limit", type=int, default=200_000)
    arguments = parser.parse_args()
    build(arguments.dictionary, arguments.corpus, arguments.output, arguments.limit)
