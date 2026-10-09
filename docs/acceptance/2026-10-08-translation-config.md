# 2026-10-08 翻译配置文件验收

最终方案已改为复用应用偏好配置 `~/Library/Preferences/io.github.SwallOwDili.OpenPaste.plist`，不再使用独立 JSON。以下保留各轮实测记录，最终方案的结果见文末。

## 变更

- API Key 直接存入 `~/Library/Application Support/OpenPaste-configuration/translation.json`，JSON 字段为 `apiKey`。目录 0700、文件 0600，原子替换。
- 删除翻译模块全部钥匙串读写及服务标识；不提供存储方式选项，不读取或迁移旧钥匙串。
- 配置目录独立于历史目录，不参与历史迁移或 iCloud 同步。文件读写在后台串行执行。
- 保存成功才清空输入框；失败保留输入，未持久化的地址和模型不提交。保存期间拒绝重复提交，取消后的异步读密钥回调不发请求。

## 候选与证据

- 源码：`main` / `9d714bc9` 基础上的本地未提交修改；仅本机 arm64 构建，未发布。
- 产物：`build/OpenPaste.app`。
- 二进制 SHA-256：`3bcd534a878a6751426277311146bcaffb930ba320f7c71479d0b808e08f3da5`。
- 日志：`build/acceptance-results/2026-10-08-local-translation-config/`。本机证据目录不进入发布包。

## 实测结果

| 场景 | 方法与结果 |
| --- | --- |
| 存储与配置逻辑 | 27 项检查通过：首次保存、覆盖、重建实例读取、空白沿用、缺少 Key、损坏 JSON 恢复、符号链接拒绝、权限、配置隔离、失败不提交其他字段、重复提交拒绝 |
| 环境与测试入口 | 19 项 Python 测试通过；生产与验收配置路径分离，配置路径越界及符号链接拒绝；CI 两个测试入口均包含配置存储检查 |
| 翻译协议 | 23 项断言通过，包括 localhost HTTP 请求与响应；只使用假密钥与模拟服务 |
| 设置界面首次保存 | 独立 acceptance profile，开启快速翻译；空 Key 保存提示“请填写 API Key”；填写 `fixture-key` 后显示“配置已保存”，实际 JSON 值一致、目录与文件权限正确 |
| 设置界面重启 | 退出并重新启动验收实例；Key 输入留空再保存，显示“配置已保存”，沿用文件中的 Key |
| 设置界面写入失败与恢复 | 将隔离配置文件路径临时替换成目录，保存新假 Key 后显示失败，输入框保留；恢复旧文件后不重新输入直接保存成功，核对 JSON 已更新为新假 Key |
| 授权弹窗 | 上述保存、重启、读取及重试流程未触发钥匙串授权；源码扫描确认翻译路径无 SecItem、kSec、keychainService 或 Security 导入 |
| 构建 | arm64 release 构建、严格签名验证与 diff 空白检查通过 |

## 范围与清理

- GUI 验收在专用 profile 执行，使用 localhost 地址与假密钥；未验证用户真实翻译服务，也未将本轮结果作为跨应用选区替换验收。
- 验收结束后关闭该 profile 的翻译开关并正常退出。CUA 退出后查询曾额外启动无 profile 实例，发现后已正常关闭；后续退出不再查询已退出窗口。
- 没有安装覆盖 `/Applications/OpenPaste.app`，没有提交、推送或发布。日常安装版需另行替换才包含本轮改动。

## 同日调整：统一使用 OpenPaste 目录

- 根据用户要求，将生产配置固定为 `~/Library/Application Support/OpenPaste/translation.json`；验收配置同样位于 profile 内的 `Application Support/OpenPaste/translation.json`。无旧目录兼容或迁移逻辑。
- 默认配置目录与默认历史目录共用；配置路径固定，不跟随用户选择的历史目录改变。历史迁移、同步、导入、备份只处理命名明确的历史索引和附件；清空历史及垃圾回收不删除翻译配置。已只读核查对应写入、枚举和删除路径。
- 19 项环境及测试入口检查、27 项配置检查、26 项目录回归通过；arm64 构建、严格签名校验、SwiftLint 与 diff 空白检查通过。
- GUI：在隔离 profile 的快速翻译设置输入假 Key 并保存，显示“配置已保存”；实际新目录 JSON 值匹配，文件权限 0600。关闭该 profile 翻译开关后正常退出。
- 新候选 SHA-256：`923f24bf4c46e8fca40a6662873821a31615b40c2298f838fa49cd0e196a8ad0`。证据位于 `build/acceptance-results/2026-10-08-translation-directory/`。
- 本轮未重跑真实服务或跨应用粘贴验收，未覆盖日常安装的 App，未提交或发布。

## 最终方案：复用应用偏好配置

- API Key 改为 `AppEnvironment.current.defaults` 的 `translationAPIKey` 字段，和 `translationBase`、`translationModel`、`translationLanguage` 一同保存。生产使用 macOS 管理的 `~/Library/Preferences/io.github.SwallOwDili.OpenPaste.plist`；不自行写入 plist 文件。
- 删除独立凭据文件存储类、专用目录字段及校验；无钥匙串、JSON 回退或迁移逻辑。界面与 README 已同步。
- 空白 Key 沿用已保存值；非法地址、缺少 Key 或模型时保存失败，输入与已保存字段保留；保存成功取消旧翻译请求并更新 revision。
- 15 项配置测试和 18 项环境／入口测试通过；arm64 构建、SwiftLint、签名验证及 diff 检查通过。
- 真实 GUI：隔离 profile 中存在旧 JSON 假 Key，但新配置首次留空保存仍提示缺少 Key，证明没有回退读取；输入假 Key 后保存成功。退出后检查该验收 suite 的实际 plist，Key、地址、模型与语言均在同一份文件中；重启后留空 Key 保存成功。全过程没有触发钥匙串授权。
- 结束时关闭验收 profile 的翻译开关并正常退出。未读取或写入生产密钥，未覆盖日常安装 App，未提交或发布。
- 本轮未重跑真实翻译服务或跨应用替换验收；当前候选 SHA-256：`ab9cce2bda717b89bde8add89014c77577b8409448d33a2705ba37afb8c8e14b`。证据：`build/acceptance-results/2026-10-08-translation-preferences/`。

## 本地安装部署

- 用户确认本地部署后，旧实例通过已有 SIGTERM 正常退出处理保存历史并结束。
- 将上一节已验证构建安装到 `/Applications/OpenPaste.app`，签名严格校验通过，安装后二进制 SHA-256 与候选一致。
- 已启动安装版，核对只有一个 OpenPaste 主程序进程，运行路径为 `/Applications/OpenPaste.app/Contents/MacOS/OpenPaste`。启动后主线程采样处于正常事件循环，未出现钥匙串调用等待。
- 旧 App 备份：`build/local-backups/OpenPaste-before-preferences-7bd255e9dd.zip`，ZIP 完整性检查通过。
- 本轮部署没有读取、迁移或写入生产 API Key；需用户在翻译设置重新填写保存一次。设置保存和重启已在隔离实例实测，部署后本轮只复核进程、文件一致性与主线程采样。
- 证据：`build/acceptance-results/2026-10-08-translation-preferences/installed-app.txt` 与 `installed-process.sample`。未推送或发布。
