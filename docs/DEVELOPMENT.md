# 开发与发布

本文面向源码构建、贡献与发布维护者。产品使用说明见 [README](../README.md)。以下命令均在项目根目录执行。

## 本地构建

构建需要 Xcode Command Line Tools 和网络连接；首次构建会通过 Swift Package Manager 下载 Firebase Analytics 依赖：

```sh
xcode-select --install
./build.sh
```

源码构建默认不连接官方统计项目：仓库不包含 `Assets/GoogleService-Info.plist`，缺少该文件时 App 的统计开关不可用。如需接入你自己的 Firebase 项目，将该项目下载的配置文件放在 `Assets/GoogleService-Info.plist` 后重新构建；该路径已被 Git 忽略。

生成的应用位于 `build/OpenPaste.app`。构建默认使用临时签名；如果你有可用的签名身份：

```sh
OPENPASTE_SIGNING_IDENTITY="你的签名身份" ./build.sh
```

退出正在运行的 OpenPaste，再将生成的应用复制到应用程序目录：

```sh
ditto build/OpenPaste.app /Applications/OpenPaste.app
open /Applications/OpenPaste.app
```

固定签名身份有助于更新时保持应用身份，但临时签名、应用 ID 变化或系统状态变化仍可能导致权限需要重新授权。不要将证书、私钥或 API Key 提交到仓库。

## GitHub 自动构建与 Release

提交到 `main` / `master` 或创建 PR 后，先编译测试可执行文件并跑单元测试，再执行安全检查；测试、代码规范和依赖漏洞扫描全部通过，且 PR 贡献者已签署 CLA 后才组装 App 并生成 ZIP。发布 Release 时也依次执行单元与集成测试、代码规范检查、依赖漏洞扫描和安全检查，再构建通用 App，上传 ZIP 与 SHA-256 校验文件。通用包包含 Apple Silicon 与 Intel 两种架构，最低支持 macOS 14。

普通 CI 不注入 Firebase 配置；正式 Release 工作流从仓库 Secret `OPENPASTE_FIREBASE_CONFIG_B64` 还原官方配置，再嵌入安装包。此 Secret 已在官方仓库设置。更换 Firebase 配置时，仓库维护者可运行：

```sh
base64 < /path/to/GoogleService-Info.plist | tr -d '\n' | gh secret set OPENPASTE_FIREBASE_CONFIG_B64 --repo SwallOwDili/OpenPaste
```

发布构建缺少 Secret 或配置的 Bundle ID 不匹配时会直接失败。源码仓库不存放官方配置；客户端配置仍会包含在最终 App 内。

发布步骤：

1. 将本项目根目录内容提交到仓库，包含 `.github/workflows/`。
2. 在 GitHub 创建 Release，标签使用 `v0.6.0` 等 `v主版本.次版本.修订版本` 格式；也接受 `v0.6.0-beta.1`。
3. 发布后，Actions 从该标签的代码构建，完成检查后把 `OpenPaste-0.6.0-macos-universal.zip` 和 `.sha256` 上传到同一 Release。

App 的版本来自 Release 标签，Build 来自工作流运行编号；预发布版本在「关于」页面显示完整后缀。GitHub Release 的标题不会影响版本号。工作流可重复运行，同名附件会覆盖。

版本来源按以下优先级确定，不再使用写死的本地版本文件：

| 构建来源 | App 显示版本 |
| --- | --- |
| GitHub Release 工作流 | 标签版本，如 `0.6.0` 或 `0.6.0-beta.1` |
| 本地 Git / 普通 CI 构建 | 分支名 + 8 位 commit，如 `main-a1b2c3d4` |
| 无 Git 仓库或尚无 commit | `draft` |

分离 HEAD 时，CI 使用 GitHub 分支信息，本地使用 `detached-commitid`。开发版本的系统数字版本为 `0.0.0`，界面显示上述版本标识。开发构建仍可检查正式 Release；不会将分支名当作语义版本比较。内部构建号自动生成：本地为 `1`，GitHub 构建直接使用系统提供的工作流运行编号，无需手动传参；仅保留在 App 元数据中，界面不显示。

需要显式模拟 Release 构建时：

```sh
OPENPASTE_VERSION=v0.6.0 OPENPASTE_ARCH=universal ./build.sh
```

GitHub 默认提供上传所需的 `GITHUB_TOKEN`，无需另配个人访问令牌。当前自动构建使用临时签名，尚未接入 Developer ID 证书和 Apple 公证；与本机固定签名不是同一个身份，更新后权限可能需要重新授权。

如果开启 GitHub 的不可变 Release，须先创建草稿，再在 Actions 手动运行 **Build release**、填写该草稿标签，待附件上传完成后发布。不可变 Release 发布后不能追加或替换附件，工作流会明确报错。

工作流配置见 [release.yml](../.github/workflows/release.yml) 和 [ci.yml](../.github/workflows/ci.yml)。Release 只公开安装包 ZIP 与 SHA-256 校验文件；调试符号单独保留在 Actions Artifacts，保存 14 天。此流程发布安装包。App 已支持正式 Release 检测和下载页入口；安装仍由用户手动替换，不自动下载或安装。

## 自动检查与 CLA

顺序为 **单元与集成测试 → 代码规范检查 → 依赖漏洞扫描 → 安全检查 → CLA 核验（PR）→ App 构建与打包**。测试阶段编译可执行文件，不组装、签名或打包 App。集成测试覆盖本地翻译 HTTP 模拟服务、数据目录与剪贴板导入流程，不调用真实翻译服务。

代码规范使用 SwiftLint 的明确规则、Actionlint 工作流检查、Shell/Python/JavaScript 语法检查。规则配置见 `.swiftlint.yml`。依赖扫描读取 `Package.resolved` 的全部直接与传递依赖，按锁定版本查询 GitHub Advisory Database，发现 high/critical 漏洞阻塞；数据库访问失败、依赖未锁定也阻塞。此扫描无需启用仓库 Dependency Graph。扫描覆盖已公开的 Swift 依赖公告，不能证明不存在未知漏洞，也不覆盖二进制内部未声明的依赖。

安全阶段用 Gitleaks 扫描源码与新增提交中的密钥，并测试 Firebase 配置输入校验。上述检查不调用 AI 服务，不需要模型密钥。

外部 PR 在无 Secret、只读权限的任务中测试；可信的 `workflow_run` 工作流确认测试成功和 CLA 已签署，才启动独立的打包任务。CLA 使用 `pull_request_target` 和签署评论事件，但只执行默认分支的受信脚本，绝不运行 PR 代码。签署记录存放在独立的 `cla-signatures` 分支；多人贡献逐人核验，未关联 GitHub 账号的提交作者必须先关联账号。签署成功会重新触发已通过测试的当前 PR commit 的打包核验。

官方仓库主分支必需检查为 `CLA` 和 `test-security`，要求基于最新主分支验证，管理员保留绕过权限。Fork 仓库须自行配置分支保护。CI 安装包在 **Check and package** 的 Artifacts 下载，Release 安装包在对应 Release 下载。

相关配置：[CI](../.github/workflows/ci.yml)、[核验与打包](../.github/workflows/package.yml)、[CLA](../.github/workflows/cla.yml)、[Release](../.github/workflows/release.yml)。

## 开发与验证

```sh
./build.sh
./scripts/check.sh
```

逻辑检查使用临时数据和测试剪贴板。翻译检查需要 Python 3，并在 `127.0.0.1:18767` 启动本机模拟服务，使用虚构凭据，不访问你的翻译接口。

窗口检查需要图形环境；先退出正常实例，再运行：

```sh
build/OpenPaste.app/Contents/MacOS/OpenPaste --layout-test
```

验证范围见 [验证说明](VALIDATION.md)。贡献方式见 [CONTRIBUTING.md](../CONTRIBUTING.md)，版本变化见 [CHANGELOG](CHANGELOG.md)。

## 数据存储实现

默认历史目录为 `~/Library/Application Support/OpenPaste/`：

```text
OpenPaste/
├── history.json                 # 本机历史索引
├── blobs/                       # 按内容摘要命名的附件
├── before-*.json                # 导入或迁移前的备份（按需生成）
└── device-*.json                # 共享目录中的设备索引（按需生成）
```

后台每 0.3 秒检查剪贴板变化，因此极短时间内连续复制的中间内容可能漏记。

本地保存完成后回收无引用附件，保留撤销记录、备份及冲突版本的引用；相关索引不可读取时暂停回收。共享目录的索引可能落后于离线设备，因此不自动删除共享附件，仅回收本机离线缓存中的无引用附件。

网页与地图预览缓存保留 7 天，目标容量上限 100 MB。磁盘读取、写入和目录清理在后台串行执行；磁盘命中不占用网络名额，未命中时最多并行运行两个网络任务，单任务超时 20 秒后取消。

自定义粘贴事件 `content_pasted` 在按键事件发送后记录，仅复制或发送前失败不计入；该事件无法确认目标应用是否接受粘贴。

## 目录结构

```text
OpenPaste/
├── .github/workflows/    # 持续构建与 Release 发布
├── Assets/               # 应用图标；本机 Firebase 配置不提交
├── Sources/              # Swift 源码与检查入口
├── Tests/                # 本机翻译模拟服务
├── scripts/              # 构建和检查脚本
├── docs/                 # 变更与验证说明
├── build.sh              # 构建入口
├── CONTRIBUTING.md
└── README.md
```

`build/` 和 `.build/` 为本机生成目录，不提交 Git。应用通过 Swift Package Manager 编译，再由 `build.sh` 组装和签名。
