#!/usr/bin/env python3
"""Sample natural-language clauses from public web corpora into pinyin eval fixtures.

Sources (see https://github.com/wangmuy/awesome-nlp-chinese-corpus), expected in --corpus-dir:
  LREC/ReleasedData/Task1data   SMP2017 ECDT user utterances   -> 口语指令
  dgk_*.conv                    dgk_lost_conv film dialogue     -> 对白
  douban_test.txt               Douban Conversation Corpus      -> 论坛
  toutiao_cat_data.txt          Toutiao news titles             -> 新闻标题
  literature_train.txt          Chinese-Literature-NER-RE       -> 文学

A clause is kept only when two independent readings agree: pypinyin over jieba words and
the dictionary's top-weight reading over forward-maximum-matched words. That drops clauses
whose polyphones cannot be labelled automatically, so labels are trustworthy but the set
under-represents polyphone-heavy text.
"""
import argparse
import glob
import hashlib
import random
import re
import sqlite3
from pathlib import Path

import jieba
from pypinyin import lazy_pinyin

CLAUSE = re.compile(r"[\u4e00-\u9fff]+")
MIN_LEN, MAX_LEN = 5, 14


def clauses(text):
    # Only clauses delimited by punctuation or line ends: a run cut by a digit or Latin
    # letter is a fragment, not something a user would type as one unit.
    for part in re.split(r"[，。！？；：、,.!?;:\s\"“”‘’（）()《》【】\[\]…—~·|/]+", text):
        if MIN_LEN <= len(part) <= MAX_LEN and CLAUSE.fullmatch(part):
            yield part


def read_sources(root: Path):
    smp = []
    for path in sorted(glob.glob(str(root / "LREC/ReleasedData/Task1data/*/*.txt"))):
        for line in open(path, encoding="utf-8", errors="ignore"):
            smp.extend(clauses(line))
    yield "口语指令", smp

    dgk = []
    for path in sorted(glob.glob(str(root / "dgk_*.conv"))):
        for line in open(path, encoding="utf-8", errors="ignore"):
            if line.startswith("M "):
                dgk.extend(clauses(line[2:]))
    yield "对白", dgk

    douban = []
    for line in open(root / "douban_test.txt", encoding="utf-8", errors="ignore"):
        for utterance in line.rstrip("\n").split("\t")[1:]:
            douban.extend(clauses(utterance.replace(" ", "")))
    yield "论坛", douban

    titles = []
    for line in open(root / "toutiao_cat_data.txt", encoding="utf-8", errors="ignore"):
        fields = line.split("_!_")
        if len(fields) > 3:
            titles.extend(clauses(fields[3]))
    yield "新闻标题", titles

    literature, current = [], []
    for line in open(root / "literature_train.txt", encoding="utf-8", errors="ignore"):
        if line.strip():
            current.append(line[0])
        else:
            literature.extend(clauses("".join(current)))
            current = []
    yield "文学", literature


class DictionaryReader:
    def __init__(self, database: Path):
        self.readings = {}
        connection = sqlite3.connect(database)
        for word, pinyin in connection.execute(
            "SELECT word, pinyin FROM entries WHERE length(word) <= 6 ORDER BY weight ASC"
        ):
            self.readings[word] = pinyin.replace("'", "")

    def read(self, text):
        output, index = [], 0
        while index < len(text):
            for size in range(min(6, len(text) - index), 0, -1):
                reading = self.readings.get(text[index:index + size])
                if reading is not None:
                    output.append(reading)
                    index += size
                    break
            else:
                return None
        return "".join(output)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus-dir", type=Path, required=True)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--per-source", type=int, default=400)
    arguments = parser.parse_args()

    reader = DictionaryReader(arguments.database)
    rng = random.Random(20261118)
    dev, test = [], []
    for name, items in read_sources(arguments.corpus_dir):
        unique = sorted(set(items))
        rng.shuffle(unique)
        kept = 0
        for clause in unique:
            if kept == arguments.per_source:
                break
            reading = "".join(lazy_pinyin(jieba.lcut(clause)))
            if not reading.isascii() or reading != reader.read(clause):
                continue
            kept += 1
            bucket = dev if hashlib.md5(clause.encode()).digest()[0] % 2 == 0 else test
            bucket.append(f"{name}\t{reading}\t{clause}")
        print(f"{name}: {len(unique)} unique clauses, kept {kept}")
    for filename, rows in (("web_dev.tsv", dev), ("web_test.tsv", test)):
        (arguments.output_dir / filename).write_text("\n".join(rows) + "\n", encoding="utf-8")
        print(f"{filename}: {len(rows)}")


if __name__ == "__main__":
    main()
