import Cocoa

// MARK: - batt 调用

func locateBatt() -> String? {
    let candidates = [
        NSHomeDirectory() + "/.local/bin/batt",
        "/usr/local/bin/batt",
        NSHomeDirectory() + "/Desktop/batt安装/batt"
    ]
    for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
        return p
    }
    return nil
}

// MARK: - 自检与自愈

let stableBattPath = NSHomeDirectory() + "/.local/bin/batt"

/// 把 app 内置的 batt 铺到用户目录，保证 app 可移动、不依赖外部文件
func ensureBattBinary() {
    if FileManager.default.isExecutableFile(atPath: stableBattPath) { return }
    guard let bundled = Bundle.main.path(forResource: "batt", ofType: nil) else { return }
    let dir = (stableBattPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: stableBattPath)
    try? FileManager.default.copyItem(atPath: bundled, toPath: stableBattPath)
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: stableBattPath
    )
}

func daemonRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", "system/cc.chlc.batt"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// 弹系统授权框安装后台服务（app 运行在用户会话，可以正常弹框）
func installDaemonAsync(completion: @escaping (Bool) -> Void) {
    guard let bin = locateBatt() else { completion(false); return }
    DispatchQueue.global(qos: .userInitiated).async {
        let script = "do shell script \"'\(bin)' install --allow-non-root-access && sleep 1 && '\(bin)' limit 80\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var ok = false
        if (try? p.run()) != nil {
            p.waitUntilExit()
            ok = p.terminationStatus == 0
        }
        DispatchQueue.main.async { completion(ok) }
    }
}

@discardableResult
func runBatt(_ args: [String]) -> String {
    guard let bin = locateBatt() else { return "" }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: bin)
    proc.arguments = args
    let out = Pipe()
    proc.standardOutput = out
    // stderr 必须丢弃：不读的管道写满 64KB 会永久阻塞子进程
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - 模型

struct Snapshot {
    var ok = false
    var percent = 0
    var state = "unknown"
    var pluggedIn = false
    var rate: Double = 0
    var upper = 80
    var lower = 78
    var enabled = true
    var mode = ""
    var noDrain = false
    var capacity = 0
}

func readSnapshot() -> Snapshot {
    var s = Snapshot()
    let txt = runBatt(["status", "--json"])
    guard !txt.isEmpty,
          let data = txt.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return s }

    s.ok = true
    if let c = root["charging"] as? [String: Any] {
        s.pluggedIn = c["pluggedIn"] as? Bool ?? false
    }
    if let b = root["battery"] as? [String: Any] {
        s.percent = b["currentChargePercent"] as? Int ?? 0
        s.state = b["state"] as? String ?? "unknown"
        s.rate = b["chargeRateWatts"] as? Double ?? 0
        s.capacity = b["fullCapacityMah"] as? Int ?? 0
    }
    if let cfg = root["configuration"] as? [String: Any] {
        s.upper = cfg["upperLimitPercent"] as? Int ?? 80
        s.lower = cfg["lowerLimitPercent"] as? Int ?? 78
        s.enabled = cfg["enabled"] as? Bool ?? true
        if let nd = cfg["noDrain"] as? [String: Any] {
            s.noDrain = nd["enabled"] as? Bool ?? false
        }
    }
    if let comp = root["compatibility"] as? [String: Any] {
        s.mode = comp["chargeControlMode"] as? String ?? ""
    }
    return s
}

func stateLabel(_ s: Snapshot) -> String {
    let nearLimit = s.enabled && s.percent >= s.upper - 1
    switch s.state {
    case "charging":
        return nearLimit ? "补电中（到 \(s.upper)% 即停）" : "充电中"
    case "discharging":
        return s.pluggedIn ? "放电中" : "电池供电"
    case "full":
        return "已充满"
    case "notCharging", "not-charging":
        return s.pluggedIn ? "维持中（不充不放）" : "未充电"
    default:
        return s.state
    }
}

func modeLabel(_ m: String) -> String {
    switch m {
    case "firmware": return "固件级"
    case "native":   return "系统原生"
    case "legacy":   return "传统 SMC"
    case "adapter":  return "适配器切换"
    default:         return m.isEmpty ? "未知" : m
    }
}

// MARK: - 电池图标（iOS 风格：数字内嵌 + 双色反白）

func batteryImage(percent: Int, dark: Bool) -> NSImage {
    let w: CGFloat = 13
    let h: CGFloat = 21
    let fg: NSColor = dark ? .white : .black

    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        fg.setFill()
        fg.setStroke()

        // 顶部正极凸点
        let nub = NSRect(x: w / 2 - 2.3, y: h - 2.9, width: 4.6, height: 2.7)
        NSBezierPath(roundedRect: nub, xRadius: 0.9, yRadius: 0.9).fill()

        // 电池外壳
        let body = NSRect(x: 0.9, y: 0.6, width: w - 1.8, height: h - 4.3)
        let shell = NSBezierPath(roundedRect: body, xRadius: 2.6, yRadius: 2.6)
        shell.lineWidth = 1.4
        shell.stroke()

        // 电量填充（自底向上）
        let inset: CGFloat = 2.5
        let pct = max(0, min(100, percent))
        let fillH = (body.height - inset * 2) * CGFloat(pct) / 100
        if fillH > 0.3 {
            let fill = NSRect(x: body.minX + inset, y: body.minY + inset,
                              width: body.width - inset * 2, height: fillH)
            NSBezierPath(roundedRect: fill, xRadius: 1.2, yRadius: 1.2).fill()
        }
        return true
    }
    img.isTemplate = false
    return img
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?
    var sliderLabel: NSTextField?
    var slider: NSSlider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setup()
    }

    private var didSetup = false
    var latest = Snapshot()
    var refreshing = false

    func setup() {
        guard !didSetup else { return }
        didSetup = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu

        // 自愈：铺开内置的 batt，服务不在就弹授权框装
        ensureBattBinary()

        // 先用占位图点亮图标，真实数据异步补上（同步调用会阻塞主线程）
        statusItem.button?.image = batteryImage(percent: 0, dark: isDarkMode())

        if daemonRunning() {
            refreshIcon()
        } else {
            installDaemonAsync { [weak self] ok in
                self?.refreshIcon()
                if !ok {
                    self?.statusItem.button?.title = " 需授权"
                }
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
        RunLoop.main.add(timer!, forMode: .common)

        // 系统深浅色切换时立即重绘图标
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyIcon(self.latest)
        }
    }

    func isDarkMode() -> Bool {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 后台刷新，绝不阻塞主线程（batt 调用实测可达数秒）
    func refreshIcon() {
        if refreshing { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = readSnapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.latest = s
                self.refreshing = false
                self.applyIcon(s)
            }
        }
    }

    func applyIcon(_ s: Snapshot) {
        guard let button = statusItem.button else { return }
        if !s.ok {
            let img = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: "batt 未运行")
            img?.isTemplate = true
            button.image = img
            button.title = ""
            return
        }
        button.title = ""
        let img = batteryImage(percent: s.percent, dark: isDarkMode())
        button.image = img
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = latest
        refreshIcon()   // 后台更新，下次打开生效

        guard s.ok else {
            let bad = NSMenuItem(title: "batt 未运行或未安装", action: nil, keyEquivalent: "")
            bad.isEnabled = false
            menu.addItem(bad)
            menu.addItem(.separator())
            addStatic(menu, "打开管理脚本…", #selector(openManager))
            addStatic(menu, "退出", #selector(quit))
            return
        }

        // 状态行
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.isEnabled = false
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: "\(s.percent)%   ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]))
        line.append(NSAttributedString(string: stateLabel(s), attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        head.attributedTitle = line
        menu.addItem(head)

        let sub = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sub.isEnabled = false
        sub.attributedTitle = NSAttributedString(
            string: "\(String(format: "%.1f", s.rate))W · \(s.capacity) mAh · \(modeLabel(s.mode))",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.tertiaryLabelColor]
        )
        menu.addItem(sub)

        menu.addItem(.separator())

        // 滑块
        addSlider(menu, current: s.upper, enabled: s.enabled)
        menu.addItem(.separator())

        addStatic(menu, "保持当前电量（\(s.percent)%）", #selector(holdCurrent))
        let off = NSMenuItem(title: "关闭充电限制", action: #selector(disableLimit), keyEquivalent: "")
        off.target = self
        off.state = s.enabled ? .off : .on
        menu.addItem(off)

        if s.enabled && s.pluggedIn && s.state == "discharging" && s.percent > s.upper {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            warn.attributedTitle = NSAttributedString(
                string: "电量高于上限，固件正在放电到 \(s.upper)%",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.systemOrange]
            )
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        addStatic(menu, "重装后台服务…", #selector(repairService))
        addStatic(menu, "彻底卸载…", #selector(uninstallApp))
        addStatic(menu, "打开管理脚本…", #selector(openManager))
        addStatic(menu, "退出", #selector(quit))
    }

    func addSlider(_ menu: NSMenu, current: Int, enabled: Bool) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 54))

        let label = NSTextField(labelWithString: "充电上限   \(current)%")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = enabled ? .labelColor : .tertiaryLabelColor
        label.frame = NSRect(x: 16, y: 31, width: 220, height: 17)
        container.addSubview(label)

        let sl = NSSlider(value: Double(current), minValue: 50, maxValue: 100,
                          target: self, action: #selector(sliderMoved(_:)))
        sl.frame = NSRect(x: 14, y: 6, width: 224, height: 22)
        sl.isContinuous = false
        container.addSubview(sl)

        sliderLabel = label
        slider = sl

        let item = NSMenuItem()
        item.view = container
        menu.addItem(item)
    }

    func addStatic(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
    }

    // MARK: 动作

    @objc func sliderMoved(_ sender: NSSlider) {
        let v = Int(sender.doubleValue.rounded())
        sliderLabel?.stringValue = "充电上限   \(v)%"
        runBatt(["limit", String(v)])
        refreshIcon()
    }

    @objc func holdCurrent() {
        let s = latest
        guard s.percent > 0 else { return }
        runBatt(["limit", String(s.percent)])
        refreshIcon()
    }

    @objc func disableLimit() {
        runBatt(["disable"])
        refreshIcon()
    }

    @objc func repairService() {
        installDaemonAsync { [weak self] _ in
            self?.refreshIcon()
        }
    }

    @objc func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "彻底卸载电池管家？"
        alert.informativeText = """
        将执行以下操作：
        • 停止并移除后台服务
        • 删除 batt 程序与所有配置
        • 充电限制恢复为 macOS 默认（充满到 100%）
        • 删除 app 自身

        此操作不可撤销。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let home = NSHomeDirectory()
        let appPath = Bundle.main.bundlePath
        let bin = locateBatt() ?? (home + "/.local/bin/batt")

        // 脚本以 base64 传递，避免引号转义问题
        let cmd = """
        '\(bin)' uninstall >/dev/null 2>&1 || true
        launchctl bootout system/cc.chlc.batt >/dev/null 2>&1 || true
        rm -f /Library/LaunchDaemons/cc.chlc.batt.plist
        rm -f /etc/batt.json
        rm -f '\(home)/.local/bin/batt'
        rm -f '\(home)/Library/LaunchAgents/com.ping.batterybuddy.plist'
        rm -rf '\(appPath)'
        echo cleaned
        """
        let b64 = Data(cmd.utf8).base64EncodedString()
        let script = "do shell script \"echo \(b64) | base64 -d | /bin/sh\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            if (try? p.run()) != nil {
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            }
            DispatchQueue.main.async {
                if ok {
                    NSApp.terminate(nil)
                } else {
                    let err = NSAlert()
                    err.messageText = "卸载未完成"
                    err.informativeText = "授权被取消或执行失败。可以改用安装包里的「卸载.command」。"
                    err.runModal()
                }
            }
        }
    }

    @objc func openManager() {
        let path = NSHomeDirectory() + "/Desktop/batt安装/batt管理.command"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Utilities/Terminal.app"))
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
delegate.setup()
app.run()
