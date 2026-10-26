//
//  SMBConverter.swift
//  菜单栏 SMB 路径转换：Windows \\server\share  ↔  Mac smb://server/share
//

import SwiftUI
import AppKit
import ServiceManagement

// 弹窗不透明底色：浅色纯白、深色深灰（NSPopover 默认半透明毛玻璃，可读性差）
extension NSColor {
    static let popoverBg = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }
}

// MARK: - 转换逻辑（与网页版规则一致）

enum SMBConvert {
    /// 反复百分号解码到稳定状态（兼容已编码 / 重复编码，最多 3 次）
    static func fullyDecode(_ s: String) -> String {
        var cur = s
        for _ in 0..<3 {
            guard cur.contains("%"),
                  let dec = cur.removingPercentEncoding, dec != cur else { break }
            cur = dec
        }
        return cur
    }

    /// 把任意形式的单行输入解析为 [host, share, ...segments]（均为已解码原文）
    static func parse(_ raw: String) -> [String]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let low = s.lowercased()
        if low.hasPrefix("smb://") { s.removeFirst(6) }
        else if low.hasPrefix("file://") { s.removeFirst(7) }

        // 反斜杠/斜杠统一，连续斜杠折叠
        s = s.replacingOccurrences(of: #"[\\/]+"#, with: "/", options: .regularExpression)
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }

        let segs = s.split(separator: "/", omittingEmptySubsequences: true)
            .map { fullyDecode(String($0)) }
        return segs.count >= 1 ? segs : nil
    }

    /// 与 JS encodeURIComponent 一致的允许字符集
    static let componentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!*'()")
        return set
    }()

    static func toWin(_ segs: [String]) -> String {
        "\\\\" + segs.joined(separator: "\\")
    }

    static func toMac(_ segs: [String]) -> String {
        "smb://" + segs
            .map { $0.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? $0 }
            .joined(separator: "/")
    }

    enum Direction {
        case winToMac, macToWin, fileBoth, unknown
        var statusText: String {
            switch self {
            case .winToMac: return "检测到 Windows 路径 · 已转换为 Mac"
            case .macToWin: return "检测到 Mac 路径 · 已转换为 Windows"
            case .fileBoth: return "检测到 file:// 路径 · 两种格式均可复制"
            case .unknown:  return "等待输入…"
            }
        }
        /// 自动复制时偏好的目标格式
        var preferredTarget: Target {
            self == .macToWin ? .win : .mac
        }
    }

    enum Target { case win, mac }

    static func direction(of raw: String) -> Direction {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = s.lowercased()
        if low.hasPrefix("smb://") { return .macToWin }
        if low.hasPrefix("\\\\") || low.hasPrefix("//") { return .winToMac }
        if low.hasPrefix("file://") { return .fileBoth }
        if s.contains("\\") { return .winToMac }
        return .unknown
    }

    /// 只有“长得像”共享路径的剪贴板内容才自动采用
    static func looksLikeSharePath(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.hasPrefix("\\\\") || s.hasPrefix("//")
            || s.hasPrefix("smb://") || s.hasPrefix("file://")
    }
}

// MARK: - 视图模型

final class ConverterVM: ObservableObject {
    @Published var input = "" { didSet { sanitizeAndRecompute() } }
    @Published private(set) var win = ""
    @Published private(set) var mac = ""
    @Published private(set) var winLines: [String] = []
    @Published private(set) var macLines: [String] = []
    @Published private(set) var statusText = SMBConvert.Direction.unknown.statusText
    @Published private(set) var direction: SMBConvert.Direction = .unknown
    @Published private(set) var hasResult = false
    @Published private(set) var flash = ""
    @Published var focusTick = 0
    @Published var editorFocused = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// 由 AppDelegate 注入：复制/打开后关闭弹窗
    var wantsClose: (() -> Void)?

    private var lastCopiedWin = ""
    private var lastCopiedMac = ""
    private var flashTask: Task<Void, Never>?

    /// 只允许一个路径：去掉换行，仅保留首行
    private func sanitizeAndRecompute() {
        let cleaned = input
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        if cleaned != input { input = cleaned }
        recompute()
    }

    private func recompute() {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard let segs = SMBConvert.parse(line) else {
            win = ""; mac = ""; winLines = []; macLines = []
            hasResult = false
            direction = .unknown
            statusText = SMBConvert.Direction.unknown.statusText
            return
        }
        win = SMBConvert.toWin(segs)
        mac = SMBConvert.toMac(segs)
        winLines = [win]; macLines = [mac]
        hasResult = true
        direction = SMBConvert.direction(of: line)
        statusText = direction.statusText
    }

    func willOpen() {
        focusTick &+= 1
        // 自动读取剪贴板（但不采用本工具自己刚复制出去的结果）
        guard let clip = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !clip.isEmpty,
              clip != lastCopiedWin, clip != lastCopiedMac else { return }

        let anyShare = clip.components(separatedBy: .newlines).contains {
            SMBConvert.looksLikeSharePath($0)
        }
        if anyShare {
            input = clip
            // 自动填入：已复制结果，但保持面板打开，不打断用户查看/再操作
            copyPreferred(auto: true, closeAfter: false)
        }
    }

    func clear() {
        input = ""
        flash("")
    }

    @discardableResult
    private func putOnPasteboard(_ s: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(s, forType: .string)
    }

    func copy(_ target: SMBConvert.Target, auto: Bool = false, closeAfter: Bool = true) {
        let text = target == .win ? win : mac
        guard hasResult, !text.isEmpty else { return }
        guard putOnPasteboard(text) else { flash("复制失败"); return }
        if target == .win { lastCopiedWin = text } else { lastCopiedMac = text }
        let label = target == .win ? "Windows" : "Mac"
        flash("✓ 已复制 \(label) 路径\(auto ? "（来自剪贴板）" : "")")
        // 仅在用户主动操作（粘贴/回车/点卡片）后关闭；剪贴板自动填入时保持面板打开
        guard closeAfter else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            self?.wantsClose?()
        }
    }

    /// 粘贴/回车：复制与输入方向相反的目标格式
    func copyPreferred(auto: Bool = false, closeAfter: Bool = true) {
        guard hasResult else { return }
        copy(direction.preferredTarget, auto: auto, closeAfter: closeAfter)
    }

    func openInFinder() {
        // 多行时打开第一条
        guard hasResult, let first = macLines.first, let url = URL(string: first) else {
            flash("无法打开：路径无效"); return
        }
        flash(macLines.count > 1 ? "正在 Finder 中打开第 1 条…" : "正在 Finder 中打开…")
        NSWorkspace.shared.open(url)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.wantsClose?()
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
                flash("✓ 已设为开机启动")
            } else {
                try SMAppService.mainApp.unregister()
                flash("已取消开机启动")
            }
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            flash("开机启动设置失败：\(error.localizedDescription)")
        }
    }

    private func flash(_ msg: String) {
        flash = msg
        flashTask?.cancel()
        guard !msg.isEmpty else { return }
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.flash = ""
        }
    }
}

// MARK: - 多行编辑器：聚焦即全选、可捕获粘贴、⌘+↵ 提交

final class JumpTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChange?(true)
            DispatchQueue.main.async { [weak self] in self?.selectAll(nil) }
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}

struct JumpEditor: NSViewRepresentable {
    @Binding var text: String
    var focusTick: Int
    var onSubmit: () -> Void
    var onPaste: () -> Void
    var onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = JumpTextView()
        tv.delegate = context.coordinator
        tv.onFocusChange = { focused in context.coordinator.parent.onFocusChange(focused) }
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.insertionPointColor = .systemBlue
        tv.textContainerInset = NSSize(width: 3, height: 7)
        tv.textContainer?.lineFragmentPadding = 4
        // 自动换行、关闭各种自动替换（路径里不能被插入智能引号）
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 92)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.autoresizingMask = [.width, .height]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        if context.coordinator.lastFocusTick != focusTick {
            context.coordinator.lastFocusTick = focusTick
            scroll.window?.makeFirstResponder(tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JumpEditor
        var lastFocusTick = 0
        private var pastePending = false
        init(_ parent: JumpEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            if pastePending {
                pastePending = false
                parent.onPaste()
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if NSStringFromSelector(commandSelector) == "paste:" {
                pastePending = true          // 让系统先执行粘贴，再在 textDidChange 里自动复制
            } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()            // 单路径：回车即提交复制，不换行
                return true
            }
            return false
        }
    }
}

// MARK: - 弹窗界面

struct PopoverView: View {
    @ObservedObject var vm: ConverterVM

    private var editorFocused: Bool { vm.editorFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // —— 醒目的输入区 ——
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 11, weight: .semibold))
                    Text("在这里粘贴路径")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("自动识别 Windows / Mac")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if !vm.input.isEmpty {
                        Button("清空") { vm.clear() }
                            .buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
                .foregroundStyle(editorFocused ? Color.accentColor : .secondary)

                ZStack(alignment: .topLeading) {
                    if vm.input.isEmpty {
                        Text(verbatim: #"\\server\share\项目\2026 计划.xlsx 或 smb://…"#)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 11)
                            .allowsHitTesting(false)
                    }
                    JumpEditor(text: $vm.input,
                               focusTick: vm.focusTick,
                               onSubmit: { vm.copyPreferred() },
                               onPaste: { vm.copyPreferred() },
                               onFocusChange: { vm.editorFocused = $0 })
                }
                .frame(height: 68)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(editorFocused ? Color.accentColor : Color(NSColor.separatorColor),
                                      lineWidth: editorFocused ? 2 : 1)
                )
                .shadow(color: editorFocused ? Color.accentColor.opacity(0.18) : .clear,
                        radius: 4, x: 0, y: 0)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(vm.hasResult ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(vm.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if vm.flash.isEmpty {
                    Text("↵ 复制反向结果")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Text(vm.flash)
                        .font(.system(size: 10.5))
                        .foregroundStyle(vm.flash.hasPrefix("✓") ? .green : .secondary)
                        .lineLimit(1)
                }
            }

            // —— 全宽主按钮：检测提示下方 ——
            Button {
                vm.openInFinder()
            } label: {
                Label("在 Finder 中打开", systemImage: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!vm.hasResult)

            Divider()

            ResultCard(symbol: "pc", // 用通用图标，避免老系统 SF Symbol 缺失
                       accent: Color(NSColor.systemGreen),
                       title: "Windows", lines: vm.winLines,
                       placeholder: #"\\server\share\path"#) {
                vm.copy(.win)
            }
            ResultCard(symbol: "laptopcomputer",
                       accent: Color(NSColor.systemBlue),
                       title: "Mac", lines: vm.macLines,
                       placeholder: "smb://server/share/path") {
                vm.copy(.mac)
            }

            Divider()

            HStack {
                Toggle("开机启动", isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { v in vm.launchAtLogin = v; vm.toggleLaunchAtLogin() }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
        .padding(14)
        .frame(width: 440)
        .background(Color(NSColor.popoverBg))
    }
}

struct ResultCard: View {
    let symbol: String
    let accent: Color
    let title: String
    let lines: [String]
    let placeholder: String
    let onCopy: () -> Void

    private var text: String { lines.joined(separator: "\n") }
    private var empty: Bool { lines.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(accent)
                    if lines.count > 1 {
                        Text("\(lines.count) 条")
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(accent.opacity(0.15)))
                            .foregroundStyle(accent)
                    }
                }
                Group {
                    if empty {
                        Text(placeholder)
                    } else {
                        Text(text)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            Button(action: onCopy) {
                Image(systemName: "doc.on.doc").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(empty)
            .help("复制\(title)路径")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accent.opacity(0.08))
        )
        .contentShape(Rectangle())
        .onTapGesture { if !empty { onCopy() } }
    }
}

// MARK: - 状态栏代理

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let popoverWidth: CGFloat = 440

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let vm = ConverterVM()
    private lazy var host = NSHostingController(rootView: PopoverView(vm: vm))
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "folder.network",
                              accessibilityDescription: "共享转换器")
                ?? NSImage(systemSymbolName: "externaldrive",
                           accessibilityDescription: "共享转换器")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(toggle(_:))
        }

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = host
        vm.wantsClose = { [weak self] in self?.closePopover() }
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    /// 按当前内容算出精确尺寸并固定，避免显示时先用默认大尺寸定位、内容收缩后与图标脱节
    private func syncContentSize() {
        let width = Self.popoverWidth
        let fitting = host.sizeThatFits(in: CGSize(width: width, height: .infinity))
        let size = CGSize(width: width, height: ceil(fitting.height))
        host.view.setFrameSize(size)
        popover.contentSize = size
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        vm.willOpen()
        syncContentSize()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let win = popover.contentViewController?.view.window {
            // 关闭毛玻璃，底色不透明，提升可读性
            win.titlebarAppearsTransparent = true
            win.isOpaque = false
            win.backgroundColor = .popoverBg
            popover.contentViewController?.view.wantsLayer = true
            popover.contentViewController?.view.layer?.backgroundColor = NSColor.popoverBg.cgColor
        }
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)

        // 点击弹窗外部任意位置时关闭
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}

// MARK: - 入口

#if SELFTEST
// 无界面自测：swiftc -D SELFTEST 后运行，校验转换规则
let cases: [(String, String)] = [
    ("\\\\fileserver\\团队共享\\项目文件\\2026 计划.xlsx",
     "smb://fileserver/%E5%9B%A2%E9%98%9F%E5%85%B1%E4%BA%AB/%E9%A1%B9%E7%9B%AE%E6%96%87%E4%BB%B6/2026%20%E8%AE%A1%E5%88%92.xlsx"),
    ("smb://fileserver/团队共享/项目文件/2026%20计划.xlsx",
     "smb://fileserver/%E5%9B%A2%E9%98%9F%E5%85%B1%E4%BA%AB/%E9%A1%B9%E7%9B%AE%E6%96%87%E4%BB%B6/2026%20%E8%AE%A1%E5%88%92.xlsx"),
    ("file://server/share/a%20b/测试",
     "smb://server/share/a%20b/%E6%B5%8B%E8%AF%95"),
    ("//server/share/dir/file.txt",
     "smb://server/share/dir/file.txt"),
    ("smb://host/share/100%25_done/2026%25%25",
     "smb://host/share/100%25_done/2026%25%25"),
]
var fail = 0
for (input, expectMac) in cases {
    guard let segs = SMBConvert.parse(input) else { print("PARSE FAIL: \(input)"); fail += 1; continue }
    let mac = SMBConvert.toMac(segs), win = SMBConvert.toWin(segs)
    let ok = mac == expectMac
    if !ok { fail += 1 }
    // 往返一致
    let rt = SMBConvert.parse(win).map { SMBConvert.toMac($0) } == mac
    print("\(ok && rt ? "PASS" : "FAIL")  \(input)\n   → \(win)\n   → \(mac)")
}
print(fail == 0 ? "\n全部通过 ✅" : "\n\(fail) 条失败 ❌")
exit(fail == 0 ? 0 : 1)
#else
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
#endif
