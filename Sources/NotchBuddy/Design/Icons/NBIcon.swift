import SwiftUI
import NotchBuddyCore

/// NotchBuddy's own icon set: drawn on a 24 × 24 grid with one stroke weight (1.8 grid units, never
/// thinner than 1.25 pt), round caps and joins, and an optional second tone (a soft fill under the
/// line work). Every icon is a pure function of three numbers, so each can animate:
/// - `hover` 0 → 1: the icon's gesture (the gear turns a tooth, the pin tilts, the arrow jumps);
/// - `value` 0 … 1: a state the icon shows (sound on/off, play/pause, pinned, battery level, timer);
/// - `phase` 0 ..< 1: a loop (spinner, hourglass, blinking cursor, pulsing waves).
enum NBIcon: String, CaseIterable, Identifiable {
    // Tools
    case terminal, edit, read, search, web, agent, mcp, wrench, plan, question
    // Statuses
    case working, waiting, done, error, idle
    // Actions
    case settings, soundOn, soundOff, pin, jump, copy, folder, check, close, chevron, bell, sparkle
    // Media & widgets
    case play, pause, next, previous, calendar, timer, battery, cpu, tray, music

    var id: String { rawValue }

    // l10n-ignore-begin (group titles and motion notes: the design sheet only)
    enum Group: String, CaseIterable {
        case tools, statuses, actions, widgets

        var title: String {
            switch self {
            case .tools: return "Инструменты"
            case .statuses: return "Статусы"
            case .actions: return "Действия"
            case .widgets: return "Медиа и виджеты"
            }
        }

        var icons: [NBIcon] { NBIcon.allCases.filter { $0.group == self } }
    }
    // l10n-ignore-end

    var group: Group {
        switch self {
        case .terminal, .edit, .read, .search, .web, .agent, .mcp, .wrench, .plan, .question: return .tools
        case .working, .waiting, .done, .error, .idle: return .statuses
        case .settings, .soundOn, .soundOff, .pin, .jump, .copy, .folder, .check, .close, .chevron, .bell, .sparkle: return .actions
        case .play, .pause, .next, .previous, .calendar, .timer, .battery, .cpu, .tray, .music: return .widgets
        }
    }

    /// Localized name (accessibility, design sheet).
    var title: String {
        switch self {
        case .terminal: return L("Терминал")
        case .edit: return L("Правка")
        case .read: return L("Чтение")
        case .search: return L("Поиск")
        case .web: return L("Сеть")
        case .agent: return L("Агент")
        case .mcp: return "MCP"
        case .wrench: return L("Инструмент")
        case .plan: return L("План")
        case .question: return L("Вопрос")
        case .working: return L("Работает")
        case .waiting: return L("Ждёт")
        case .done: return L("Готово")
        case .error: return L("Ошибка")
        case .idle: return L("Простой")
        case .settings: return L("Настройки")
        case .soundOn: return L("Звук")
        case .soundOff: return L("Без звука")
        case .pin: return L("Закрепить")
        case .jump: return L("Перейти")
        case .copy: return L("Копировать")
        case .folder: return L("Папка")
        case .check: return L("Галочка")
        case .close: return L("Закрыть")
        case .chevron: return L("Раскрыть")
        case .bell: return L("Уведомление")
        case .sparkle: return L("Магия")
        case .play: return L("Играть")
        case .pause: return L("Пауза")
        case .next: return L("Дальше")
        case .previous: return L("Назад")
        case .calendar: return L("Календарь")
        case .timer: return L("Таймер")
        case .battery: return L("Батарея")
        case .cpu: return L("Процессор")
        case .tray: return L("Полка")
        case .music: return L("Музыка")
        }
    }

    // l10n-ignore-begin
    /// What the hover gesture / loop does (design sheet caption).
    var motionNote: String {
        switch self {
        case .terminal: return "курсор мигает"
        case .edit: return "пишет строку"
        case .read: return "строки дописываются"
        case .search: return "лупа ищет"
        case .web: return "глобус вращается"
        case .agent: return "улыбается, антенна"
        case .mcp: return "вилка входит"
        case .wrench: return "подкручивает"
        case .plan: return "пункт отмечен"
        case .question: return "покачивается"
        case .working: return "крутится"
        case .waiting: return "песок сыплется"
        case .done: return "галочка + салют"
        case .error: return "встряхивается"
        case .idle: return "дремлет, zZ"
        case .settings: return "поворот на зубец"
        case .soundOn, .soundOff: return "волны ↔ крестик"
        case .pin: return "наклон ↔ воткнут"
        case .jump: return "стрелка улетает"
        case .copy: return "листы → галочка"
        case .folder: return "крышка открывается"
        case .check: return "рисуется"
        case .close: return "поворот на 90°"
        case .chevron: return "разворот"
        case .bell: return "звенит"
        case .sparkle: return "мерцает"
        case .play, .pause: return "морф ▶ ↔ ❚❚"
        case .next, .previous: return "шаг вперёд"
        case .calendar: return "день перескакивает"
        case .timer: return "стрелка идёт"
        case .battery: return "уровень"
        case .cpu: return "ножки бегут"
        case .tray: return "падает на полку"
        case .music: return "ноты подпрыгивают"
        }
    }
    // l10n-ignore-end

    /// The `value` an icon shows when the caller gives none.
    var defaultValue: Double {
        switch self {
        case .soundOn, .pause, .done, .check: return 1
        case .soundOff, .play, .pin, .copy, .chevron: return 0
        case .battery: return 0.72
        case .timer: return 0.35
        default: return 0
        }
    }

    /// Whether the icon has a loop (`phase`).
    var loops: Bool {
        switch self {
        case .terminal, .search, .web, .agent, .working, .waiting, .idle, .settings, .soundOn,
             .bell, .sparkle, .timer, .cpu:
            return true
        default:
            return false
        }
    }

    var loopPeriod: Double {
        switch self {
        case .working: return NBMotion.spinPeriod
        case .waiting: return 3.2
        case .terminal: return NBMotion.blinkPeriod
        case .web: return 6
        case .settings: return 4
        case .timer: return 8
        case .agent: return 4.5
        case .idle: return 3
        case .bell: return 2.4
        case .cpu: return 1.6
        default: return NBMotion.breathePeriod
        }
    }

    /// Redraws per second of the loop: fast motion gets the full 60, slow drifts 30, the cursor blink
    /// (a step) 15. Below these rates the eye sees no difference; above them only the battery does.
    var loopFrameRate: Double {
        switch self {
        case .working, .waiting, .bell: return 60
        case .terminal: return 15
        default: return 30
        }
    }

    /// The loop phase drawn when nothing animates (static renders, Reduce Motion).
    var restPhase: Double {
        switch self {
        case .working: return 0.08
        case .waiting: return 0.3
        case .terminal: return 0.2
        case .idle: return 0.35
        case .sparkle: return 0.25
        case .cpu: return 0.4
        default: return 0
        }
    }

    /// Curve of the hover gesture.
    var hoverCurve: MotionCurve {
        switch self {
        case .question, .error, .bell, .edit, .wrench, .jump: return NBMotion.iconWobble
        default: return NBMotion.iconHover
        }
    }

    /// Curve of `value` changes.
    var valueCurve: MotionCurve {
        switch self {
        case .done: return NBMotion.celebrate
        case .check: return MotionCurve.curve(.easeOut, 0.4)
        case .battery, .timer: return NBMotion.fill
        default: return NBMotion.morph
        }
    }

    // MARK: Mapping

    /// The icon of a tool call ("Bash" → terminal, "mcp__github__…" → mcp). Uses `ToolStyle`'s
    /// classification so the two always agree.
    static func tool(_ toolName: String?) -> NBIcon {
        switch ToolStyle.symbol(for: toolName) {
        case "apple.terminal": return .terminal
        case "pencil": return .edit
        case "doc.text": return .read
        case "globe": return .web
        case "magnifyingglass": return .search
        case "person.2": return .agent
        case "list.bullet.clipboard": return .plan
        case "puzzlepiece.extension": return .mcp
        case "lock.open": return .question
        default: return .wrench
        }
    }

    static func status(_ status: SessionStatus) -> NBIcon {
        switch status {
        case .working: return .working
        case .waitingForUser: return .waiting
        case .finished: return .done
        case .error: return .error
        case .idle: return .idle
        }
    }
}
