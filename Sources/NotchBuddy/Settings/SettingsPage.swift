import AppKit
import SwiftUI
import NotchBuddyCore

/// The settings page, drawn inside the expanded island (black, the list's width): a header in the island's top
/// strip and one card per section in a scroll view. A card opens in place (one at a time) on the island's own
/// morph spring and its rows drop in one after another; everything applies live.
///
/// Usage: show it instead of the session list while settings are open (`SettingsEntryButton` in the list
/// header opens it, the same button in this header, now a ×, closes it). The page sizes itself: the header plus
/// its cards, up to `maxHeight`, then it scrolls.
struct SettingsPage: View {
    @ObservedObject var model: SettingsPageModel
    let metrics: IslandMetrics
    let width: CGFloat
    let maxHeight: CGFloat
    let onClose: () -> Void
    /// The island's pin (📌 beside the ×: the page closes with the island once the pointer leaves, unless pinned).
    var pinned = false
    var pinBounce = 0
    var onTogglePin: (() -> Void)?
    /// Static renders only (`--render-settings`): the scroll offset and the viewport height to draw.
    var staticScroll: CGFloat = 0
    var staticViewport: CGFloat?

    @ObservedObject private var store: SettingsStore
    @ObservedObject private var hooks: HookSettingsModel
    @ObservedObject private var maintenance: SettingsMaintenance
    @ObservedObject private var hotkey: GlobalHotkey

    @Environment(\.islandStaticRender) private var staticRender
    @State private var contentHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var headerSpin = 0

    static let sidePadding: CGFloat = 10
    static let textInset: CGFloat = 22
    /// Until the cards have been measured.
    static let estimatedContentHeight: CGFloat = 548

    init(model: SettingsPageModel, metrics: IslandMetrics, width: CGFloat? = nil, maxHeight: CGFloat? = nil,
         staticScroll: CGFloat = 0, staticViewport: CGFloat? = nil, pinned: Bool = false, pinBounce: Int = 0,
         onTogglePin: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.pinned = pinned
        self.pinBounce = pinBounce
        self.onTogglePin = onTogglePin
        self.metrics = metrics
        self.width = width ?? IslandLayout.listWidth(metrics)
        self.maxHeight = maxHeight ?? IslandLayout.maxOpenHeight
        self.onClose = onClose
        self.staticScroll = staticScroll
        self.staticViewport = staticViewport
        store = model.store
        hooks = model.hooks
        maintenance = model.maintenance
        hotkey = model.hotkey
    }

    var headerHeight: CGFloat { metrics.style == .notch ? metrics.barHeight : 48 }
    /// The header with its top inset.
    var headerBlock: CGFloat { headerHeight + (metrics.style == .notch ? 0 : 2) }
    var maxViewport: CGFloat { maxHeight - headerBlock }

    var body: some View {
        let reduce = model.reduceMotion
        VStack(spacing: 0) {
            header
                .appearAfter(0.02, style: .header)
            scroller
        }
        .frame(width: width)
        .environment(\.settingsAccent, store.values.accent)
        .environment(\.islandReduceMotion, reduce)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                NBIconView(.settings, size: 16, color: IslandPalette.secondary)
                    .rotationEffect(.degrees(Double(headerSpin) * 120))
                    .animation(.spring(response: 0.7, dampingFraction: 0.62).speed(IslandMotion.speed), value: headerSpin)
                Text(L("Настройки"))
                    .settingsFont(12.5, .bold)
                    .foregroundStyle(IslandPalette.secondary)
            }
            Spacer(minLength: metrics.style == .notch ? metrics.notchWidth + 12 : 8)
            HStack(spacing: 6) {
                if let onTogglePin {
                    PinButton(pinned: pinned, bounce: pinBounce, action: onTogglePin)
                }
                SettingsEntryButton(isOpen: true, action: onClose)
            }
            .fixedSize()
        }
        .padding(.leading, Self.textInset)
        .padding(.trailing, 12)
        .frame(height: headerHeight)
        .padding(.top, metrics.style == .notch ? 0 : 2)
        .contentShape(Rectangle())
        .onAppear {
            guard !staticRender, !model.reduceMotion else { return }
            headerSpin &+= 1
        }
    }

    // MARK: Cards

    private var scroller: some View {
        let measured = staticRender ? SectionFrameCollector.shared.contentHeight ?? Self.estimatedContentHeight
            : contentHeight > 0 ? contentHeight : Self.estimatedContentHeight
        let viewport = staticViewport ?? min(measured, maxViewport)
        let scrolls = (staticViewport.map { _ in true } ?? false) || measured > maxViewport + 0.5
        return Group {
            if staticRender {
                cards
                    .offset(y: -staticScroll)
                    .frame(height: viewport, alignment: .top)
                    .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        cards
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.scrollSpace)).minY } action: {
                                scrollOffset = -$0
                            }
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    .scrollDisabled(!scrolls)
                    .frame(height: viewport)
                    .onChange(of: model.expanded) { _, section in
                        guard let section else { return }
                        // After the card has started to open: keep it in view (its final height is known).
                        Task {
                            try? await Task.sleep(for: IslandMotion.delay(0.06))
                            withAnimation(SettingsMotion.expand(reduce: model.reduceMotion)) {
                                proxy.scrollTo(section, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .mask {
            let top = staticRender ? staticScroll > 1 : scrollOffset > 1
            let bottom = scrolls && (staticRender ? staticScroll + viewport < measured - 1
                                                  : scrollOffset + viewport < measured - 1)
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                    .opacity(top ? 1 : 0)
                    .background(Color.black.opacity(top ? 0 : 1))
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 26)
                    .opacity(bottom ? 1 : 0)
                    .background(Color.black.opacity(bottom ? 0 : 1))
            }
            .animation(SettingsMotion.hover, value: top)
            .animation(SettingsMotion.hover, value: bottom)
        }
    }

    private static let scrollSpace = "settings-scroll"

    private var cards: some View {
        VStack(spacing: 6) {
            ForEach(Array(SettingsSection.allCases.enumerated()), id: \.element) { index, section in
                card(section)
                    .id(section)
                    .appearAfter(0.035 + 0.02 * Double(min(index, 8)), style: .row)
            }
            footer
                .appearAfter(0.035 + 0.02 * 9, style: .section)
        }
        .padding(.horizontal, Self.sidePadding)
        .padding(.top, metrics.style == .notch ? 8 : 2)
        .padding(.bottom, 12)
        .coordinateSpace(name: Self.cardsSpace)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .background {
            if staticRender {
                GeometryReader { geo in
                    let _ = SectionFrameCollector.shared.recordContent(geo.size.height)
                    Color.clear
                }
            }
        }
    }

    static let cardsSpace = "settings-cards"

    @ViewBuilder
    private func card(_ section: SettingsSection) -> some View {
        let expanded = model.expanded == section
        SettingsCard(section: section, summary: summary(section), summaryTone: summaryTone(section),
                     expanded: expanded, bounce: model.iconBounce[section] ?? 0,
                     accessory: accessory(section),
                     onTap: { tap(section) }) {
            sectionContent(section)
        }
        .background(SectionFrameProbe(section: section))
    }

    private func tap(_ section: SettingsSection) {
        if section == .launch {
            toggleLaunchAtLogin()
            return
        }
        withAnimation(SettingsMotion.expand(reduce: model.reduceMotion)) { model.toggle(section) }
    }

    @ViewBuilder
    private func sectionContent(_ section: SettingsSection) -> some View {
        switch section {
        case .island: IslandSettingsSection(store: store, screens: model.screens)
        case .sounds: SoundSettingsSection(model: model, store: store, previewer: model.previewer)
        case .agents: AgentSettingsSection(hooks: hooks)
        case .usage: UsageSettingsSection(store: store)
        case .hotkey: HotkeySettingsSection(store: store, recorder: model.recorder, hotkey: hotkey)
        case .widgets: WidgetSettingsSection(store: store)
        case .appearance: AppearanceSettingsSection(store: store, systemReduce: model.systemReduceMotion())
        case .language: LanguageSettingsSection(store: store)
        case .launch: EmptyView()
        case .privacy: PrivacySettingsSection(store: store, maintenance: maintenance)
        case .about: AboutSettingsSection()
        }
    }

    // MARK: Launch at login (a switch in its card's header)

    private func accessory(_ section: SettingsSection) -> AnyView? {
        guard section == .launch else { return nil }
        switch store.launchAtLogin {
        case .requiresApproval:
            return AnyView(Button(L("Разрешить…")) { store.openLoginItemsSettings() }
                .buttonStyle(SettingsButtonStyle(kind: .accent)))
        case .unavailable:
            return AnyView(SettingsToggle(isOn: .constant(false), enabled: false))
        case .enabled, .disabled:
            return AnyView(SettingsToggle(isOn: Binding(get: { store.launchAtLogin == .enabled },
                                                        set: { store.setLaunchAtLogin($0) })))
        }
    }

    private func toggleLaunchAtLogin() {
        switch store.launchAtLogin {
        case .enabled: store.setLaunchAtLogin(false)
        case .disabled: store.setLaunchAtLogin(true)
        case .requiresApproval: store.openLoginItemsSettings()
        case .unavailable: break
        }
    }

    // MARK: Summaries

    private func summary(_ section: SettingsSection) -> String {
        let v = store.values
        switch section {
        case .island:
            let hover = v.hoverOpen == .never ? L("Открывается по клику") : L("Наведение %@", v.hoverOpen.label.lowercased())
            // The style where the island is now (a screen with a notch or a monitor).
            let notched = NSScreen.main.map { $0.safeAreaInsets.top > 0 } ?? false
            return "\(v.islandStyle(hasNotch: notched).label) · \(hover.lowercasedFirst) · \(v.size.label.lowercased())"
        case .sounds:
            guard v.soundsEnabled else { return L("Выключены") }
            return L("Включены · громкость %@ %%", Int((v.soundVolume * 100).rounded()))
        case .agents:
            guard !hooks.reports.isEmpty else { return L("Проверяю…") }
            let found = AgentCatalog.settingsAgents.filter { hooks.reports[$0].map { $0.status != .agentMissing } ?? false }
            guard !found.isEmpty else { return L("Агенты не найдены") }
            let installed = found.filter { hooks.reports[$0]?.status == .installed }.count
            return L("Подключено %@ из %@", installed, found.count)
        case .usage:
            let source = v.claudeUsageViaAPI ? L("Claude через API") : L("Только statusLine")
            let whose = v.usageProvider == .auto ? "" : L(" · показываю %@", v.usageProvider.label)
            return L("%@ · раз в %@%@", source, v.usageRefresh.label, whose)
        case .hotkey:
            guard v.hotkeyEnabled else { return L("Выключена") }
            switch hotkey.status {
            case .taken, .system: return L("%@ · занято", v.hotkey.display)
            default: break
            }
            return v.hotkey.display
        case .widgets:
            let on = v.enabledWidgets
            guard on.count > 1 else { return L("Только агенты — без вкладок") }
            return on.map(\.title).joined(separator: " · ")
        case .appearance:
            return L("%@ · анимации %@", v.accent.label, v.motion.label.lowercased())
        case .language:
            let shown = L10n.shared.language.nativeName
            return v.language == .auto ? L("Авто · %@", shown) : shown
        case .launch:
            if let problem = store.launchAtLoginProblem, store.launchAtLogin != .enabled { return problem }
            switch store.launchAtLogin {
            case .enabled: return L("NotchBuddy стартует вместе с Mac")
            case .disabled: return L("Выключен")
            case .requiresApproval: return L("Нужно разрешение в Объектах входа")
            case .unavailable: return L("Только для NotchBuddy.app")
            }
        case .privacy:
            guard let summary = maintenance.backups else { return L("Без телеметрии") }
            let backups = summary.snapshots == 0 ? L("копий нет") : BackupsMaintenance.describe(summary)
            return L("Без телеметрии · %@", backups)
        case .about:
            return L("Версия %@", SettingsMaintenance.version)
        }
    }

    private func summaryTone(_ section: SettingsSection) -> Color? {
        switch section {
        case .launch where store.launchAtLogin == .requiresApproval: return SettingsPalette.warning
        case .hotkey:
            if store.values.hotkeyEnabled, case .taken = hotkey.status { return SettingsPalette.warning }
            return nil
        default: return nil
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10, weight: .bold))
            Text(L("Всё сохраняется и применяется сразу"))
                .settingsFont(10.5, .semibold)
        }
        .foregroundStyle(IslandPalette.tertiary)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Card

/// One section: an icon tile, the title and a one-line summary; opens in place.
struct SettingsCard<Content: View>: View {
    let section: SettingsSection
    let summary: String
    var summaryTone: Color?
    let expanded: Bool
    var bounce = 0
    var accessory: AnyView?
    let onTap: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var hovering = false

    static var radius: CGFloat { 16 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsDivider()
                        .padding(.bottom, 12)
                    content()
                }
                    .padding(.horizontal, 12)
                    .padding(.top, 0)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.settingsSectionContent(reduce: reduceMotion))
            }
        }
        .background(shape.fill(expanded ? SettingsPalette.cardOpen : hovering ? SettingsPalette.cardHover : SettingsPalette.card))
        .overlay {
            shape.strokeBorder(expanded ? SettingsPalette.selectionStroke : SettingsPalette.cardStroke, lineWidth: 0.5)
        }
        .clipShape(shape)
        .animation(SettingsMotion.hover, value: hovering)
    }

    private var header: some View {
        HStack(spacing: 11) {
            SettingsIconTile(section: section, size: 28, lit: expanded, bounce: bounce)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .settingsFont(13.5, .bold)
                    .foregroundStyle(Color.white)
                Text(summary)
                    .settingsFont(11, .medium)
                    .foregroundStyle(summaryTone ?? IslandPalette.tertiary)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                    .animation(IslandMotion.leaf, value: summary)
            }
            Spacer(minLength: 8)
            if let accessory {
                accessory
            } else if section.expandable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hovering || expanded ? IslandPalette.secondary : IslandPalette.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(expanded ? 0.1 : hovering ? 0.06 : 0)))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .frame(height: 48)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(section.expandable ? (expanded ? L("Свернуть") : L("Развернуть")) : "")
    }
}

private struct SectionRevealEffect: ViewModifier, Animatable {
    var q: Double

    var animatableData: Double {
        get { q }
        set { q = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(q)
            .blur(radius: 3 * (1 - q))
    }
}

extension AnyTransition {
    /// A section's rows come in on their own (`appearAfter`); leaving, they fade out quickly as the card folds.
    static func settingsSectionContent(reduce: Bool) -> AnyTransition {
        if reduce { return .opacity.animation(.easeOut(duration: 0.14).speed(IslandMotion.speed)) }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.06).speed(IslandMotion.speed)),
            removal: .modifier(active: SectionRevealEffect(q: 0), identity: SectionRevealEffect(q: 1))
                .animation(.easeOut(duration: 0.12).speed(IslandMotion.speed)))
    }
}

extension View {
    /// A row of an opening section: drops in `index` steps after the first.
    func settingsRowIn(_ index: Int) -> some View {
        appearAfter(0.05 + 0.028 * Double(min(index, 10)), style: .section)
    }
}

// MARK: - Entry button

/// ⚙️ in the list header (opens settings) and × in the settings header (closes them). The gear turns under the
/// pointer and, on the way to ×, the glyph swaps with a quarter turn.
struct SettingsEntryButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        // The gear turns a tooth on hover; open, it is the page's ×.
        IslandGlyphButton(icon: isOpen ? .close : .settings, active: isOpen,
                          help: isOpen ? L("Закрыть настройки") : L("Настройки"), action: action)
    }
}

// MARK: - Static renders: card frames

/// Collects the cards' frames during a static render (layout runs once there, so no state can carry them): a
/// render can then scroll a card into view in a second pass.
@MainActor
final class SectionFrameCollector {
    static let shared = SectionFrameCollector()
    var frames: [SettingsSection: CGRect] = [:]
    /// Natural height of the cards column.
    var contentHeight: CGFloat?

    func record(_ section: SettingsSection, _ frame: CGRect) -> Bool {
        frames[section] = frame
        return true
    }

    func recordContent(_ height: CGFloat) -> Bool {
        contentHeight = height
        return true
    }
}

private struct SectionFrameProbe: View {
    let section: SettingsSection
    @Environment(\.islandStaticRender) private var staticRender

    var body: some View {
        if staticRender {
            GeometryReader { geo in
                let _ = SectionFrameCollector.shared.record(section, geo.frame(in: .named(SettingsPage.cardsSpace)))
                Color.clear
            }
        }
    }
}

private extension String {
    /// "Наведение 0,1 с" → "наведение 0,1 с" (after a «·» in a summary).
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
