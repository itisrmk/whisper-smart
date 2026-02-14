import Foundation
import Network

final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")

    private var isSatisfied = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isSatisfied = path.status == .satisfied
        }
        monitor.start(queue: queue)
    }

    var isReachable: Bool {
        isSatisfied
    }
}
