# MyIME 流畅度与准确率优化报告

日期：2026-11-18。范围：`MyIME/IMEKit` 引擎（分词、词格、评分、查询、用户词库缓存）及评测。
未提交、未推送、未安装、未改动系统输入法设置；生产词库 `system.sqlite` 未改动。

## 1. 结论（先看这里）

- 在本评测集上，整句 top1 与逐键延迟均有明确提升，但**整体 top1 仍约 50%（网络语料）和 80%（手写难句集）。没有达到、也不声称达到微信/搜狗输入法 80-90% 的水平。**
- 网络语料标签由 `tools/build_web_eval.py` 通过“jieba 分词后的 pypinyin 读音”与“词典正向最大匹配读音”的一致性自动生成，**不是人工标注的真值**；歧义与错误会被两边共享，数值只适合作相对比较（回归检测），不能当绝对质量。
- 同一批 500 条样本上，我们的引擎 top1 为 52.2%，Google Input Tools（外部服务，一次性离线取得并保存在仓库外）为 69.8%。**这是与 Google 的单点对照，不等价于微信/搜狗，也不能推断后两者的结果。** 差距主要在长句的语言模型质量（本项目只有词表加 n-gram 哈希模型，没有神经重排）。

## 2. 结果

准确率（top1 整句 / 字准确率，均相对于上述自动标签）：

| 集合 | 基线 | 现在 |
|---|---|---|
| hard（178 句，手写，调参使用） | 134 = 75.3% / 93% | 143 = 80.3% / 96.4% |
| hard 词（120） | top1 111 / top3 119 | top1 114 (95.0%) / top3 119 (99.2%) |
| web_dev（1035，调参使用） | 495 = 47.8% / 84.7% | 525 = 50.7% / 86.9% |
| web_test（965，**留出，不参与调参**） | 473 = 49.0% / 84.2% | 499 = 51.7% / 86.4% |
| 同 500 样本（web_test 子集） | - | 261 = 52.2% / 87.5%（Google 参考 349 = 69.8% / 92.8%） |
| 同 178 句（hard） | - | 143 = 80.3% / 96.4%（Google 参考 167 = 93.8% / 99.1%） |

留出集 web_test 与调参集同步提升（+26 对 +30），说明提升没有明显的过拟合，但这只是在同一批自动标签下的结论。
按类别（现在，top1）：web_dev 口语指令 56.9%、对白 67.5%、文学 39.2%、新闻标题 47.5%、论坛 44.0%。文学与论坛最弱。

逐键延迟（`HARD[逐键延迟]`，4187 次按键，同一台 Apple silicon 机器、同一测试配置）：

| | mean | p50 | p95 |
|---|---|---|---|
| 基线 | 58 ms | - | 111.86 ms |
| 现在 | 13.3 ms | 11.2 ms | 28.2 ms（p99 38.2，max 57.2） |

分步（同配置，测试时机器负载有差异，仅作参考）：词格评分调整后、查询优化前 mean 45.4 / p95 102.1 ms；之后降至 13.3 / 28.2 ms，主要来自下面的查询与缓存改动。

## 3. 改动清单

引擎（`IMEKit/Sources/IMEKit`）：
1. `Segmenter.swift`：`segmentPiece` 改为带记忆化的 k-best 动态规划。排序元组是加性的，因此后缀 k-best 是精确的；保持完整干净的解析优先、至多 1 处错键、模糊音、部分首字母、撇号分隔。
2. `Engine.swift`：
   - 首音节回退查询对完整音节改用 `lookupExact`，单字母首字母仍用 `lookup`。
   - 词格音节数上限由 16 提升到 32（`Scale.maxLatticeSyllables`），仍受单次更新截止时间约束（首条 150 ms，其余 60 ms）。
   - 评分常量：`logRange` 16.0 → 12.0，`wordPenalty` 3.2 → 4.0。仅依据 web_dev 与 hard 选定；web_test 只用于检查。其余常量不变。
3. `SQLiteStore.swift`：
   - `SQLiteStore.lookup` 拆为三层查询（`py_key =`、首字母等值、前缀 GLOB），可走索引，加 512 项缓存；排序与 source_mask 过滤保持与原 OR/GLOB 查询一致。
   - `UserStore` 增加惰性内存快照（词频、短语、bigram），在 `learn`、`learnPhrase`、`importTSV`、`clearLearning` 时失效；仍受原有锁保护。`predictNext` 与 `exportTSV` 仍直接查 SQL。

测试与工程：
- `IMEKitTests.swift`：新增分词器回归测试（完整解析优先、错键上限、模糊音、部分首字母、撇号）。
- `LookupEquivalenceTests.swift`（新）：对多组查询 × source_mask × limit，断言新 `lookup` 与原查询（测试内逐字保留的旧 SQL）返回相同 id 序列。
- `HardEvalTests.swift`：加入回归阈值（hard top1 ≥ 78%、字 ≥ 95%；词 top1 ≥ 93%、top3 ≥ 97%；web_dev / web_test top1 ≥ 49%、字 ≥ 85%；逐键延迟 mean < 40 ms、p95 < 90 ms，均略低于实测值）；新增 `referenceComparison`，设置环境变量 `MYIME_REFERENCE_TSV` 时按外部参考文件的同一批行评分，未设置则跳过。
- 删除临时的 `ProfileScratchTests.swift`。
- `Package.swift`：测试目标加 `exclude: ["Fixtures"]`，消除 “unhandled resource” 警告。

## 4. 验证命令与结果

```bash
cd MyIME/IMEKit
swift test                                   # 35 个测试 / 5 个套件全部通过（含 AccuracyEval 100%/100%）
MYIME_REFERENCE_TSV=/tmp/myime_eval/google_web_test.tsv swift test --filter referenceComparison   # 同样本对照
swift test --filter LookupEquivalence        # 新旧查询等价性

cd MyIME
xcodebuild -project MyIME.xcodeproj -scheme MyIME -configuration Debug \
  -derivedDataPath /tmp/myime_dd CODE_SIGNING_ALLOWED=NO build     # BUILD SUCCEEDED
```

AccuracyEval 门槛未改动（整句 ≥ 0.96，词 ≥ 0.95 等），仍全部通过。

## 5. 语料与许可说明

评测语料来自公开中文语料集合（见 awesome-nlp-chinese-corpus 的索引），由 `tools/build_web_eval.py` 抽取子句并生成拼音：
- SMP2017 ECDT 用户话语 → 口语指令；dgk_lost_conv 等影视对白 → 对白；Douban Conversation Corpus → 论坛；今日头条新闻标题 → 新闻标题；Chinese-Literature-NER-RE → 文学。
- 各语料各自许可不同，且部分来源未明确许可（来自网络爬取）。**仓库只保留抽样的短子句与拼音（`Tests/IMEKitTests/Fixtures/web_*.tsv`），不分发原始语料；** 这些短句仅用于内部回归评测，不应作为训练数据或对外发布。如需对外分发，请逐一核对来源许可。原始语料放在 `/tmp/myime_corpus`，不入库。
- Google Input Tools 的 500 条与 178 条参考输出是一次性取得的外部结果，存放在仓库外（`/tmp/myime_eval/google_*.tsv`），仅用于对照，不入库；已不再发起任何外部请求。生成脚本见 `/tmp/myime_eval/google_ref.py`（抽样种子 7）。该服务的使用条款未确认，不应据此做对外宣传或批量调用。
- 词典许可见 `tools/LICENSES.md`，本次未改动。

## 6. 局限

1. 标签是自动生成的（jieba 分词后的 pypinyin 读音与词典最大匹配读音一致），不是人工真值。多音字、同音歧义下 “top1 不等于标签” 可能仍是合理候选；因此绝对数值偏低，且与真实用户体验不等价。
2. 评测为整句一次性输入，没有模拟真实的逐词选择与用户学习；真实使用中用户词库会提升命中率。
3. Google 对照仅为一个外部系统、500 条一次采样，没有置信区间，不能外推到微信/搜狗。
4. 评分常量调参仅在 web_dev 与 hard 两个集合上做网格搜索，已用留出的 web_test 复核，提升方向一致；但仍有集合特异性的风险。hard 集同时是调参集，其 80.3% 偏乐观。
5. 延迟测量取决于机器与负载，阈值设得较宽，只用于拦截明显回归；基线与现值在同一台机器上取得，但不同轮次的背景负载不同。
6. 与参考系统的差距（约 17 个百分点）主要来自语言模型规模与长句建模。进一步提升需要更大的语料训练的 n-gram 或神经重排（参见 `docs/NEURAL_RERANKING.md`），这超出本次范围，也不应被视为已解决。
7. 未改动生产词库；没有找到足以证明需要重建词库的实测依据。

## 7. 可复现性

- 固定种子：Google 抽样 `random.Random(7)`；`build_web_eval.py` 的抽样由其脚本内部的固定哈希/种子决定。
- 评测数据在 `IMEKit/Tests/IMEKitTests/Fixtures`（`hard_sentences.tsv`、`hard_words.tsv`、`web_dev.tsv`、`web_test.tsv`）。同 500 样本全部属于 `web_test.tsv`（已核对 500/500 行一致）。
