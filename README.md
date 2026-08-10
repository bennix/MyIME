# 🚀 MyIME

**一款能预测完整短句、会学习个人表达习惯，并且完全离线运行的 macOS 简体中文输入法。**

**🧠 智能与自学习**：长拼音整句预测，支持自动组合新词与近期上下文加权，越用越贴合你的表达习惯。

**📦 丰富本地语料**：内置约 115 万条高质量本地词库（整合 Rime-Ice、清华语料、新华/语义等社区词表及派生数据），出字精准。

**🔒 100% 纯净与安全**：候选计算、习惯学习全在本地运行，无需联网、没有网络请求，不上传任何击键数据。

**⚡ 系统级流畅交互**：基于成熟稳定的 macOS 输入服务，极速响应，支持中英混输、Emoji 及自动注册安装。

既有极客的纯粹与安全，又有极致的效率提升，这套设计思路成熟而实用。

[产品介绍](https://bennix.github.io/MyIME/) · [下载最新版](https://github.com/bennix/MyIME/releases/latest)

## 特点

- 智能整句：支持连续拼音生成自然短句候选；内置离线准确率基准持续回归。
- 本地词库：整合 Rime-Ice、THUOCL、中文维基、新华/语义等词表，以及过滤噪声后的字/词级语言模型。
- 容错输入：支持常见相邻字母颠倒、全拼韵母写法归一，以及简拼/尾部简拼。
- 联想续写：上屏后基于本地统计与常用续写给出建议，并抑制网页语料噪声。
- 安装自愈：安装和版本更新时自动刷新输入源注册，不额外安装登录守护进程。
- 系统托管：由 macOS 在选中 MyIME 时启动唯一的中文输入服务；若手动结束该进程，需切换一次 ABC → MyIME 重新建立输入会话。
- 中文状态明确：选择 MyIME 时始终处理中文输入；需要英文时切换到 ABC，不再使用不可见的 Shift 会话开关。
- 越用越顺手：重复选择会提升词频；3 秒内分开选择的字词会自动组成新词。
- 候选操作：方向键移动、回车和数字选词、展开候选与翻页。
- 英文辅助：回车可直接送出原始英文，并提供基础拼写建议。
- 完全离线：候选生成、排序和用户学习都在本机完成。

## 安装

1. 从 [Releases](https://github.com/bennix/MyIME/releases/latest) 下载 DMG。
2. 打开 DMG，双击 `MyIME.app`；全新安装无需管理员授权，从 1.0.8 或更早版本升级时会请求一次授权以清理旧副本。
3. 从 macOS 菜单栏的输入法菜单切换到 **MyIME**。

公开下载包必须使用 Developer ID Application 证书签名并完成 Apple 公证。文件名带 `development` 或 `local-adhoc` 的构建仅供开发机测试，请勿发送给其他用户安装。

## 开发与测试

```sh
cd MyIME
swift test --package-path IMEKit
xcodebuild build -project MyIME.xcodeproj -scheme MyIME -configuration Release -destination 'platform=macOS'
```

应用基于 InputMethodKit，采用非沙盒方式运行。启动后会自动安装到 `~/Library/Input Methods/MyIME.app`、注册输入源并从用户目录重新启动。1.0.8 或更早版本升级时会要求一次管理员密码，用于移除旧的 `/Library/Input Methods/MyIME.app`，避免同一 Bundle ID 的两个副本导致输入源缓存冲突。

## 生成可安装 APP 与 DMG

正式分发需要钥匙串中存在 `Developer ID Application` 证书及其私钥，并预先配置 `notarytool` 钥匙串凭据：

```sh
MYIME_NOTARY_PROFILE=MyIMENotary ./tools/build-release.sh
```

脚本会依次运行引擎测试、验证内置词库、构建并校验 Universal 2（Apple Silicon + Intel）APP、签名、生成 DMG、提交 Apple 公证、装订公证票据并生成 SHA-256 校验文件，产物位于 `dist/`。脚本会拒绝把 Apple Development 签名误当作公开分发包。

仅供当前 Mac 调试时可生成明确标记的 ad-hoc 版本；该版本不能代替正式签名分发版：

```sh
MYIME_ALLOW_ADHOC=1 ./tools/build-release.sh
```

## 词库与许可

构建脚本与来源锁定位于 `tools/`，详细流程见 `docs/DICTIONARY_PIPELINE.md`。第三方来源和许可见 `tools/LICENSES.md` 与应用内的 `ThirdPartyNotices.txt`。原始训练语料不包含在仓库或应用中，应用仅打包经过归一化的词库与紧凑统计模型。
