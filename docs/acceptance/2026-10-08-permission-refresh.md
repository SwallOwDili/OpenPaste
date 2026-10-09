# 2026-10-08 已授权但按键权限未生效检查

结果：正常退出并重新打开同一份 `/Applications/OpenPaste.app` 后，设置页已显示“直接粘贴 已授权”。随后补测系统快捷键及一次跨应用纯文本自动粘贴，实际目标收到内容，见下方补测记录。没有切换权限、删除授权条目、重置 TCC、重新签名、替换安装或修改产品代码。这不代表全产品或所有粘贴格式验收通过。

## 证据

- 重启前进程 PID 58640，路径 `/Applications/OpenPaste.app/Contents/MacOS/OpenPaste`。System Settings → Privacy & Security → Accessibility 的 OpenPaste 开关为 on；OpenPaste 显示按键权限未生效并提供手动粘贴提示。
- 产物采用 ad hoc 签名，TeamIdentifier 未设置；当前指定要求为 `cdhash a66e38629e9b80b06b66d6df6cf1536d8b0f645e`。
- 13:46:04 的系统 TCC 日志明确记录旧授权要求 `45546e760f0e1207e542f5463c6468d37d20e80b` 与当前签名不匹配。之后日志记录新签名检查成功、Accessibility 允许；进程界面仍显示发送按键检查未通过。
- 经正常菜单退出后重开，PID 64132，打开设置 → 隐私与权限，直接粘贴状态为“已授权”。

结论：不是用户忘记打开开关。此次存在安装产物签名变更后的授权重新识别过程；重新授权后的运行进程未及时反映有效的事件发送状态，重启同一版本即可恢复。应用本身每次会调用权限检查 API，因此不能简单归因为 Store 未刷新；具体系统框架内部缓存机制本轮没有进一步证明。

源码的权限按钮仅调用 AX 请求，没有调用 `CGRequestPostEventAccess`，但本次没有补调用该 API 也恢复了，不能把它定为已确认根因。

证据目录：`build/acceptance-results/2026-10-08-permission-refresh/`，包含安装产物 SHA-256、重启前后状态和相关 TCC 日志。此前系统 TCC 数据库读取被系统拒绝，未绕过该限制；结论依据可读系统日志及真实界面。

## 补测：已安装版本跨应用自动粘贴

- 在现有专用 PasteFixture 的纯文本输入框设置测试前缀，不操作真实文档。
- 使用经用户授权的 CGEvent 驱动发送当前设置的 ⌥⌘↑，实际呼出 OpenPaste；搜索既有合成记录 `OPENPASTE-FIX-FINAL-RECOVERY-NEW-COPY`，得到一条结果。
- 首次 CGEvent Return 被驱动的前台窗口检查拒绝，未发送。通过原生 UI Raise 恢复面板焦点后，用原生 UI Return 触发取用；没有在目标窗口手动发送 ⌘V。
- 目标应用粘贴计数从 6 增至 7，实际内容为 `权限恢复后自动粘贴验收：OPENPASTE-FIX-FINAL-RECOVERY-NEW-COPY`；证明已安装 App 的自动粘贴链路生效。
- 原系统剪贴板事先本地备份，测试后在确认仍为本次测试值时恢复，备份已删除。使用的既有合成历史记录被正常取用置顶，没有创建新的测试内容记录。
- 结果保存在证据目录 `cross-app-paste.json`。本轮未重测全部格式、存储边界、性能或 iCloud；不更新这些项目的验收状态。
