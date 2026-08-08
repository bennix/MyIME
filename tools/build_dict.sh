#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$ROOT_DIR/build/dictionary"
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
PYTHON_BIN=${PYTHON_BIN:-/usr/bin/python3}
export SOURCE_DATE_EPOCH

mkdir -p "$BUILD_DIR"
CEDICT="$BUILD_DIR/cedict_1_0_ts_utf-8_mdbg.txt.gz"
JIEBA="$BUILD_DIR/jieba-dict.txt"
RIME_COMMIT=569ff3bc65dd4aec0a26b33c49c8bbdfa8b5fd57
THUOCL_COMMIT=a30ce79d895d01ab5132a5c74c29703ff7efb4cc
ZHWIKI="$BUILD_DIR/zhwiki-20260416.dict.yaml"
if [ ! -f "$CEDICT" ]; then
  curl -L --fail --silent --show-error \
    https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz \
    -o "$CEDICT"
fi
if [ ! -f "$JIEBA" ]; then
  curl -L --fail --silent --show-error \
    https://raw.githubusercontent.com/fxsjy/jieba/67fa2e36e72f69d9134b8a1037b83fbb070b9775/jieba/dict.txt \
    -o "$JIEBA"
fi
for name in base ext others 8105; do
  path="$BUILD_DIR/rime-ice-$name.dict.yaml"
  if [ ! -f "$path" ]; then
    curl -L --fail --silent --show-error \
      "https://raw.githubusercontent.com/iDvel/rime-ice/$RIME_COMMIT/cn_dicts/$name.dict.yaml" \
      -o "$path"
  fi
done
if [ ! -f "$ZHWIKI" ]; then
  curl -L --fail --silent --show-error \
    https://github.com/felixonmars/fcitx5-pinyin-zhwiki/releases/download/0.3.0/zhwiki-20260416.dict.yaml \
    -o "$ZHWIKI"
fi
if [ ! -d "$BUILD_DIR/Jinghang-Dictionary/.git" ]; then
  git clone --quiet https://github.com/kkhkl/Jinghang-Dictionary.git "$BUILD_DIR/Jinghang-Dictionary"
fi
git -C "$BUILD_DIR/Jinghang-Dictionary" checkout --quiet 4ee6f087f33ef5e6cede360277930e296881f11e
if [ ! -d "$BUILD_DIR/renfei-dict/.git" ]; then
  git clone --quiet https://github.com/renfei/dict.git "$BUILD_DIR/renfei-dict"
fi
git -C "$BUILD_DIR/renfei-dict" checkout --quiet f85efb9ffc788c7d79112448aed11b2225b3e0ac
if [ ! -d "$BUILD_DIR/THUOCL/.git" ]; then
  git clone --quiet https://github.com/thunlp/THUOCL.git "$BUILD_DIR/THUOCL"
fi
git -C "$BUILD_DIR/THUOCL" checkout --quiet "$THUOCL_COMMIT"
echo "d722c784cab3b3b346d09672aab46533f95e0e0c163d6040854ef76ca8e9504a  $CEDICT" | shasum -a 256 -c
echo "7197c3211ddd98962b036cdf40324d1ea2bfaa12bd028e68faa70111a88e12a8  $JIEBA" | shasum -a 256 -c
echo "0f21c76937ac42973dba4d8d26cfb80f03e0da0069af01ad2496fc5cfc9bb36d  $BUILD_DIR/rime-ice-base.dict.yaml" | shasum -a 256 -c
echo "c800e7a52d60050ebdfcad7f309fc3c941a1e6f721e36e3c797bec6316e886c1  $BUILD_DIR/rime-ice-ext.dict.yaml" | shasum -a 256 -c
echo "6a6b1a77d94c7cdf9203cf426e67f350215d2d73259fe3769c97d2a18f521c28  $BUILD_DIR/rime-ice-others.dict.yaml" | shasum -a 256 -c
echo "ea30c3a7e37fd516fa0f894b33bfd7b8e855f14ae263ba84db763fed633c2d32  $BUILD_DIR/rime-ice-8105.dict.yaml" | shasum -a 256 -c
echo "5c140e462f9c00a119500b7fec0d3b927f0f83920001a7ea408e26748d09ea07  $ZHWIKI" | shasum -a 256 -c

MERGED="$BUILD_DIR/merged.tsv"
"$PYTHON_BIN" "$SCRIPT_DIR/build_full_dict.py" \
  "$CEDICT" "$JIEBA" "$SCRIPT_DIR/seed.tsv" "$MERGED" \
  --rime "$BUILD_DIR/rime-ice-base.dict.yaml" "$BUILD_DIR/rime-ice-ext.dict.yaml" \
    "$BUILD_DIR/rime-ice-others.dict.yaml" "$BUILD_DIR/rime-ice-8105.dict.yaml" "$ZHWIKI" \
  --word-list-dir "8:$BUILD_DIR/Jinghang-Dictionary/中文词库语料" \
    "32:$BUILD_DIR/renfei-dict/sogou" \
  --thuocl-dir "$BUILD_DIR/THUOCL/data"
CORPUS_DIR="$ROOT_DIR/build/sources/brightmart"
"$PYTHON_BIN" "$SCRIPT_DIR/build_language_model.py" \
  "$MERGED" "$BUILD_DIR/language_model.tsv" \
  --corpus "$CORPUS_DIR/wiki2019zh.download" \
    "$CORPUS_DIR/news2016zh.sample.part" \
    "$CORPUS_DIR/baike2018qa.sample.part" \
    "$CORPUS_DIR/webtext2019zh.sample.part" \
    "$CORPUS_DIR/translation2019zh.download"
"$PYTHON_BIN" "$SCRIPT_DIR/compile.py" \
  "$MERGED" \
  "$ROOT_DIR/MyIME/MyIME/Resources/system.sqlite" \
  --language-model "$BUILD_DIR/language_model.tsv"
"$PYTHON_BIN" "$SCRIPT_DIR/verify.py" "$ROOT_DIR/MyIME/MyIME/Resources/system.sqlite"
