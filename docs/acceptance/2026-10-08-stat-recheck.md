# 2026-10-08 附件写入 stat 修复复核

结论：原悬空链接回归已修复，但有效的越界链接仍可被错误当作正常附件，不能将本次存储修复判为通过。本轮只读核查产品源码并记录证据，没有替换 App 或发布。

## 已验证修复

当前 `HistoryStorage.write` 使用 `stat` 追随链接并读取目标大小。重新编译真实工作树 `HistoryStorage.swift`，执行此前独立复现：悬空链接自身长度与 8 字节附件相等时，`stat` 失败，原子写入正确替换链接，随后 read 读回相同字节。

`MaintenanceTests.swift` 已新增悬空链接写入后读回，以及已有普通附件尺寸不符的检查。两文件 SwiftLint 0 违规，`git diff --check` 通过。

## 未解决：写入与读取对有效越界链接的判断不一致

位置：`Sources/HistoryStorage.swift:103–104`（stat 成功后只校验大小）。

在专用临时目录创建 8 字节普通文件，再将 `history/blobs/<合法ID>` 指向该文件；文件位于 blobs 目录之外，附件数据同为 8 字节。使用当前真实存储文件和最小外围桩独立编译、运行：

- 当前版：`outside-symlink write=SUCCESS`，随后 `read=FAIL 历史内容文件缺失或损坏`。
- Git HEAD：同一夹具在 write 阶段 `REJECTED 已有内容文件损坏`。

原因：`stat` 读取目标文件大小，旧 `resourceValues(.fileSizeKey)` 在此环境读链接自身大小。新写入路径只比较目标大小，未执行 read 路径要求的“解析后必须仍位于 blobs 内”的检查。于是可以成功发布一个自身 read 无法读取的索引。旧实现也有特殊长度碰撞下误接受链接的既有缺陷，不能把所有符号链接问题都归因于本次更改；本次所列夹具已实测为旧拒绝、新接受。

建议让 read/write 使用一致的附件有效性规则：悬空链接安全替换；有效链接明确要求目标为普通文件、解析后位置合法、大小一致，或统一用手头数据原子替换链接。不能只比较 st_size。新增有效内部链接、有效外部链接、非普通节点的保存后读取测试。

## 验证范围和阻塞

主 Agent 已独立执行上述两种真实存储代码复现，原临时数据均不涉及用户历史。证据位于 `build/acceptance-results/2026-10-08-stat-recheck/`，含固定案例结果、源码哈希、复现源码及日志。

相关项目测试计划运行 maintenance、storage-recovery、data-directory、paste-import-unit、self-test；但共享构建先等待另一任务，随后因并行任务在构建期间修改 `Sources/Model.swift` 而失败：`input file ... was modified during the build`。因此这五组本轮未执行完成，不能宣称通过；也不将构建冲突归为产品代码编译错误。此次未重复性能测试或 GUI 验收。

复核时 `HistoryStorage.swift` SHA-256：`952b72bf69bcdec39be34a394b5921e293ff38eee7ace4ebfe1634cf09a24c31`；`MaintenanceTests.swift` SHA-256：`7ebef4eab5361e4535012aa9c18e8bbd6d848feaa815ec93f39cdf4ca6472354`。
