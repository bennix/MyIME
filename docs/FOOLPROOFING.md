# 防呆机制（FOOLPROOFING v1.0）

> 防呆 = poka-yoke：**让错误做不出来，或做出来立刻被发现。**
> 三层：①**交付门 Gate**（每里程碑必须机器可验通过）②**运行时防呆**（永不崩溃/永不丢字）③**数据/流程防呆**。
> 实现方交付每个里程碑时 MUST 逐条勾选，并把可自动化的做成 CI/脚本。**未过 Gate 不得声称完成。**

---

## 第一层：交付门（Gates）

### G-DICT — 词库（M1）
- [ ] **G-DICT-LIC**：`tools/LICENSES.md` 覆盖全部 7 来源，含实际许可证+链接+日期；未核实来源已从构建排除；zhwiki 的 CC BY-SA 署名与共享声明已写入 `About`/`meta.source_manifest`。
- [ ] **G-DICT-YIELD**：每来源 `kept/total_in ≥ 0.6`，否则有书面说明。
- [ ] **G-DICT-SCHEMA**：`system.sqlite` 通过 `PRAGMA integrity_check;` = `ok`；表/索引/`source_mask` 列齐全；`PRAGMA query_only` 可开。
- [ ] **G-DICT-DEDUP**：`SELECT count(*) FROM entries` == `SELECT count(*) FROM (SELECT DISTINCT word,py_key FROM entries)`（无重复键）。
- [ ] **G-DICT-ENC**：随机抽样 1000 条，`word` 全为合法 NFC 简体（无繁体残留：用 OpenCC 反查 t2s==自身）；`pinyin` 仅 `[a-z']`。
- [ ] **G-DICT-COVER**：常用词命中集（≥200 词 golden：你好/世界/北京/中国/谢谢/成语若干/地名若干）100% 可查到且拼音正确。
- [ ] **G-DICT-REPRO**：连续两次 `build_dict.sh` 产物（除 `built_at`）sha256 一致。
- [ ] **G-DICT-SIZE**：`entry_count` 在合理区间（记录期望量级，异常缩水/膨胀报警）。

### G-ENG — 引擎（M2，纯 IMEKit，命令行/单测即可验）
- [ ] **G-ENG-GOLDEN**：golden 首选项测试全绿。至少锁定：
  - `nihao→你好`、`shijie→世界`、`beijing→北京`、`zhongguo→中国`、`woaini→我爱你`
  - 简拼：`bj→北京(在前列)`、`nh→你好(在前列)`
  - 模糊音开：`ci→词/瓷…`且 `chi` 结果含之（惩罚后仍可选）
- [ ] **G-ENG-DET**：同输入+同 prefs → 候选顺序**完全一致**（跑 100 次哈希稳定）。
- [ ] **G-ENG-NONEMPTY**：任意「含至少一个合法音节」的输入，候选非空（单字兜底）。
- [ ] **G-ENG-NOEXCEPT**：模糊测试——随机 `a-z'` 串（含超长 64 字符、全 `'`、单字母、空串）10^5 次，Engine **零抛出、零崩溃**、均在预算内返回。
- [ ] **G-ENG-PERF**：≤6 音节输入，`update` **P95 < 20ms**（Release，M 系列）；warmup < 300ms。基准脚本纳入 CI。
- [ ] **G-ENG-SEG**：切分单测覆盖全拼/简拼/混拼/硬边界 `'`/非法尾段。

### G-IMK — 系统集成（M3）
- [ ] **G-IMK-PLIST**：`Info.plist` 的 `InputMethodConnectionName` == `IMKServer(name:)`；`InputMethodServerControllerClass` == 控制器 ObjC 运行时名（含模块前缀/`@objc`）；`tsInputMethodCharacterRepertoireKey=["zh-Hans"]`；`ComponentInputModeDict` 完整。
- [ ] **G-IMK-INSTALL**：拷入 `~/Library/Input Methods/` 后，在「系统设置→键盘→输入法」可见并可添加。
- [ ] **G-IMK-ROUNDTRIP**：TextEdit/Safari/终端三处均能：显示预编辑 → 空格上屏 → 数字选词 → 退格删字 → Esc 清空不上屏。
- [ ] **G-IMK-SANDBOX**：`ENABLE_APP_SANDBOX=NO`、`ENABLE_HARDENED_RUNTIME=YES`；改动经 PR 记录。
- [ ] **G-IMK-NOSWIFTDATA**：`Item.swift`、`sharedModelContainer` 已删除，无残留引用（`grep` 零命中 `SwiftData`、`ModelContainer`）。

### G-UX — 交互（M4）
- [ ] **G-UX-KEYMAP**：SPEC §4.2 全键位默认行为逐条通过手测清单。
- [ ] **G-UX-PUNCT**：中英标点表（全/半角）正确；Composing 中输入标点先上屏高亮再出标点。
- [ ] **G-UX-CJK**：候选窗随光标定位；翻页边界（首页上翻/末页下翻）不越界、不闪退。
- [ ] **G-UX-ENGLISH**：Shift 切中英即时生效；英文模式直通宿主。

### G-LEARN — 学习与设置（M5）
- [ ] **G-LEARN-ADAPT**：连续选同一较冷词 N 次后，其排名单调上升（有单测）。
- [ ] **G-LEARN-SAFE**：`user.sqlite` 损坏/只读/磁盘满时，输入**不受影响**（学习静默降级），有故障注入测试。
- [ ] **G-LEARN-PREFS**：改模糊音/候选数后无需重启即时生效（至少切输入源后生效），Controller 与 UI 共享同一 `EnginePrefs`。
- [ ] **G-LEARN-IE**：用户词导入/导出往返一致；导入走 CIF 同款校验，非法行被拒并计数。

### G-SHIP — 发布（M6）
- [ ] **G-SHIP-SIGN**：Developer ID 签名 + 公证（notarization）通过；`spctl -a -vv` 与 `codesign --verify --deep --strict` 通过。
- [ ] **G-SHIP-CLEAN**：全新用户账户安装即可用；卸载可清理 `~/Library/Input Methods/MyIME.app` 与 Application Support。
- [ ] **G-SHIP-ATTR**：`关于`页含全部来源署名与许可证、build_hash、词条数。

---

## 第二层：运行时防呆（Controller/Engine，MUST 编码保证）

1. **永不崩溃宿主**：`IMKInputController` 的每个事件回调（`handle`, `inputText`, `didCommand` 等）MUST 包 `do/catch` 或 Swift 无抛出封装；任何内部错误 → 记录日志 + 返回 `false`（事件交回系统），**绝不抛到系统输入会话**。IME 崩溃会波及全系统打字。
2. **永不丢字**：
   - 任意时刻失焦/切 App（`deactivateServer`/`commitComposition`）MUST 把当前 buffer 以**原始字母**上屏或按策略提交，绝不静默丢弃用户输入。
   - `insertText` 后 MUST 立即清空 marked text，杜绝「预编辑残影」。
3. **降级而非报错**：Engine 返回空/异常 → Controller 允许把 buffer 原样字母上屏（回车/失焦时），用户永远能把字打出去。
4. **输入净化**：进入 Engine 前 MUST 过滤到 `[a-z']`；大写、组合键、非 ASCII 一律不进 buffer（按键位表另行处理）。防止注入怪字符导致切分异常。
5. **索引越界防护**：数字选词、翻页 MUST 对候选数组做边界钳制（`clamp`），越界 = 无操作，不崩。
6. **重入与并发**：学习写库在后台串行队列；读路径只读 `system.sqlite`（`query_only`）。UI 与 Controller 若跨进程访问 `user.sqlite`，MUST 用 SQLite WAL + busy_timeout，避免锁死。
7. **资源缺失自检**：启动时 `system.sqlite` 缺失/`integrity_check` 失败 → 进入「英文直通 + 明确提示」模式，**不崩**、不出乱码。
8. **性能兜底**：单次 `update` 超时（软阈值 50ms）MUST 截断候选并返回已算部分，不阻塞按键。

---

## 第三层：数据/流程防呆

1. **来源锁定**：`tools/SOURCES.lock` 固定每来源 commit/tag + 日期；构建只用锁定版本，杜绝上游漂移。
2. **CIF 是唯一入口**：任何来源不经 CIF 校验不得进合并器；新增来源 = 新增一个 adapter + 更新 manifest/`source_mask`，**不改合并器逻辑**。
3. **确定性构建**：固定排序、固定权重公式；`G-DICT-REPRO` 保证可复现。
4. **金标回归**：`system.sqlite` 每次重建后 MUST 跑 `G-DICT-COVER` + `G-ENG-GOLDEN`；首选项/命中集回归失败 = 阻断合并。
5. **许可证闸门**：`G-DICT-LIC` 未过则 CI 直接失败，产物不得进入打包。
6. **Schema 版本**：`meta.schema_version` 与 App 内置期望值不符 → App 拒绝加载该库并提示重建，不静默错读。

---

## 交付自检脚本（建议）
把上面可自动化项做成 `tools/verify.sh`，输出逐 Gate 通过/失败表。**CI 红则交付无效。**

## 反面清单（MUST NOT）
- ❌ 声称完成却未跑 golden / integrity_check。
- ❌ 用占位/桩/`TODO: implement` 冒充功能（空候选窗、假词库）。
- ❌ 私自开启沙盒、私改 bundle id / 连接名却不同步 Info.plist。
- ❌ 凭记忆假定许可证、跳过 `LICENSES.md`。
- ❌ 在 Controller 里写拼音规则（逻辑必须在 Engine）。
- ❌ 保留 SwiftData 模板死代码。
- ❌ 让学习写库的失败影响正常打字。
