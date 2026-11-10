import Cocoa

// MARK: - batt 调用

func locateBatt() -> String? {
    let candidates = [
        "/usr/local/bin/batt",
        NSHomeDirectory() + "/Desktop/batt安装/batt"
    ]
    for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
        return p
    }
    return nil
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
    let w: CGFloat = 42
    let h: CGFloat = 16
    let fg: NSColor = dark ? .white : .black
    let bg: NSColor = dark
        ? NSColor(calibratedWhite: 0.13, alpha: 1)
        : NSColor(calibratedWhite: 0.97, alpha: 1)

    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let bodyW: CGFloat = w - 3.5
        let bodyRect = NSRect(x: 0.8, y: 1.9, width: bodyW - 1.6, height: h - 3.8)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 3.6, yRadius: 3.6)
        body.lineWidth = 1.25
        fg.setStroke()
        body.stroke()

        // 正极凸点
        let nub = NSRect(x: bodyW - 0.4, y: h / 2 - 2.2, width: 2.2, height: 4.4)
        fg.setFill()
        NSBezierPath(roundedRect: nub, xRadius: 1.1, yRadius: 1.1).fill()

        // 电量填充
        let inset: CGFloat = 2.7
        let innerW = bodyW - inset * 2 - 0.8
        let pct = max(0, min(100, percent))
        let fillW = max(0.001, innerW * CGFloat(pct) / 100)
        let fillRect = NSRect(x: inset, y: inset, width: fillW, height: h - inset * 2)

        fg.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()

        // 数字：填充区内画背景色，区外画前景色 —— 自动反白，任何电量都可读
        let font = NSFont.monospacedDigitSystemFont(ofSize: pct >= 100 ? 8.5 : 9.5, weight: .bold)
        let text = "\(pct)"
        let ts = (text as NSString).size(withAttributes: [.font: font])
        let origin = NSPoint(x: (bodyW - ts.width) / 2, y: (h - ts.height) / 2 + 0.6)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: fillRect).addClip()
        (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: bg])
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        let outer = NSBezierPath(rect: NSRect(x: 0, y: 0, width: bodyW, height: h))
        outer.append(NSBezierPath(rect: fillRect))
        outer.windingRule = .evenOdd
        outer.addClip()
        (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: fg])
        NSGraphicsContext.restoreGraphicsState()

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

        // 先用占位图点亮图标，真实数据异步补上（同步调用会阻塞主线程）
        statusItem.button?.image = batteryImage(percent: 0, dark: isDarkMode())
        refreshIcon()

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
