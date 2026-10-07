import SwiftUI
import AppKit

enum SettingsPage: String, CaseIterable {
    case general = "通用", translation = "快速翻译", privacy = "隐私与权限", data = "数据管理", about = "关于"
    var icon: String { switch self { case .general: return "slider.horizontal.3"; case .translation: return "character.bubble"; case .privacy: return "hand.raised"; case .data: return "externaldrive"; case .about: return "info.circle" } }
    var subtitle: String { switch self { case .general: return "调整呼出方式、历史记录与内容预览"; case .translation: return "连接你自己的翻译服务，选中即译"; case .privacy: return "控制记录范围与直接粘贴权限"; case .data: return "管理本机历史，或从 Paste 迁移内容"; case .about: return "应用信息与使用授权" } }
}
final class SettingsDirectoryInfo: ObservableObject {
    @Published private(set) var isCloud = false
    private var root: URL?
    func refresh(_ root: URL) {
        guard self.root != root else { return }
        self.root = root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cloud = DataDirectory.isCloud(root)
            DispatchQueue.main.async {
                guard let self, self.root == root else { return }
                self.isCloud = cloud
            }
        }
    }
}
struct SettingsView: View {
    static let privacyNotification = Notification.Name("OpenPasteShowPrivacy")
    @ObservedObject var store: Store
    @StateObject private var directory = SettingsDirectoryInfo()
    @State private var page: SettingsPage = CommandLine.arguments.contains("--about") ? .about : .general
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 9) { Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32); VStack(alignment: .leading, spacing: 2) { Text("OpenPaste").font(.system(size: 15, weight: .semibold)); Text("本机剪贴板").font(.system(size: 11)).foregroundStyle(.secondary) } }.padding(.top, 8)
                VStack(spacing: 5) {
                    ForEach(SettingsPage.allCases, id: \.self) { item in
                        Button { Controller.shared.cancelShortcutRecording(); page = item } label: {
                            Label(item.rawValue, systemImage: item.icon).font(.system(size: 13, weight: page == item ? .medium : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
                                .foregroundStyle(page == item ? Color.white : Color.primary).background(page == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) { Label(directory.isCloud ? "iCloud Drive 同步" : "本机数据目录", systemImage: directory.isCloud ? "icloud" : "internaldrive"); Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "OpenPasteReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") }.font(.system(size: 11)).foregroundStyle(.secondary)
                Button { Controller.shared.quit() } label: {
                    Label("退出 OpenPaste", systemImage: "power").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered).controlSize(.small).help("退出程序并保存历史记录")
            }.padding(16).frame(width: 170).background(.regularMaterial)
            Divider()
            SettingsPages(page: page, store: store, directory: directory)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { directory.refresh(store.root) }
        .onChange(of: store.root) { _, root in directory.refresh(root) }
        .onReceive(NotificationCenter.default.publisher(for: UpdateChecker.aboutNotification)) { _ in page = .about }
        .onReceive(NotificationCenter.default.publisher(for: Self.privacyNotification)) { _ in page = .privacy }
    }
}

func runSettingsPageCacheTests(store: Store) {
    let coordinator = SettingsPages.Coordinator()
    let directory = SettingsDirectoryInfo()
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 570, height: 620))
    let passes = store.filterPasses
    for page in SettingsPage.allCases { coordinator.show(page, in: container, store: store, directory: directory) }
    let original = coordinator.hosts
    for _ in 0..<3 {
        for page in SettingsPage.allCases {
            coordinator.show(page, in: container, store: store, directory: directory)
            guard coordinator.hosts[page] === original[page], container.subviews.count == 1 else { print("FAIL: settings page was rebuilt or left duplicate views"); exit(1) }
        }
    }
    guard coordinator.hosts.count == 5, store.filterPasses == passes else { print("FAIL: settings switch rebuilt history results"); exit(1) }
    print("PASS: all five settings pages reuse their hosts without refiltering history")
}

struct SettingsPages: NSViewRepresentable {
    let page: SettingsPage
    let store: Store
    let directory: SettingsDirectoryInfo
    final class Coordinator {
        private(set) var hosts: [SettingsPage: NSHostingView<SettingsPageView>] = [:]
        private var current: SettingsPage?
        func show(_ page: SettingsPage, in container: NSView, store: Store, directory: SettingsDirectoryInfo) {
            guard current != page else { return }
            if let current { hosts[current]?.removeFromSuperview() }
            let host: NSHostingView<SettingsPageView>
            if let cached = hosts[page] { host = cached }
            else {
                host = NSHostingView(rootView: SettingsPageView(store: store, directory: directory, page: page))
                host.sizingOptions = []
                host.autoresizingMask = [.width, .height]
                hosts[page] = host
            }
            host.frame = container.bounds
            container.addSubview(host)
            current = page
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.show(page, in: container, store: store, directory: directory)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.show(page, in: container, store: store, directory: directory)
    }
}

struct SettingsPageView: View {
    @ObservedObject var store: Store
    @ObservedObject var directory: SettingsDirectoryInfo
    let page: SettingsPage
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var analytics = UsageAnalytics.shared
    @State private var translationKey = ""
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14, content: content).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    var body: some View {
        VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) { Text(page == .about ? "关于 OpenPaste" : page.rawValue).font(.system(size: 23, weight: .semibold)); Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch page {
                        case .general: general
                        case .translation:
                            group("翻译服务") { TranslationSettings(key: $translationKey) }
                            HStack(alignment: .top, spacing: 9) { Image(systemName: "info.circle").foregroundStyle(.secondary); note("使用 OpenAI 兼容接口。开启后，选中文字会发送到你配置的服务；OpenPaste 不上传其他历史。") }
                        case .privacy: privacy
                        case .data: data
                        case .about: about
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(store.importingPaste || store.changingDataDirectory)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("OpenPaste").font(.system(size: 26, weight: .semibold))
                Text("让复制过的内容，随时可用。") .font(.system(size: 13)).foregroundStyle(.secondary)
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "OpenPasteReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(.vertical, 24).frame(maxWidth: .infinity).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            group("软件更新") {
                Toggle("自动检查更新", isOn: $updates.automatic).toggleStyle(.switch)
                note("开启后每天检查一次 GitHub 正式 Release，仅查询公开版本信息，不上传剪贴板内容。")
                HStack {
                    Text(updates.message).font(.system(size: 12)).foregroundStyle(updates.available == nil ? Color.secondary : Color.accentColor)
                    Spacer()
                    Button(updates.checking ? "正在检查…" : "检查更新") { updates.check() }.disabled(updates.checking)
                }
                if let release = updates.available {
                    HStack {
                        Button("查看新版 \(release.version)…") { Controller.shared.showUpdateDetails() }.buttonStyle(.borderedProminent)
                        Button("跳过此版本") { updates.skip() }
                    }
                }
            }
            group("为 macOS 打造") {
                Label("历史与收藏，找回每一次复制", systemImage: "doc.on.clipboard")
                Label("预览、编辑与键盘快速取用", systemImage: "keyboard")
                Label("连接自己的服务，快速翻译选中文字", systemImage: "character.bubble")
                Divider()
                note("默认本机保存，无账号。网页与地图预览、快速翻译按设置联网；选择 iCloud Drive 目录后由系统同步历史。")
            }
            group("Firebase 使用统计") {
                HStack {
                    Label("Google Firebase Analytics", systemImage: "chart.bar")
                    Spacer()
                    Text(analytics.available ? (analytics.enabled ? "已开启" : "已关闭") : "未配置")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if analytics.available {
                    note("官方构建默认开启。OpenPaste 向 Google Firebase Analytics 记录首次启动、粘贴取用和翻译成功三项次数；首次启动用于估算安装量。Firebase SDK 还会处理应用实例标识、设备与应用版本等基础信息。")
                    note("不发送剪贴板内容、所选文字、网址、文件路径或翻译 API Key。可在「隐私与权限」关闭，关闭后停止收集并清除本机统计标识。")
                    Button("管理使用统计…") { NotificationCenter.default.post(name: SettingsView.privacyNotification, object: nil) }.buttonStyle(.link)
                } else {
                    note("此构建未配置 Firebase，不会发送使用统计。")
                }
            }
            group("使用与授权") {
                Text("个人及公司使用均免费").font(.system(size: 13, weight: .medium))
                Text("基于 OpenPaste · Copyright © 2026 SwallOwDili").font(.system(size: 12))
                Link("https://github.com/SwallOwDili/OpenPaste", destination: URL(string: "https://github.com/SwallOwDili/OpenPaste")!).font(.system(size: 12))
                note("私人修改和内部使用无需公开源码。对外发行（含售卖）须提供对应源码，保留界面署名、版权与许可证，不得缩小接收者权利。闭源发行或移除规定的项目声明，须另行获取付费书面授权；不免除第三方义务。本软件不提供担保。")
                HStack {
                    Menu("许可证") {
                        Button("中文参考译文") { if let url = Bundle.main.url(forResource: "LICENSE.zh-CN", withExtension: "txt") { NSWorkspace.shared.open(url) } }
                        Button("English · GPL v3 原文") { if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { NSWorkspace.shared.open(url) } }
                    }
                    Menu("署名条款") {
                        Button("中文") { if let url = Bundle.main.url(forResource: "NOTICE.zh-CN", withExtension: "txt") { NSWorkspace.shared.open(url) } }
                        Button("English") { if let url = Bundle.main.url(forResource: "NOTICE", withExtension: nil) { NSWorkspace.shared.open(url) } }
                    }
                }
                note("中文译文供理解使用，法律条款以英文原文为准。")

            }
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("键盘操作") {
                HStack { Text("呼出剪贴板"); Spacer(); Text(store.recordingShortcut ? "请按组合键…" : store.shortcutLabel).font(.system(size: 12, weight: .medium, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)); Button(store.recordingShortcut ? "取消" : "更改…") { Controller.shared.beginShortcutRecording() } }
                HStack { note(store.shortcutNotice.isEmpty ? "使用 ⌃、⌥ 或 ⇧⌘ 搭配一个按键。录制时按 Esc 取消。" : store.shortcutNotice); Spacer(); Button("恢复默认") { Controller.shared.cancelShortcutRecording(); Controller.shared.installShortcut(.standard, persist: true) }.buttonStyle(.link).font(.caption) }
            }
            group("历史记录") {
                HStack { Text("记录条数"); Spacer(); Picker("记录条数", selection: Binding(get: { store.limit }, set: { store.limit = $0 })) { Text("不限制").tag(0); Text("500 条").tag(500); Text("1,000 条").tag(1000); Text("5,000 条").tag(5000); if store.limit > 5000 { Text("\(store.limit) 条").tag(store.limit) } }.labelsHidden().frame(width: 150) }
                Divider()
                HStack { Text("保留时间"); Spacer(); Picker("保留时间", selection: $store.retentionDays) { Text("永久").tag(0); Text("1 天").tag(1); Text("1 周").tag(7); Text("1 月").tag(30); Text("1 年").tag(365) }.labelsHidden().frame(width: 150) }
                note("收藏内容不受条数与时间限制。当前容量上限 \(store.storageLimitMB) MB；单条超过 20 MB 时跳过。")
            }
            group("内容预览") {
                HStack { Text("加载网页与地图预览"); Spacer(); Toggle("加载网页与地图预览", isOn: $store.networkPreviews).labelsHidden().toggleStyle(.switch) }
                note("访问对应网页与 Apple 地图以获取预览。关闭后不再发起新的预览请求。")
                Divider()
                HStack { VStack(alignment: .leading, spacing: 4) { Text("图片文字识别"); note(store.ocrProgress.isEmpty ? "识别后的文字可在历史中搜索" : store.ocrProgress) }; Spacer(); Button(store.indexingImages ? "识别中…" : "识别历史图片") { store.indexImages() }.disabled(store.indexingImages) }
            }
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("辅助功能") {
                HStack { Label("直接粘贴", systemImage: "keyboard"); Spacer(); Label(store.permissionStatus, systemImage: store.directPasteAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle").font(.caption).foregroundStyle(store.directPasteAuthorized ? Color.green : Color.orange) }
                note("授权后可返回原输入框自动粘贴。未授权时，取用内容后手动按 ⌘V。")
                Button("打开辅助功能设置…") { Controller.shared.requestAccessibility() }
                if !store.directPasteAuthorized { note("开关已打开但未生效时，退出并重开 OpenPaste；仍无效时移除旧条目，重新添加 /Applications/OpenPaste.app。") }
            }
            group("排除应用") {
                note("这些应用的复制内容不会记录，也不会执行快速翻译。每行填写一个 Bundle ID。")
                TextEditor(text: Binding(get: { store.ignored }, set: { store.ignored = $0 })).font(.system(size: 12, design: .monospaced)).frame(height: 108).padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08)))
                Button("排除当前目标应用") { if let id = Controller.shared.target?.bundleIdentifier, !store.ignored.components(separatedBy: .newlines).contains(id) { store.ignored += "\n" + id } }.disabled(Controller.shared.target == nil)
            }
            group("记录控制") { HStack { Text(store.paused ? "记录已暂停" : "正在记录剪贴板"); Spacer(); Button(store.paused ? "继续记录" : "暂停记录") { Controller.shared.togglePause() } }; note("普通文字中的密码无法可靠识别，请使用排除应用或暂停记录。历史由 macOS 账户权限和磁盘保护，未单独加密。") }
            group("匿名使用统计") {
                HStack { Text("帮助改进 OpenPaste"); Spacer(); Toggle("帮助改进 OpenPaste", isOn: $analytics.enabled).labelsHidden().toggleStyle(.switch).disabled(!analytics.available) }
                if analytics.available {
                    note("默认开启。OpenPaste 向 Google Firebase Analytics 记录首次启动、粘贴取用和翻译成功三项次数；首次启动用于估算安装量。SDK 还会处理应用实例标识、设备与应用版本等基础信息。不会发送剪贴板内容、所选文字、网址、文件路径或翻译 API Key。关闭后停止收集并清除本机统计标识。")
                } else {
                    note("此构建未配置 Firebase，使用统计不可用。历史和剪贴板功能不受影响。")
                }
            }
        }
    }
    private var data: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("数据保存目录") {
                HStack { Label(directory.isCloud ? "iCloud Drive" : (store.root.standardizedFileURL == DataDirectory.defaultRoot.standardizedFileURL ? "本机默认目录" : "自定义目录"), systemImage: directory.isCloud ? "icloud" : "folder"); Spacer(); Button("打开目录") { Controller.shared.openExternal(store.root) } }
                Text(store.root.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
                HStack { Button("更改目录…") { store.chooseDataDirectory() }.buttonStyle(.borderedProminent); if store.root.standardizedFileURL != DataDirectory.defaultRoot.standardizedFileURL { Button("恢复默认目录") { store.changeDataDirectory(to: DataDirectory.defaultRoot) } } }
                note("历史、收藏和图片附件一起迁移，目标已有历史会合并，原目录保留为备份。选择 iCloud Drive 中的专用文件夹后，由系统同步数据；其他 Mac 选择同一文件夹即可读取历史。")
                note("离线缓存、翻译 API Key、快捷键和权限配置留在本机。文件条目只保存引用，另一台 Mac 不一定能访问原文件。")
                if !store.directoryStatus.isEmpty { Text(store.directoryStatus).font(.caption).foregroundStyle(store.directoryStatus.hasPrefix("切换失败") ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true) }
                if store.changingDataDirectory { Text(store.directoryProgress.phase).font(.caption); ProgressView(value: store.directoryProgress.fraction); Text("\(store.directoryProgress.completed) / \(store.directoryProgress.total)").font(.caption).monospacedDigit() }
            }
            group("从 Paste 迁移") {
                note("保留时间、来源、收藏分组和原始格式。自动去重，导入前备份现有历史；按磁盘可用空间计算容量。")
                HStack { Button("从 Paste 导入…") { Controller.shared.importPaste() }.buttonStyle(.borderedProminent); Button("选择数据文件…") { Controller.shared.importPaste(selectFile: true) } }
            }
            if store.importingPaste { group("导入进度") { Text(store.importProgress.phase); if store.importProgress.total > 0 { ProgressView(value: store.importProgress.fraction); Text("\(store.importProgress.completed) / \(store.importProgress.total)").font(.caption).monospacedDigit() } else { ProgressView().controlSize(.small) } } }
            if store.message.hasPrefix("已导入") || store.message.hasPrefix("导入失败") { note(store.message) }
            group("清理历史") { HStack { VStack(alignment: .leading, spacing: 4) { Text("清空历史记录"); note("收藏内容会保留，此操作无法撤销。") }; Spacer(); Button("清空历史…", role: .destructive) { Controller.shared.confirmClear() } } }
        }
    }
}
