import Foundation
import Network

/// Whether the device can reach the network, and a callback when it becomes reachable.
protocol NetworkStatusProviding: AnyObject {
    var isOnline: Bool { get }
    /// Called on the main actor each time the network goes from unreachable to reachable.
    func addReachabilityHandler(_ handler: @escaping @MainActor () -> Void)
}

/// `NWPathMonitor` wrapper. Starts monitoring on creation.
///
/// `isOnline` starts `true` until the first path update arrives (a moment after start): a
/// request made in that window fails fast with a `URLError` if the device is actually offline,
/// which every caller already handles.
@MainActor
final class NetworkMonitor: NetworkStatusProviding {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    private var handlers: [@MainActor () -> Void] = []
    private let monitor = NWPathMonitor()

    private init() {
        // The update handler runs on the monitor's queue; hop to the main actor for state.
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            Task { @MainActor in self.update(isOnline: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.joshuaqn.Nudge.NetworkMonitor", qos: .utility))
    }

    func addReachabilityHandler(_ handler: @escaping @MainActor () -> Void) {
        handlers.append(handler)
    }

    private func update(isOnline online: Bool) {
        let becameReachable = online && !isOnline
        isOnline = online
        if becameReachable { handlers.forEach { $0() } }
    }
}
