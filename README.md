# 🚀 MyIME

**一款能预测完整短句、会学习个人表达习惯，并且完全离线运行的 macOS 简体中文输入法。**

**🧠 智能与自学习**：长拼音整句预测，支持自动组合新词与近期上下文加权，越用越贴合你的表达习惯。

**📦 丰富本地语料**：内置约 116 万条本地候选记录（整合 Rime-Ice、青简、清华语料、新华/语义等社区词表及派生数据）。

**🔒 100% 纯净与安全**：候选计算、习惯学习全在本地运行，无需联网、没有网络请求，不上传任何击键数据。

**⚡ 系统级流畅交互**：基于成熟稳定的 macOS 输入服务，极速响应，支持中英混输、Emoji 及自动注册安装。

既有极客的纯粹与安全，又有极致的效率提升，这套设计思路成熟而实用。

[产品介绍](https://bennix.github.io/MyIME/) · [下载最新版](https://github.com/bennix/MyIME/releases/latest)

## 特点

- 智能整句：支持连续拼音生成自然短句候选；内置离线准确率基准持续回归。
- 本地词库：整合 Rime-Ice、THUOCL、中文维基、新华/语义等词表，以及过滤噪声后的字/词级语言模型。
- 容错输入：支持常见相邻字母颠倒、全拼韵母写法归一，以及简拼/尾部简拼。
- 联想续写：上屏后基于本地统计与常用续写给出建议，并抑制网页语料噪声。
- 安装自愈：版本更新后自动重绑前台输入会话；登录后自动恢复输入源注册。
- 越用越顺手：重复选择会提升词频；3 秒内分开选择的字词会自动组成新词。
- 候选操作：方向键移动、回车和数字选词、展开候选与翻页。
- 英文辅助：回车可直接送出原始英文，并提供基础拼写建议。
- 离线释义：中文候选旁显示简短英文释义，可在设置中关闭；释义仅作参考。
- 日期快捷输入：输入 `rq`、`sj`、`xq`，选择当前日期、时间或星期，支持数字和方向键选取。
- 完全离线：候选生成、排序和用户学习都在本机完成。

当前版本已整合青简的 92,825 条有效词条与语料频次，合并去重后共 1,160,989 条候选记录。日期快捷候选放在常规首选之后。升级时保留已有设置和用户学习记录。

整句计算目前使用本地词图搜索、字/词统计模型与用户学习，尚未内置 Transformer。PinyinGPT / Transformers4IME 的研究结论与后续接入要求见 [模型方案](docs/NEURAL_RERANKING.md)。

## 安装

1. 从 [Releases](https://github.com/bennix/MyIME/releases/latest) 下载 DMG。
2. 打开 DMG，双击 `MyIME.app`；首次安装会请求管理员授权。
3. 从 macOS 菜单栏的输入法菜单切换到 **MyIME**。

Release 使用 Apple Developer ID 证书签名，尚未完成 Apple 公证。如果 macOS 阻止首次打开，请在 Finder 中按住 Control 点击 `MyIME.app`，选择“打开”。

## 开发与测试

```sh
cd MyIME
swift test --package-path IMEKit
xcodebuild build -project MyIME.xcodeproj -scheme MyIME -configuration Release -destination 'platform=macOS'
```

应用基于 InputMethodKit，采用非沙盒方式运行。启动后会自动安装到 `/Library/Input Methods/MyIME.app`、注册输入源并从系统目录重新启动。

## 词库与许可

构建脚本与来源锁定位于 `tools/`，详细流程见 `docs/DICTIONARY_PIPELINE.md`。第三方来源和许可见 `tools/LICENSES.md` 与应用内的 `ThirdPartyNotices.txt`。原始训练语料不包含在仓库或应用中，应用仅打包经过归一化的词库与紧凑统计模型。
