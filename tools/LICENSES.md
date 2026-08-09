# Dictionary source licenses

The bundled `system.sqlite` is an adapted offline dictionary built on 2026-08-08 from the
following pinned sources. MyIME removes tone numbers, uses the simplified word form, combines
frequency values, and compiles the result into SQLite.

## CC-CEDICT

- Publisher: MDBG
- Source: https://www.mdbg.net/chinese/dictionary?page=cc-cedict
- Artifact date: 2026-08-07T08:04:28Z
- License: Creative Commons Attribution-ShareAlike 4.0 International
- License text: https://creativecommons.org/licenses/by-sa/4.0/
- Copyright referenced by upstream: CEDICT, Copyright 1997–1998 Paul Andrew Denisowski

The adapted dictionary data is distributed under CC BY-SA 4.0. The attribution and ShareAlike
terms apply to the dictionary data, not to independently written MyIME program code.

## jieba dictionary frequencies

- Project: jieba by Sun Junyi
- Source: https://github.com/fxsjy/jieba
- Revision: `67fa2e36e72f69d9134b8a1037b83fbb070b9775`
- License: MIT

Copyright (c) 2013 Sun Junyi

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the conditions in the upstream MIT license.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

## Rime Ice dictionary

- Project: Rime Ice by iDvel and contributors
- Source: https://github.com/iDvel/rime-ice
- Revision: `569ff3bc65dd4aec0a26b33c49c8bbdfa8b5fd57`
- Included data: `cn_dicts/base`, `ext`, `others`, and `8105`
- License: GNU General Public License version 3

MyIME converts the selected Rime Ice entries to its SQLite schema and marks this as modified
dictionary data. The corresponding source revision, conversion script, and exact checksums are
listed in `tools/SOURCES.lock`. A copy of GPL-3.0 is bundled with the application.

## fcitx5-pinyin-zhwiki

- Source: https://github.com/felixonmars/fcitx5-pinyin-zhwiki
- Revision: `cb1073ce2042ab431c872da7699d62ed8b857cff`
- Artifact: `zhwiki-20260416.dict.yaml`
- Repository license: Unlicense
- Generated dictionary terms follow the Wikimedia source terms described at
  https://dumps.wikimedia.org/legal.html

## Jinghang Dictionary

- Source: https://github.com/kkhkl/Jinghang-Dictionary
- Revision: `4ee6f087f33ef5e6cede360277930e296881f11e`
- License: Jinghang custom license 2025–2026.5

MyIME includes a clearly identified derived data set, not an unmodified or official Jinghang
release. The upstream terms permit derivative data with that identification and attribution.

## renfei/dict

- Copyright (c) 2022 Ren Fei
- Source: https://github.com/renfei/dict
- Revision: `f85efb9ffc788c7d79112448aed11b2225b3e0ac`
- License: MIT

## THUOCL (Tsinghua Open Chinese Lexicon)

- Copyright (c) 2018 THUNLP
- Source: https://github.com/thunlp/THUOCL
- Revision: `a30ce79d895d01ab5132a5c74c29703ff7efb4cc`
- License: MIT

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to inclusion of the copyright and permission notice.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

## NLP Chinese Corpus

- Project: NLP Chinese Corpus by Bright Xu / brightmart
- Source: https://github.com/brightmart/nlp_chinese_corpus
- Revision: `5dc872154777d24c897f957f1ec848fc7fd59aa9`
- DOI: https://doi.org/10.5281/zenodo.3402023
- Included training sources: wiki2019zh, news2016zh, baike2018qa, webtext2019zh,
  and the Chinese side of translation2019zh
- Repository license: MIT

MyIME does not bundle the original articles, questions, answers, or translations. It streams the
corpora during the dictionary build and distributes only a compact, normalized trigram frequency
model used to rank homophonic sentence candidates. Original texts retain the rights and source
terms of their respective Wikipedia, news, community, encyclopedia, and translation providers.

## OpenCC conversion data

- Project: Open Chinese Convert (OpenCC)
- Source: https://github.com/BYVoid/OpenCC
- Revision: `81223ed87ae53283ef518e2deac34b7971f8a39e`
- Included data: `STPhrases.txt`, `STCharacters.txt`, `TSPhrases.txt`, and `TSCharacters.txt`
- License: Apache License 2.0

`ST*` mappings are compiled into `system.sqlite` for simplified-to-traditional output conversion.
`TS*` mappings are used only at dictionary build time to normalize traditional source words to
simplified before merge.

## sc-dictionary

- Source: https://github.com/samejack/sc-dictionary
- Revision: `e057977284ed40f15765d3b97808e34fae98480e`
- License: Creative Commons Attribution 3.0 Unported (CC BY 3.0)

MyIME converts traditional forms to simplified, keeps words of length 2–12 with recoverable
pinyin, and merges them into the offline candidate lexicon with attribution.

## chinese-xinhua

- Copyright (c) 2018 PWXCOO
- Source: https://github.com/pwxcoo/chinese-xinhua
- Revision: `fe6d6c2e8baa82187f4c96bbe042e43f96c05666`
- License: MIT

MyIME imports idioms (with provided pinyin), single-character readings, and common words from
`data/idiom.json`, `data/word.json`, and `data/ci.json`. Xiehouyu punchlines are not imported as
IME candidates.

## ChineseSemanticKB

- Author: Liu Huanyong
- Source: https://github.com/liuhuanyong/ChineseSemanticKB
- Revision: `2379ce44aee1a6aa696521efa4ae653df6dab0b9`
- License: no SPDX / GitHub license field at the pinned revision

The upstream README presents the data as an open Chinese semantic resource and asks consumers to
respect the open-source intent rather than republish a secondary standalone database. MyIME
extracts Chinese surface words from synonym, antonym, abbreviation, abstraction, and small closed
class lists for offline IME recall only, with author attribution recorded here. If upstream later
publishes a conflicting license, this source MUST be re-reviewed under `docs/DICTIONARY_PIPELINE.md`.

## Sources retained locally but not bundled

The following requested source snapshots are present under `build/sources`, but their repositories
do not contain an explicit redistribution license at the pinned revision. They are excluded from
`system.sqlite` under the license gate in `docs/DICTIONARY_PIPELINE.md` until permission is supplied:

- CustomPinyinDictionary, revision `0673212e83c9db1fef24fdf950b22c994bf27e9c`
- skrik2/lexicon, revision `3ed738ab8e0db9f659de782f65c060d9d5199bdb`
- Peter-JXL/thesaurus, revision `92f751cb6f2219e78c1535ad6c4c0b215f047b51`
