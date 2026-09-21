import Foundation

/// A single reusable timer that follows the wall clock, so a deadline that passes while the Mac is
/// asleep fires right after wake. Rescheduling reuses the same dispatch source.
@MainActor
final class WallClockTimer {
    private let source: DispatchSourceTimer
    private(set) var fireDate: Date?
    var onFire: (() -> Void)?

    init() {
        // `.strict` asks the system to respect our leeway even when it would like to coalesce more.
        source = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        source.schedule(wallDeadline: .distantFuture)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fireDate = nil
                self.onFire?()
            }
        }
        source.activate()
    }

    /// Fires once at `date`. `leeway` lets the system batch the wake-up with other work.
    func schedule(at date: Date, leeway: TimeInterval) {
        fireDate = date
        source.schedule(
            wallDeadline: DispatchWallTime(date),
            leeway: .milliseconds(Int(max(leeway, 0) * 1000))
        )
    }

    func cancel() {
        fireDate = nil
        source.schedule(wallDeadline: .distantFuture)
    }
}

extension DispatchWallTime {
    init(_ date: Date) {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        self.init(timespec: timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000)))
    }
}
