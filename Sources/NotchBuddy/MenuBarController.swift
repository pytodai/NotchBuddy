import AppKit
import NotchBuddyCore

/// Status-bar item and its menu. The menu is rebuilt every time it opens, so it always
/// reflects the model; hook statuses are read in the background and patched in when ready.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let hooks: HookInstallService
    private let socket: SocketService?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    /// The "Хуки" submenu of the currently built menu (recreated with it).
    private weak var hooksMenu: NSMenu?

    private var hookReports: [AgentSource: HookReport] = [:]
    private var busyAgents: Set<AgentSource> = []
    private var refreshTask: Task<Void, Never>?
    /// A refresh was requested while one was running (e.g. right after an install).
    private var refreshAgain = false
    /// Opens the island's ⚙️ page (set by the app delegate).
    var openSettings: () -> Void = {}
    /// Self-updates: «Проверить обновления…» in the menu (set by the app delegate).
    var updates: AppUpdates?

    init(model: AppModel, hooks: HookInstallService, socket: SocketService?) {
        self.model = model
        self.hooks = hooks
        self.socket = socket
        super.init()

        if let button = statusItem.button {
            button.image = Self.statusImage(badge: false)
            button.toolTip = "NotchBuddy"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshHookStatuses()
    }

    /// A small dot on the icon while an update waits for the user.
    func setUpdateBadge(_ on: Bool) {
        guard let button = statusItem.button else { return }
        button.image = Self.statusImage(badge: on)
        button.toolTip = on ? L("NotchBuddy · есть обновление") : "NotchBuddy"
    }

    /// The menu bar icon: the template glyph, with a dot at its top right corner when `badge` is set (still a template
    /// image, so it follows the menu bar's appearance like the system's own badges).
    static func statusImage(badge: Bool) -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "NotchBuddy") else { return nil }
        glyph.isTemplate = true
        guard badge else { return glyph }
        let dot: CGFloat = 5
        let size = NSSize(width: glyph.size.width + 2, height: glyph.size.height + 1)
        let image = NSImage(size: size, flipped: false) { _ in
            let cutout = NSRect(x: size.width - dot - 1.5, y: size.height - dot - 1.5, width: dot + 3, height: dot + 3)
            glyph.draw(in: NSRect(x: 0, y: 0, width: glyph.size.width, height: glyph.size.height))
            // Clear a ring around the dot so it reads as separate from the glyph.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: cutout).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: cutout.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L("NotchBuddy · есть обновление")
        return image
    }

    /// Pops the menu open (used when the user launches the app again while it's running).
    func showMenu() {
        statusItem.button?.performClick(nil)
    }

    /// Re-reads hook statuses off the main thread and patches the open menu.
    func refreshHookStatuses() {
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshAgain = false
                let fresh = await hooks.reports(AgentSource.allCases)
                for (source, report) in fresh where !busyAgents.contains(source) {
                    hookReports[source] = report
                }
            } while refreshAgain
            refreshTask = nil
            populateHooksMenu()
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildMenu()
        refreshHookStatuses()
        // For the next look at the menu (this one is already built).
        model.refreshUsageForDisplay()
    }

    // MARK: Building

    private func rebuildMenu() {
        menu.removeAllItems()
        addSessionItems()
        menu.addItem(.separator())
        addUsageItems()
        menu.addItem(.separator())

        if socket?.isRunning == false {
            let item = infoItem(L("События от агентов не принимаются — см. логи"))
            item.image = symbol("exclamationmark.triangle.fill", color: .systemOrange)
            item.toolTip = socket?.failure
            menu.addItem(item)
        }

        let hooksItem = NSMenuItem(title: L("Хуки"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        hooksItem.submenu = submenu
        hooksMenu = submenu
        menu.addItem(hooksItem)
        populateHooksMenu()
        if hookReports[.kimi]?.status != .agentMissing {
            menu.addItem(hintItem(L("Kimi: только уведомления, разрешать нужно в самом Kimi")))
        }

        menu.addItem(actionItem(L("Настройки…"), #selector(showSettings), key: ","))
        if let updates { menu.addItem(updates.menuItem()) }
        menu.addItem(widgetsItem())
        menu.addItem(styleItem())
        let hotkey = SettingsStore.shared.values
        if hotkey.hotkeyEnabled {
            menu.addItem(hintItem(L("Открыть остров: %@", hotkey.hotkey.display)))
        }
        menu.addItem(launchAtLoginItem())
        let sounds = actionItem(L("Звуки уведомлений"), #selector(toggleSounds))
        sounds.state = IslandSounds.isEnabled ? .on : .off
        sounds.toolTip = L("Звук, когда агент закончил или ждёт тебя")
        menu.addItem(sounds)
        menu.addItem(actionItem(L("Открыть логи"), #selector(openLogs)))
        menu.addItem(.separator())
        menu.addItem(actionItem(L("Выйти"), #selector(quit), key: "q"))
    }

    private func addSessionItems() {
        let sessions = model.sessions
        guard !sessions.isEmpty else {
            menu.addItem(infoItem(L("Нет активных сессий")))
            return
        }
        menu.addItem(NSMenuItem.sectionHeader(title: L("Сессии")))
        for session in sessions {
            let item = actionItem("", #selector(jumpToSession(_:)))
            item.attributedTitle = sessionTitle(session)
            item.image = symbol("circle.fill", color: Self.color(for: session.status), pointSize: 9)
            item.representedObject = session.key
            item.toolTip = [session.cwd, session.lastToolSummary ?? session.lastMessage]
                .compactMap { $0 }.joined(separator: "\n")
            menu.addItem(item)
        }
    }

    private func sessionTitle(_ session: AgentSession) -> NSAttributedString {
        let title = NSMutableAttributedString(string: session.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        let detail = "  \(session.source.displayName) · \(Self.statusText(session.status))"
        title.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
    }

    private func addUsageItems() {
        menu.addItem(NSMenuItem.sectionHeader(title: L("Лимиты Claude")))
        switch model.usage {
        case .unavailable(let reason):
            menu.addItem(infoItem(L(reason)))
        case .loaded(let snapshot):
            let lines = [(L("5ч"), snapshot.fiveHour), (L("7д"), snapshot.sevenDay)].compactMap { label, window in
                window.map { Self.usageLine(label: label, window: $0) }
            }
            if lines.isEmpty { menu.addItem(infoItem(L("нет данных"))) }
            lines.forEach { menu.addItem(infoItem($0)) }
        }
        let api = actionItem(L("Лимиты Claude через API"), #selector(toggleUsageNetwork))
        api.state = UsageFetcher.isNetworkEnabled() ? .on : .off
        api.toolTip = L("Читает вход Claude Code из связки ключей и раз в 5 минут запрашивает лимиты у api.anthropic.com. Выключено — только данные из statusLine, без сети и без связки ключей.")
        menu.addItem(api)
    }

    private func populateHooksMenu() {
        guard let submenu = hooksMenu else { return }
        submenu.removeAllItems()
        for source in AgentSource.allCases {
            let report = hookReports[source]
            let label = busyAgents.contains(source) ? L("выполняется…")
                : report.map { HookInstallService.statusText($0.status) } ?? L("проверяю…")
            let item = NSMenuItem(title: "\(source.displayName) — \(label)", action: nil, keyEquivalent: "")
            if let report { item.image = symbol("circle.fill", color: Self.color(for: report.status), pointSize: 9) }
            item.submenu = agentHooksMenu(source, report: report)
            submenu.addItem(item)
        }
    }

    private func agentHooksMenu(_ source: AgentSource, report: HookReport?) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        func add(_ title: String, _ action: Selector) {
            let item = actionItem(title, action)
            item.representedObject = source
            if source == .codex, action == #selector(installHooks(_:)) {
                item.toolTip = HookInstallService.codexTrustNotice
            }
            m.addItem(item)
        }

        if busyAgents.contains(source) {
            m.addItem(infoItem(L("Выполняется…")))
            return m
        }
        switch report?.status {
        case nil:
            m.addItem(infoItem(L("Проверяю…")))
        case .agentMissing?:
            m.addItem(infoItem(L("%@ не найден на этом Mac", source.displayName)))
        case .notInstalled?:
            add(L("Установить"), #selector(installHooks(_:)))
        case .installed?:
            add(L("Переустановить"), #selector(installHooks(_:)))
            add(L("Удалить"), #selector(uninstallHooks(_:)))
        case .partial(let detail)?:
            m.addItem(infoItem(detail))
            if source == .codex { add(L("Почему так?"), #selector(explainCodexTrust(_:))) }
            add(L("Переустановить"), #selector(installHooks(_:)))
            add(L("Удалить"), #selector(uninstallHooks(_:)))
        case .error(let message)?:
            let item = infoItem(L("Ошибка: %@", message))
            item.toolTip = message
            m.addItem(item)
            add(L("Попробовать установить"), #selector(installHooks(_:)))
        }

        if let existing = report?.existingFiles, !existing.isEmpty {
            m.addItem(.separator())
            let item = actionItem(L("Показать файл настроек"), #selector(revealConfig(_:)))
            item.representedObject = existing
            m.addItem(item)
        }
        return m
    }

    private func launchAtLoginItem() -> NSMenuItem {
        let item = actionItem(L("Запускать при входе"), #selector(toggleLaunchAtLogin))
        switch LaunchAtLogin.state {
        case .enabled: item.state = .on
        case .disabled: item.state = .off
        case .requiresApproval:
            item.state = .mixed
            item.toolTip = L("Нужно разрешение в Системных настройках → Основные → Объекты входа")
        case .unavailable:
            item.isEnabled = false
            item.toolTip = L("Доступно только при запуске из NotchBuddy.app")
        }
        return item
    }

    // MARK: Actions

    @objc private func jumpToSession(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? SessionKey else { return }
        model.jump(to: key)
    }

    @objc private func installHooks(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? AgentSource else { return }
        runHookOperation(source, install: true)
    }

    @objc private func uninstallHooks(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? AgentSource else { return }
        runHookOperation(source, install: false)
    }

    @objc private func explainCodexTrust(_ sender: NSMenuItem) {
        Alerts.show(title: L("Хуки Codex без доверия"), message: HookInstallService.codexTrustExplanation, style: .informational)
    }

    @objc private func revealConfig(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch LaunchAtLogin.state {
            case .enabled:
                try LaunchAtLogin.setEnabled(false)
            case .disabled:
                try LaunchAtLogin.setEnabled(true)
                if LaunchAtLogin.state == .requiresApproval { askForLoginItemApproval() }
            case .requiresApproval:
                askForLoginItemApproval()
            case .unavailable:
                throw LaunchAtLogin.Failure.notBundled
            }
        } catch {
            Log.error("launch at login toggle failed: \(error)")
            Alerts.show(title: L("Не удалось изменить автозапуск"), message: "\(error)", style: .warning)
        }
    }

    /// «Островки»: the same switches as Settings → Островки (one store; the island follows either at once).
    private func widgetsItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("Островки"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for entry in SettingsStore.shared.values.widgets {
            let widget = NSMenuItem(title: entry.kind.title, action: #selector(toggleWidget(_:)), keyEquivalent: "")
            widget.target = self
            widget.representedObject = entry.kind.rawValue
            widget.state = entry.enabled ? .on : .off
            widget.isEnabled = !entry.kind.isRequired
            widget.toolTip = entry.kind.isRequired ? L("Всегда на острове") : entry.kind.subtitle
            widget.image = symbol(entry.kind.symbol, color: .secondaryLabelColor, pointSize: 12)
            submenu.addItem(widget)
        }
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: L("Порядок и настройки…"), action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        submenu.addItem(settings)
        item.submenu = submenu
        return item
    }

    /// «Стиль острова»: «Чёлка» / «Островок» for monitors and, with such a screen, for the one with a camera notch
    /// (the same settings as Settings → Остров → Стиль).
    private func styleItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("Стиль острова"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let values = SettingsStore.shared.values
        let notched = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        for hasNotch in notched ? [false, true] : [false] {
            if notched { submenu.addItem(.sectionHeader(title: hasNotch ? L("Экран с вырезом") : L("Монитор"))) }
            for style in IslandStyle.allCases {
                let row = NSMenuItem(title: style.label, action: #selector(chooseStyle(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = [hasNotch ? "notched" : "monitors", style.rawValue]
                row.state = values.islandStyle(hasNotch: hasNotch) == style ? .on : .off
                row.image = symbol(style == .notch ? "rectangle.topthird.inset.filled" : "capsule.fill",
                                   color: .secondaryLabelColor, pointSize: 12)
                submenu.addItem(row)
            }
        }
        item.submenu = submenu
        return item
    }

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 2,
              let style = IslandStyle(rawValue: parts[1]) else { return }
        SettingsStore.shared.values.setIslandStyle(style, hasNotch: parts[0] == "notched")
    }

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = WidgetKind(rawValue: raw), !kind.isRequired,
              let index = SettingsStore.shared.values.widgets.firstIndex(where: { $0.kind == kind }) else { return }
        SettingsStore.shared.values.widgets[index].enabled.toggle()
    }

    @objc private func toggleSounds() {
        IslandSounds.isEnabled.toggle()
    }

    @objc private func toggleUsageNetwork() {
        UsageFetcher.setNetworkEnabled(!UsageFetcher.isNetworkEnabled())
        let model = model
        let provider = model.usageProvider
        Task {
            await provider.nudge()
            await model.refreshUsage()
        }
    }

    @objc private func openLogs() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Log.fileURL.path) {
            NSWorkspace.shared.open(Log.fileURL)
        } else {
            try? fm.createDirectory(at: Log.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Log.directory)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func askForLoginItemApproval() {
        Alerts.show(
            title: L("Нужно разрешение"),
            message: L("Разреши NotchBuddy в Системных настройках → Основные → Объекты входа."),
            style: .informational
        ) {
            LaunchAtLogin.openSystemSettings()
        }
    }

    private func runHookOperation(_ source: AgentSource, install: Bool) {
        guard !busyAgents.contains(source) else { return }
        busyAgents.insert(source)
        populateHooksMenu()
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = install ? try await hooks.install(source) : try await hooks.uninstall(source)
                hookReports[source] = report
                busyAgents.remove(source)
                populateHooksMenu()
                if install, let note = HookInstallService.followUpNote(for: source, status: report.status) {
                    Alerts.show(title: L("Хуки %@", source.displayName), message: note, style: .informational)
                }
            } catch {
                hookReports[source] = await hooks.report(for: source)
                busyAgents.remove(source)
                populateHooksMenu()
                let verb = install ? L("установить") : L("удалить")
                Alerts.show(
                    title: L("Не удалось %@ хуки %@", verb, source.displayName),
                    message: HookInstallService.describe(error),
                    style: .warning)
            }
            // A refresh that read this agent before the operation must not win with stale data.
            refreshHookStatuses()
        }
    }

    // MARK: Helpers

    @objc private func showSettings() { openSettings() }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A small secondary-text note under the item it explains.
    private func hintItem(_ title: String) -> NSMenuItem {
        let item = infoItem(title)
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.indentationLevel = 1
        return item
    }

    private func symbol(_ name: String, color: NSColor, pointSize: CGFloat = 13) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    nonisolated static func statusText(_ status: SessionStatus) -> String {
        switch status {
        case .working: return L("работает")
        case .waitingForUser: return L("ждёт тебя")
        case .finished: return L("готово")
        case .error: return L("ошибка")
        case .idle: return L("простаивает")
        }
    }

    static func color(for status: SessionStatus) -> NSColor {
        switch status {
        case .working: return .systemBlue
        case .waitingForUser: return .systemOrange
        case .finished: return .systemGreen
        case .error: return .systemRed
        case .idle: return .systemGray
        }
    }

    static func color(for status: HookInstallStatus) -> NSColor {
        switch status {
        case .installed: return .systemGreen
        case .partial: return .systemOrange
        case .error: return .systemRed
        case .notInstalled, .agentMissing: return .systemGray
        }
    }

    nonisolated static func usageLine(label: String, window: UsageWindow, now: Date = Date()) -> String {
        let percent = IslandFormat.percentValue(window.utilization)
        guard let resets = window.resetsAt, resets > now else { return "\(label): \(percent)%" }
        let f = DateFormatter()
        f.locale = L10n.shared.locale
        if Calendar.current.isDate(resets, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
            return L("%@: %@%% · сброс в %@", label, percent, f.string(from: resets))
        }
        f.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        return L("%@: %@%% · сброс %@", label, percent, f.string(from: resets))
    }
}

// MARK: - Alerts

/// Alerts for an accessory (Dock-less) app, never app-modal: `runModal` would stall main-queue work
/// (socket events, island updates) and drop clicks on the island until the alert is dismissed.
/// Each alert's own panel is shown as an ordinary floating window; its buttons report back through
/// a completion handler. macOS 14 activation is cooperative and may leave another app in front,
/// hence the floating level.
@MainActor
enum Alerts {
    /// Alerts on screen; each is kept alive until one of its buttons is pressed.
    private static var visible: [AlertPresenter] = []

    static func show(
        title: String, message: String, style: NSAlert.Style = .warning,
        then completion: (() -> Void)? = nil
    ) {
        // Repeated clicks on the same menu item bring the open notice forward instead of stacking copies.
        if let open = visible.first(where: { $0.isNotice && $0.shows(title: title, message: message) }) {
            open.bringToFront()
            return
        }
        let alert = makeAlert(title: title, message: message, style: style)
        alert.addButton(withTitle: "OK")
        present(alert, isNotice: true) { _ in completion?() }
    }

    /// Resolves when the user presses a button; the main thread stays free meanwhile.
    static func confirm(title: String, message: String, confirmTitle: String, cancelTitle: String) async -> Bool {
        let alert = makeAlert(title: title, message: message, style: .informational)
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle).keyEquivalent = "\u{1b}"   // Esc
        return await withCheckedContinuation { continuation in
            present(alert, isNotice: false) { index in continuation.resume(returning: index == 0) }
        }
    }

    private static func makeAlert(title: String, message: String, style: NSAlert.Style) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        return alert
    }

    private static func present(_ alert: NSAlert, isNotice: Bool, completion: @escaping (Int) -> Void) {
        let presenter = AlertPresenter(alert: alert, isNotice: isNotice) { presenter, index in
            visible.removeAll { $0 === presenter }
            completion(index)
        }
        visible.append(presenter)
        presenter.show()
    }
}

/// Shows an NSAlert's panel without a modal session; its buttons are re-targeted to this object.
@MainActor
private final class AlertPresenter: NSObject {
    let isNotice: Bool
    private let alert: NSAlert
    private var completion: ((AlertPresenter, Int) -> Void)?

    init(alert: NSAlert, isNotice: Bool, completion: @escaping (AlertPresenter, Int) -> Void) {
        self.alert = alert
        self.isNotice = isNotice
        self.completion = completion
    }

    func shows(title: String, message: String) -> Bool {
        alert.messageText == title && alert.informativeText == message
    }

    func show() {
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(buttonPressed(_:))
        }
        alert.layout()
        let window = alert.window
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        bringToFront()
    }

    func bringToFront() {
        NSApp.activate()
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let completion else { return }
        self.completion = nil
        alert.window.orderOut(nil)
        completion(self, sender.tag)
    }
}
