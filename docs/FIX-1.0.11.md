# 1.0.11：输入连接与光标提示修复

2026-09-16，本机 macOS 的 imklaunchagent 日志明确报告：
`Refusing connection name for bundle: unrecognized 'InputMethodConnectionName' value`。
已安装 1.0.7 使用 `MyIME_1_Connection`，与系统接受的 bundle identifier 加 `_Connection` 不符。切换到 MyIME 后 TextEdit 直接输入拉丁字母，没有建立输入会话。

修复：

- 连接名统一为 `fudan.miniS.inputmethod.MyIME_Connection`。
- 安装/登录的 `--register-input-source` 在无现有服务时进入正常 App 生命周期，保持 IMKServer 运行；存在服务时复用它。
- 光标宽度为零但高度有效时仍使用真实光标坐标，候选与指示窗口不再错误回退到鼠标位置。
- 中文空闲会话的“中 MyIME”提示保持显示；组词、英文模式和输入法停用时隐藏。提示窗口不拦截鼠标。

验证：Developer ID 签名 Release 构建通过，已更新本机系统目录到 1.0.11（build 61）。日志确认 TextEdit、系统设置建立并激活输入会话；TextEdit 键盘实测 `nihao` 出现 `ni'hao` 预编辑并可上屏中文。辅助功能树确认 MyIME 窗口包含“中 MyIME”。未宣称已完成所有第三方应用实测。

本地安装包：`release/MyIME-1.0.11-developer-id-arm64.dmg`。本轮尚未发布该修复至 GitHub。
