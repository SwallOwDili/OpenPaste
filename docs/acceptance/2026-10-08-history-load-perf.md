# 2026-10-08 冷启动后台读取历史提速验收

范围：只处理“启动后历史迟迟不出现”的后台读取耗时。不涉及主线程 SwiftUI 布局、面板呼出、搜索和方向键选择，这些没有在本轮测量或修改。

## 定位

- 在 macOS 15.6 / Apple Silicon，使用隔离 profile、7,502 条历史（7,502 个附件，约 38 MB）、暂停记录、关闭联网预览，用 `sample` 采样持久化队列。
- 此前 Codex 的两份采样文件调用栈为空，无法归因。本次采样有效。
- 旧实现的后台读取时间几乎全部耗在每个附件的文件系统元数据查询：逐附件 `DataDirectory.ready()`（FileProvider 判断）、不带 `isDirectory` 的 `appendingPathComponent`（每次访问磁盘）、重复的 `resolvingSymlinksInPath()`、单独的 `resourceValues(.fileSizeKey)`；另有用 `String(format:"%02x")` 拼 SHA-256 十六进制的开销。
- 用同一夹具单独测试：读取逻辑 1.04–1.21 s 降到约 0.135 s；30,000 次摘要拼接 601 ms 降到 23 ms。

## 修改

- `HistoryStorage.read`：`blobs` 目录与 iCloud 状态只解析一次；非 iCloud 目录跳过逐附件占位文件判断，读取失败时再调用 `ready()` 以保留“iCloud 内容正在下载”提示；符号链接用 `destinationOfSymbolicLink` 先判断，仅在是链接时才做完整解析并保持“必须仍在 blobs 目录内”的限制；大小以实际读到的字节数校验，仍报“历史内容文件缺失或损坏”。
- `HistoryStorage.write`：附件存在与大小检查合并为一次 `attributesOfItem`，路径带 `isDirectory: false`。
- `HistoryStorage.digest` 及 `Clip.fingerprint`、`LinkPreviewCache.fileKey` 的十六进制输出改为查表，输出与旧实现一致。
- 未改：`DataDirectory.baseline` 的逐条签名（本地目录也会计算）。同步目录可能在运行中出现，贸然跳过会让后续同步的基线失真，所以保留。

## 结果

候选：当前工作树（`HistoryStorage.swift`、`Model.swift`、`RichPreviews.swift`），`build/OpenPaste.app` 二进制 SHA-256 `2b1349bf4662e4c4295a1eb05ce01e058c8cb7b15eaa7128cb693694d98e074c`。对照：Codex 构建的 `ProfileOpenPaste.app`（改动前）。两者均用 get-task-allow 临时签名，同一台机器、同一夹具，交替运行各 3 次，每次新进程新 profile。系统文件缓存为热状态，无法在无特权下清空，因此不是磁盘冷读。

| 指标（ms） | 改动前 | 改动后 |
|---|---|---|
| `history.initial-load.background`（后台总耗时） | 2805.7 / 2283.0 / 2003.2 | 875.9 / 629.8 / 589.0 |
| `history.initial-install` 同步 | 39.9 / 36.5 / 37.3 | 33.5 / 32.5 / 31.9 |
| `history.initial-install` 到下一轮 | 198.0 / 121.7 / 87.1 | 88.6 / 69.3 / 66.9 |

后台读取约快 3.2–3.6 倍，仍剩约 0.6–0.9 s，其中约一半是 `clipSignature` 的 JSON 编码，其余是附件读取。装入后的主线程间隔也有下降，但样本少、波动大，不作为通过结论。

自动验证：`scripts/unit-tests.sh` 退出 0（含存储恢复、目录迁移、导入、清理、预览缓存等）；SwiftLint 0 违规；生产二进制检查通过。

## 未执行 / 未覆盖

- 未测 iCloud 目录、含 `device-*.json` 的同步目录、附件被替换成符号链接、附件被 iCloud 驱逐为占位文件的真实表现，只有现有单元测试的覆盖。
- 未测磁盘冷读、Intel、macOS 14。
- 未测面板呼出、搜索、方向键和新复制后的列表更新卡顿；`ClipCard` 的 `@ObservedObject` 导致整排卡片重复求值只是读代码的推测，没有实测。
- 未更换 `/Applications/OpenPaste.app`，未提交、推送或发布。
- 证据：`build/acceptance-results/2026-10-08-history-load-perf/`（日志、两份有效采样、对照脚本）。

## 补充：新复制一条后的主线程停顿（7,502 条）

方法：临时在测试构建里加入一个只调用真实 `Store.capture(force:true, pasteboard:)` 的计时入口（独立命名剪贴板，不碰系统剪贴板），加载同一份 7,502 条夹具，连续复制 30 条不同文本，丢弃前 5 条预热，记录每条的主线程同步耗时。测试后已删除该入口并核对源码哈希恢复。同一台机器、交替构建改前（保留 `archive.clips = items; prune()` 两次发布）与改后各跑 3 次。

| 指标（ms） | 改动前 | 改动后 |
|---|---|---|
| 同步耗时中位数 | 79.1 / 106.7 / 118.9 | 53.2 / 44.6 / 43.0 |
| 同步耗时最大值 | 258.3 / 228.4 / 372.3 | 83.4 / 68.4 / 98.0 |
| 每次复制的筛选次数 | 2 | 1 |

停顿约减半，但中位数仍有 43–53 ms，最大值仍可到约 100 ms，未达到 16 ms 级别，也未归因到具体函数（预期包含全量筛选、排序、`byteCount`、去重指纹比较）。这是进程内计时，不含 SwiftUI 重绘，不代表按键到画面的延迟。

## 补充：附件符号链接规则

写入与读取使用同一规则（`blobState`）：已存在的附件必须是 `blobs` 内的普通文件，符号链接只有解析后仍位于 `blobs` 内才接受，且大小匹配；失效链接视为不存在并被原子写入替换。新增回归：失效链接（自身大小等于附件大小）被替换并可读；指向 `blobs` 之外的有效链接在写入和读取都被拒绝；目录占位被拒绝；指向 `blobs` 内普通文件的链接被接受；大小不符被拒绝。

最终候选再次冷启动 3 次：后台加载 2289 / 742 / 506 ms。第一次是构建后首次运行，明显偏慢，原因未查明，不作为通过依据。
