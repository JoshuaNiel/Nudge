/// When the Dashboard forces its `DeviceActivityReport` to rebuild (docs/specs/phase-2-dashboard.md V1).
///
/// A rebuild changes the report's `.id`, which disconnects the extension's remote view and
/// connects a new one; done in quick succession the new connection sometimes never draws. So
/// every trigger (toolbar Refresh, a real foreground, the fallback Reload) only *requests* a
/// rebuild, which happens `debounce` after the last request: back-to-back triggers coalesce
/// into one. Day, week and mode changes are not rebuilds — they change only the filter.
///
/// Pure: the caller passes the time. The view keys a `.task` on `generation`, sleeps
/// `remainingDelay`, then calls `fire`.
struct ReportRebuildPolicy {

    static let defaultDebounce: Duration = .milliseconds(400)

    let debounce: Duration
    /// Changes on every request, so a `.task(id:)` keyed on it restarts its wait (and the
    /// cancelled earlier wait never fires).
    private(set) var generation = 0
    private var deadline: ContinuousClock.Instant?

    init() {
        self.init(debounce: Self.defaultDebounce)
    }

    init(debounce: Duration) {
        self.debounce = debounce
    }

    /// Schedules a rebuild `debounce` from now, replacing any pending one.
    mutating func request(at now: ContinuousClock.Instant) {
        deadline = now + debounce
        generation &+= 1
    }

    /// How long until the pending rebuild is due (zero if overdue); nil when nothing is pending.
    func remainingDelay(at now: ContinuousClock.Instant) -> Duration? {
        deadline.map { max(.zero, $0 - now) }
    }

    /// True once per request, when its deadline has passed: rebuild now.
    mutating func fire(at now: ContinuousClock.Instant) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }

    /// Drops the pending rebuild, e.g. when the report is being created fresh anyway.
    mutating func cancel() {
        deadline = nil
    }
}
