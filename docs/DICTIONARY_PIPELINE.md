# 词库综合流水线（DICTIONARY_PIPELINE v1.0）

> 目标：把已授权的异构来源归一为 **CIF**，合并去重、频率归一，编译为 `system.sqlite`（Schema 见 `SPEC.md` §6.1）。
> 产物路径：`MyIME/MyIME/Resources/system.sqlite`。
> 脚本放 `tools/`，用 **Python 3.11+**（`pypinyin`、`OpenCC`、`sqlite3` 标准库）。脚本 MUST 幂等、可重跑。

---

## 1. 来源清单（Source Manifest）

| id | 来源 | 原始格式 | 简/繁 | 采信度 rank | 用途/说明 |
|----|------|----------|-------|-------------|-----------|
| `custom_pinyin` | CustomPinyinDictionary | Fcitx5/Rime 文本 | 简 | 3 | 百万级常用词（成语/地名/商品/人名），已去重精简 |
| `rime_ice` | rime-ice（雾凇拼音） | Rime `dict.yaml` | 简 | 1（最高） | 长期维护、体验优，作为**主干与冲突仲裁基准** |
| `skrik2_lexicon` | skrik2/lexicon | 文本 / JSON | 简 | 3 | 专业词库（医学/IT/法律/网络流行语） |
| `jingxing` | 景行词库 | Gboard 文本 | 简 | 3 | 轻量，生活/科技/娱乐；含双拼信息→v1.0 忽略双拼列 |
| `zhwiki` | fcitx5-pinyin-zhwiki | Fcitx5 文本 / libime 源 | 简/繁混 | 2 | zhwiki 生成，词量大、更新，长词/专名多 |
| `thesaurus` | Peter-JXL/thesaurus | 文本 | 英/术语 | 4 | 程序员术语（Java/Markdown…），保留大小写，特殊处理 |
| `renfei_dict` | renfei/dict | 文本 | 简/繁混 | 3 | 搜狗分类词库整理版 |
| `thuocl` | 清华大学开放中文词库（THUOCL） | 词语 + DF 词频 TSV | 简 | 2 | IT、财经、成语、地名、医学、法律等专业词汇 |
| `sc_dictionary` | samejack/sc-dictionary | 一行一词 | 简/繁混 | 3 | 百万简繁词表；构建时 OpenCC t2s |
| `chinese_xinhua` | pwxcoo/chinese-xinhua | JSON | 简 | 2 | 成语（自带拼音）、词语、单字读音 |
| `chinese_semantic_kb` | liuhuanyong/ChineseSemanticKB | 关系文本 | 简 | 3 | 同义/反义/简称/抽象等表面词抽取；上游无 SPDX，见 `tools/LICENSES.md` |

> **rank 语义**：合并冲突时，rank 小者（更权威）胜出为基准词形/拼音；见 §5。
> **⚠ 许可证 MUST 逐一核实**：这些来源可能为 GPL/LGPL/CC BY-SA/MIT/Apache 等，含 **ShareAlike/Copyleft** 风险。实现方 MUST 在 `tools/LICENSES.md` 记录每个来源的**实际许可证 + 原始链接 + 抓取日期**，并确认与「非 App Store、Developer ID 分发」兼容；zhwiki 系 CC BY-SA，成品 MUST 附署名与相同方式共享声明。**不得凭记忆假定许可证。** 未核实通过的来源 MUST 从构建中排除（见 FOOLPROOFING G-DICT-LIC）。

---

## 2. CIF —— 归一中间格式

每来源先转成统一的 **CIF TSV**（UTF-8, `\n`）：
```
word <TAB> pinyin <TAB> weight <TAB> source
```
字段约束（MUST）：
- `word`：目标词，**简体**、Unicode **NFC**；`繁→简` 用 OpenCC `t2s`。长度 1–20 汉字。
- `pinyin`：小写 `a–z` 音节，以 `'` 连接，无声调；音节数 MUST == `word` 汉字数（不等则丢弃并计入 `dropped_mismatch`）。
- `weight`：原始频率/权重（整数，来源内部标度，后续再全局归一）。缺失则置来源默认（见各适配器）。
- `source`：上表 `id`。

CIF 是**唯一进入合并器的入口**；任何来源都 MUST 先落地为 `build/cif/<source>.tsv`，便于抽检与回归。

---

## 3. 各来源适配器（Adapters）

每个来源一个 `tools/adapters/<id>.py`，输入原始文件、输出 `build/cif/<id>.tsv`。通用步骤：解析 → 抽 `(word, pinyin?, weight?)` → 补拼音 → 校验 → 写 CIF。

### 3.1 补拼音策略（MUST）
- 来源**自带拼音**（rime/fcitx5/景行）：直接采用，仅做小写化、去声调、`'` 归一、音节数校验。
- 来源**无拼音**（部分 thesaurus / renfei / lexicon 纯词表）：用 `pypinyin`（`Style.NORMAL`，`heteronym=False`，`errors='ignore'`）生成；含非汉字则该行进入 `non_han` 分流。
- **多音字**：v1.0 只取来源给定读音；自动生成时取 `pypinyin` 默认读音，不做多音字展开（避免噪声爆炸）。

### 3.2 各来源要点
- **`rime_ice`**：解析 `dict.yaml`，跳过 YAML 头（`---`…`...`），数据行 `text\tcode\tweight`（weight 可缺）。`code` 空格→`'`。作为基准，rank=1。
- **`custom_pinyin`**：Fcitx5/Rime 文本，按其分隔符（空格或 tab）解析；百万级，MUST 流式处理，勿全量载入内存。
- **`zhwiki`**：fcitx5 文本 `词 拼音 频率`（拼音以 `'` 连）；繁体条目 OpenCC t2s；长专名多，长度上限放宽到 20。
- **`jingxing`**：Gboard 文本；**忽略双拼列**（v1.0 非目标），只取全拼；无频率则默认中位权重。
- **`skrik2_lexicon`**：JSON 走 `json`，文本走通用解析；带分类 tag 的 MAY 存入 `source` 之外的辅助日志，但**不进 `entries`**（v1.0 无分类字段）。
- **`renfei_dict`**：搜狗整理版文本；繁→简；去分类表头行。
- **`thesaurus`（特殊）**：程序员术语，**保留原大小写**（`Java`、`Markdown`）。这类词的 `word` 含 ASCII 字母：
  - 「拼音」用其**小写 ASCII 本身**作为 `py_key`/`pinyin`（如 `java`→`java`），使英文首字母/全拼都能召回；`initials` 取首字母。
  - `source=thesaurus` 并打内部 `ascii=1` 标记，合并时**与中文词隔离**（不同 `py_key` 命名空间天然隔离，无需额外列）。
  - 音节数校验对 ASCII 词**豁免**（它不是汉字词）。

---

## 4. 校验（每来源出 CIF 后，MUST）
逐行校验，产出 `build/report/<id>.json`：
- 编码：非法 UTF-8 → 丢弃并计数。
- `pinyin` 仅含 `a–z'`；否则丢弃（ASCII 术语走豁免通道）。
- 音节数 == 汉字数（汉字词）；不符丢弃并计入 `dropped_mismatch`。
- 空 `word` / 空 `pinyin` / 超长 → 丢弃。
- 统计：`total_in, kept, dropped_encoding, dropped_mismatch, dropped_nonhan, dedup_internal`。
> 任一来源 `kept/total_in < 0.6` MUST 报警并人工核对适配器（防呆 G-DICT-YIELD）。

---

## 5. 合并与去重（Merger）

输入全部 `build/cif/*.tsv`，输出 `build/merged.tsv`（含 `source_mask`）。

### 5.1 去重键
`dedupKey = (word, py_key)`（`py_key` = 去 `'` 拼接）。同键即同一条目，跨来源合并。

### 5.2 词形/拼音仲裁
- 同 `dedupKey` 天然同 `word`+`pinyin`，无需仲裁。
- 若不同来源对同一 `word` 给出**不同拼音**（多音差异）：各自成条（`py_key` 不同），都保留。

### 5.3 权重合并（MUST 确定性）
1. **来源内归一**：每个来源把 `weight` 线性映射到 `[0,1]`（按分位数裁剪 99% 去极值，避免单来源超大频率霸榜）。
2. **加权求和**：`w = Σ_source ( srcReliability[source] * norm_weight )`，`srcReliability` 由 rank 决定（rank1=1.0, 2=0.8, 3=0.6, 4=0.4）。
3. **全局归一**：`weight_final = round( 65535 * (log1p(w)/log1p(w_max)) )`，落入 `0..65535`（对数压缩长尾）。
4. `source_mask`：出现来源的位掩码（bit 顺序固定见 §5.4），供设置界面按来源过滤。

### 5.4 `source_mask` 位定义（MUST 固定）
```
bit0 rime_ice   bit1 custom_pinyin  bit2 zhwiki    bit3 jingxing
bit4 skrik2_lexicon  bit5 renfei_dict  bit6 thesaurus
bit10 thuocl
```
> `entries` 表 MUST 增列 `source_mask INTEGER NOT NULL`（在 SPEC §6.1 Schema 基础上加此列），并加索引可选。设置里「禁用某来源」= 运行时 `WHERE source_mask & ~disabledMask`。

### 5.5 去重后统计
输出 `build/report/merged.json`：`entries_total, unique_words, collisions_merged, per_source_kept`。

---

## 6. 编译到 SQLite（Compiler）

`tools/compile.py`：读 `build/merged.tsv` → 写 `system.sqlite`。
- 建表（SPEC §6.1 + `source_mask` 列）与索引。
- 逐行插入：`py_key = pinyin.replace("'", "")`；`initials = 每音节首字母拼接`。
- 单事务批量插入（每 5 万行 commit），`PRAGMA journal_mode=OFF, synchronous=OFF`（仅构建期）。
- 建完 `PRAGMA optimize; VACUUM;`，最终**只读**产物。
- 写 `meta`：
  - `schema_version`（如 `1`）
  - `build_hash`：`merged.tsv` 的 sha256 前 16 位
  - `source_manifest`：JSON（各来源 id、许可证、抓取日期、kept 数）
  - `entry_count`
  - `built_at`（ISO8601）

---

## 7. 构建入口与可复现

`tools/build_dict.sh`（或 `make dict`）串起：`fetch → adapt → validate → merge → compile → verify`。
- MUST 幂等：重跑得到**逐字节一致**的 `system.sqlite`（除 `built_at`）；实现方 SHOULD 用固定排序（按 `word, py_key`）保证插入顺序稳定。
- 原始下载物固定版本（记录 commit/tag 于 `tools/SOURCES.lock`），杜绝「今天构建和昨天不一样」。
- 验证步骤见 FOOLPROOFING G-DICT。

---

## 8. 目录产物
```
tools/
  adapters/*.py
  merge.py  compile.py  validate.py  build_dict.sh
  SOURCES.lock          # 各来源 repo + commit/tag + 日期
  LICENSES.md           # 每来源实际许可证（核实后）
build/                  # 中间产物（git 忽略）
  cif/*.tsv  merged.tsv  report/*.json
MyIME/MyIME/Resources/system.sqlite   # 最终产物（随 App 打包）
```
> `build/` 与下载的原始词库 MUST 加入 `.gitignore`；仓库只提交脚本、`SOURCES.lock`、`LICENSES.md`，以及（体量允许时）最终 `system.sqlite`。若 `system.sqlite` 过大，改用 Git LFS 或构建时生成。
