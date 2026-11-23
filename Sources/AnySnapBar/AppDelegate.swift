import AppKit
import ServiceManagement
import AnySnapCore

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ActionItem.run), keyEquivalent: "")
        self.target = self
        self.state = checked ? .on : .off
        self.isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func run() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let hotkeys = HotkeyManager()
    private var statusItem: NSStatusItem!
    private var busy = false
    private var trustTimer: Timer?
    private var brokerTimer: Timer?
    private var pruneTimer: Timer?
    private var servingRequest = false

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("camera.viewfinder")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotkeys.onTrigger = { [weak self] in self?.capture() }
        restartHotkeys()

        // Delete expired snapshots now and every hour.
        SnapshotStore.pruneExpired()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            SnapshotStore.pruneExpired()
        }

        // Capture requests from the CLI / MCP server (they lack our permissions).
        brokerTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.serviceCaptureRequest()
        }

        // Ask for permissions on first launch.
        if !AXReader.isTrusted(prompt: true) {
            // Global key monitors only start working after Accessibility is granted,
            // so poll and re-register once it is.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if AXReader.isTrusted() {
                    t.invalidate()
                    self?.restartHotkeys()
                }
            }
        }
        if !WindowCapture.hasPermission() {
            WindowCapture.requestPermission()
        }
    }

    private func restartHotkeys() {
        hotkeys.start(kind: settings.hotkeyKind, custom: settings.customHotkey)
    }

    // MARK: capture

    func capture() {
        guard !busy else { return }
        busy = true
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var opts = CaptureOptions()
        opts.includeScreenshot = settings.includeScreenshot
        if settings.playSound { Self.playCaptureSound() }
        setIcon("ellipsis.circle")
        let options = opts

        Task {
            do {
                let meta = try await Snapshotter.capture(options)
                await MainActor.run {
                    self.deliver(meta, frontBundle: frontBundle)
                    self.busy = false
                    self.flash("checkmark.circle")
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.flash("exclamationmark.triangle")
                    self.showAlert("截取失败", "\(error)")
                }
            }
        }
    }

    private func serviceCaptureRequest() {
        guard !servingRequest, let req = CaptureBroker.claimNextRequest() else { return }
        servingRequest = true
        var opts = CaptureOptions()
        opts.appName = req.appName
        opts.excludePIDs = Set(req.excludePIDs)
        opts.includeScreenshot = req.includeScreenshot
        let options = opts
        let requestID = req.id
        Task {
            do {
                let meta = try await Snapshotter.capture(options)
                CaptureBroker.respond(to: requestID, snapshotID: meta.id, error: nil)
            } catch {
                CaptureBroker.respond(to: requestID, snapshotID: nil, error: "\(error)")
            }
            await MainActor.run { self.servingRequest = false }
        }
    }

    private func deliver(_ meta: SnapshotMeta, frontBundle: String?) {
        switch settings.destination {
        case .clipboard:
            Delivery.copy(meta, format: settings.clipboardFormat, forApp: frontBundle)
        case .claude:
            // Codex-style: only the screenshot shows up in the chat box; the agent fetches
            // the full window text through the AnySnap MCP server (get_latest_snapshot).
            let fmt: ClipboardFormat = settings.clipboardFormat == .auto ? .image : settings.clipboardFormat
            Delivery.copy(meta, format: fmt, forApp: Delivery.claudeBundleID)
            Delivery.activateAndPaste(bundleID: Delivery.claudeBundleID)
        case .saveOnly:
            break
        }
    }

    static func playCaptureSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: path), let s = NSSound(contentsOfFile: path, byReference: true) {
            s.play()
        } else {
            NSSound(named: "Tink")?.play()
        }
    }

    // MARK: status icon

    private func setIcon(_ symbol: String) {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "AnySnap")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    private func flash(_ symbol: String) {
        setIcon(symbol)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.setIcon("camera.viewfinder")
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(ActionItem("截取前台窗口（\(settings.hotkeyLabel)）") { [weak self] in self?.capture() })
        menu.addItem(.separator())

        // Recent snapshots
        let recent = NSMenuItem(title: "最近快照", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let items = SnapshotStore.list(limit: 10)
        if items.isEmpty {
            recentMenu.addItem(ActionItem("（还没有快照）", enabled: false) {})
        }
        for m in items {
            var title = "\(df.string(from: m.createdAt))  \(m.appName)"
            if let t = m.windowTitle, !t.isEmpty { title += " — \(t.prefix(40))" }
            recentMenu.addItem(ActionItem(title) { [weak self] in
                guard let self else { return }
                Delivery.copy(m, format: self.settings.clipboardFormat == .auto ? .files : self.settings.clipboardFormat, forApp: nil)
            })
        }
        recentMenu.addItem(.separator())
        let keep = NSMenuItem(title: "快照保留时间", action: nil, keyEquivalent: "")
        let keepMenu = NSMenu()
        let current = SnapshotStore.retentionDays
        let choices: [(Int, String)] = [(1, "1 天"), (3, "3 天（默认）"), (7, "7 天"), (30, "30 天"), (0, "永久保留")]
        for (days, title) in choices {
            keepMenu.addItem(ActionItem(title, checked: current == days) {
                SnapshotStore.retentionDays = days
                SnapshotStore.pruneExpired()
            })
        }
        keep.submenu = keepMenu
        recentMenu.addItem(keep)
        recentMenu.addItem(ActionItem("清空所有快照…") { [weak self] in self?.confirmClearSnapshots() })
        recentMenu.addItem(ActionItem("打开快照文件夹") {
            try? FileManager.default.createDirectory(at: SnapshotStore.root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(SnapshotStore.root)
        })
        recent.submenu = recentMenu
        menu.addItem(recent)

        // Destination
        let dest = NSMenuItem(title: "快照目标位置", action: nil, keyEquivalent: "")
        let destMenu = NSMenu()
        let destinations: [(Destination, String)] = [
            (.clipboard, "复制到剪贴板"),
            (.claude, "发送到 Claude 桌面版（自动粘贴）"),
            (.saveOnly, "仅保存（供 MCP / CLI 读取）"),
        ]
        for (d, title) in destinations {
            destMenu.addItem(ActionItem(title, checked: settings.destination == d) { [weak self] in
                self?.settings.destination = d
            })
        }
        dest.submenu = destMenu
        menu.addItem(dest)

        // Clipboard format
        let fmt = NSMenuItem(title: "剪贴板格式", action: nil, keyEquivalent: "")
        let fmtMenu = NSMenu()
        let formats: [(ClipboardFormat, String)] = [
            (.auto, "自动（发给 Claude 时只贴截图；终端用文字引用；其它用文件）"),
            (.files, "截图 + 文字文件"),
            (.reference, "文字引用（路径，适合终端 agent）"),
            (.image, "仅截图"),
        ]
        for (f, title) in formats {
            fmtMenu.addItem(ActionItem(title, checked: settings.clipboardFormat == f) { [weak self] in
                self?.settings.clipboardFormat = f
            })
        }
        fmt.submenu = fmtMenu
        menu.addItem(fmt)

        // Hotkey
        let hk = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
        let hkMenu = NSMenu()
        let kinds: [(HotkeyKind, String)] = [
            (.leftRightCommand, "同时按下左右 ⌘"),
            (.leftRightOption, "同时按下左右 ⌥"),
            (.doubleCommand, "双击 ⌘"),
        ]
        for (k, title) in kinds {
            hkMenu.addItem(ActionItem(title, checked: settings.hotkeyKind == k) { [weak self] in
                self?.settings.hotkeyKind = k
                self?.restartHotkeys()
            })
        }
        if let c = settings.customHotkey {
            hkMenu.addItem(ActionItem("自定义：\(c.label)", checked: settings.hotkeyKind == .custom) { [weak self] in
                self?.settings.hotkeyKind = .custom
                self?.restartHotkeys()
            })
        }
        hkMenu.addItem(.separator())
        hkMenu.addItem(ActionItem("录制自定义快捷键…") { [weak self] in self?.recordHotkey() })
        hk.submenu = hkMenu
        menu.addItem(hk)

        menu.addItem(.separator())
        menu.addItem(ActionItem("包含截图", checked: settings.includeScreenshot) { [weak self] in
            guard let self else { return }
            self.settings.includeScreenshot.toggle()
        })
        menu.addItem(ActionItem("播放音效", checked: settings.playSound) { [weak self] in
            guard let self else { return }
            self.settings.playSound.toggle()
        })
        let loginEnabled = SMAppService.mainApp.status == .enabled
        menu.addItem(ActionItem("登录时启动", checked: loginEnabled) { [weak self] in
            do {
                if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            } catch {
                self?.showAlert("无法修改登录项", error.localizedDescription)
            }
        })

        menu.addItem(.separator())
        menu.addItem(ActionItem("权限状态…") { [weak self] in self?.showPermissions() })
        menu.addItem(ActionItem("复制 MCP 配置（Claude Desktop 等）") { [weak self] in self?.copyMCPConfig() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("退出 AnySnap") { NSApp.terminate(nil) })
    }

    // MARK: custom hotkey recording

    private func recordHotkey() {
        hotkeys.stop()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "录制快捷键"
        alert.informativeText = "请按下新的快捷键组合（需要包含 ⌘、⌃ 或 ⌥ 中的至少一个），例如 ⌃⌥⌘S。"
        alert.addButton(withTitle: "取消")

        var captured: CustomHotkey?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.intersection([.command, .option, .control]).isEmpty else { return e }
            captured = CustomHotkey(keyCode: UInt32(e.keyCode),
                                    modifiers: mods.rawValue,
                                    label: HotkeyManager.label(for: e, modifiers: mods))
            NSApp.stopModal(withCode: .OK)
            return nil
        }
        let response = alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }

        if response == .OK, let c = captured {
            settings.customHotkey = c
            settings.hotkeyKind = .custom
        }
        restartHotkeys()
    }

    private func confirmClearSnapshots() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清空所有快照？"
        alert.informativeText = "会删除已保存的所有截图和窗口文字（共 \(SnapshotStore.list(limit: 10_000).count) 个），无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            SnapshotStore.removeAll()
        }
    }

    // MARK: permissions & config

    private func showPermissions() {
        let ax = AXReader.isTrusted()
        let sr = WindowCapture.hasPermission()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AnySnap 权限状态"
        alert.informativeText = """
        辅助功能 / 无障碍（全局快捷键、读取窗口文字）：\(ax ? "✅ 已授权" : "❌ 未授权")
        屏幕录制（窗口截图）：\(sr ? "✅ 已授权" : "❌ 未授权")

        授权后如果仍显示 ❌，请退出并重新打开 AnySnap。
        重新编译后签名会变化，可能需要在系统设置里先删掉旧的 AnySnap 再重新授权。
        """
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开辅助功能（无障碍）设置")
        alert.addButton(withTitle: "打开屏幕录制设置")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .alertThirdButtonReturn:
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        default:
            break
        }
    }

    private func openSettings(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    private func copyMCPConfig() {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/anysnap").path
        let json = """
        {
          "mcpServers": {
            "anysnap": {
              "command": "\(cli)",
              "args": ["mcp"]
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        showAlert("已复制 MCP 配置",
                  "粘贴到 ~/Library/Application Support/Claude/claude_desktop_config.json 的 mcpServers 里，然后重启 Claude Desktop。\n\nClaude Code：claude mcp add anysnap -- \"\(cli)\" mcp")
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
