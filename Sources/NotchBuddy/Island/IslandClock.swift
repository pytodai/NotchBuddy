import Foundation
import Observation

/// One shared 1 Hz clock for every running timer on the island ("работает 2:14", "ждёт 0:20"), aligned
/// to whole seconds so all of them tick together. It runs only while a view on screen shows a clock (the
/// list, a card, the floating pill of a working or waiting session); previews use a frozen one so every image
/// shows the same times.
@Observable
@MainActor
final class IslandClock {
    private(set) var now: Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let frozen: Bool
    /// Film renders (`--render-promo`) drive the clock from their virtual timeline (`film(at:)`); the real timer never runs.
    @ObservationIgnored private var filmed = false

    init(frozenAt date: Date? = nil) {
        now = date ?? Date()
        frozen = date != nil
    }

    func setRunning(_ running: Bool) {
        guard !frozen, !filmed, running != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard running else { return }
        now = Date()
        // First tick on the next whole second, then every second.
        let next = Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.rounded(.down) + 1)
        let timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        // Whole seconds tick together within 0.1 s; a looser deadline lets the system coalesce the wake-up.
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The virtual time of a film render: every clock on the island shows `date` (whole seconds, like the live tick).
    func film(at date: Date) {
        filmed = true
        timer?.invalidate()
        timer = nil
        let whole = Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
        if whole != now { now = whole }
    }
}
