import AppKit
import SwiftUI
import NotchBuddyCore

// MARK: - Updates

/// «Обновления»: the version, «Проверить обновления…» (Sparkle's window does the rest), daily checks, automatic
/// installs and a link to the release notes. Everything is disabled in a build that cannot update itself.
struct UpdatesSettingsSection: View {
    @ObservedObject var updates: AppUpdates
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsRow(title: Self.versionLine(updates), hint: Self.lastCheckLine(updates)) {
                primaryButton
            }
            .settingsRowIn(0)
            if let note = notice {
                SettingsNote(text: note, tone: updates.isRunning ? .success : .info,
                             symbol: updates.isRunning ? "arrow.down.circle.fill" : "info.circle.fill")
                    .transition(.opacity.combined(with: .offset(y: -4)))
                    .settingsRowIn(1)
            }
            SettingsDivider().settingsRowIn(1)
            SettingsToggleRow(title: L("Проверять автоматически"),
                              hint: L("Раз в день, в фоне: один запрос appcast.xml на GitHub"),
                              isOn: Binding(get: { updates.checksAutomatically },
                                            set: { updates.setChecksAutomatically($0) }),
                              enabled: updates.isRunning)
                .settingsRowIn(2)
            SettingsToggleRow(title: L("Устанавливать автоматически"),
                              hint: L("Скачивает обновление само и ставит его при выходе или когда агенты давно не работают"),
                              isOn: Binding(get: { updates.installsAutomatically },
                                            set: { updates.setInstallsAutomatically($0) }),
                              enabled: updates.isRunning && updates.checksAutomatically
                                  && updates.configuration.allowsAutomaticUpdates)
                .settingsRowIn(3)
            SettingsDivider().settingsRowIn(4)
            HStack(spacing: 6) {
                Button { NSWorkspace.shared.open(UpdateConfiguration.releasesPage) } label: {
                    Label(L("Что нового"), systemImage: "doc.text")
                }
                .buttonStyle(SettingsButtonStyle(kind: .neutral))
                Spacer(minLength: 0)
            }
            .settingsRowIn(4)
            Text(L("Каждое обновление перед установкой проверяется подписью EdDSA."))
                .settingsFont(10.5, .medium)
                .foregroundStyle(IslandPalette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .settingsRowIn(5)
        }
        .animation(SettingsMotion.expand(reduce: reduceMotion), value: notice)
    }

    @ViewBuilder
    private var primaryButton: some View {
        let title = Self.primaryTitle(updates)
        if updates.downloadedVersion != nil {
            Button(title) { updates.installDownloaded() }
                .buttonStyle(SettingsButtonStyle(kind: .accent))
        } else if updates.foundVersion != nil {
            Button(title) { updates.checkForUpdates() }
                .buttonStyle(SettingsButtonStyle(kind: .accent))
                .disabled(!updates.canCheck)
        } else {
            Button(title) { updates.checkForUpdates() }
                .buttonStyle(SettingsButtonStyle(kind: .neutral))
                .disabled(!updates.isRunning || !updates.canCheck)
                .help(updates.isRunning ? "" : L("Обновления недоступны в этой сборке"))
        }
    }

    private var notice: String? {
        if !updates.isRunning {
            return L("В этой сборке обновления выключены. Новые версии — на странице релизов.")
        }
        if let version = updates.downloadedVersion {
            return L("Версия %@ скачана. Она установится при выходе или сама, когда агенты давно не работают.", version)
        }
        if let version = updates.foundVersion {
            return L("Вышла версия %@.", version)
        }
        return nil
    }

    // MARK: Text

    /// The row's button: install a downloaded update (only while it can be installed), open the one a background check
    /// found, or check. The same words as the menu bar menu and Sparkle's own window.
    static func primaryTitle(_ updates: AppUpdates) -> String {
        if updates.downloadedVersion != nil { return L("Установить и перезапустить") }
        if let version = updates.foundVersion { return L("Обновить до %@…", version) }
        return L("Проверить обновления…")
    }

    static func versionLine(_ updates: AppUpdates) -> String {
        L("Версия %@%@", updates.version, updates.build.map { " (\($0))" } ?? "")
    }

    static func lastCheckLine(_ updates: AppUpdates) -> String {
        guard let date = updates.lastCheck else { return L("Ещё не проверялось") }
        return L("Последняя проверка: %@", relative(date))
    }

    /// The card's one-line summary.
    static func summary(_ updates: AppUpdates) -> String {
        guard updates.isRunning else { return L("Недоступны в этой сборке") }
        if let version = updates.downloadedVersion { return L("Версия %@ скачана", version) }
        if let version = updates.foundVersion { return L("Доступна версия %@", version) }
        guard updates.checksAutomatically else { return L("Только вручную") }
        guard let date = updates.lastCheck else { return L("Раз в день") }
        return L("Раз в день · проверено %@", relative(date))
    }

    /// "сегодня в 14:02", "yesterday at 9:10 AM", "28 сент. 2025 г., 18:00" in the app's language.
    static func relative(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.shared.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        let absolute = f.string(from: date)
        f.doesRelativeDateFormatting = true
        let text = f.string(from: date)
        // "Today at 14:02" follows a colon or a «·»: lower-case the word, never a month's name.
        return text == absolute ? text : text.prefix(1).lowercased() + text.dropFirst()
    }
}
