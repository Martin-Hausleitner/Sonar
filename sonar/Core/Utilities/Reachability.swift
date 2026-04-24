import Foundation
import Network

@MainActor
final class Reachability: ObservableObject {
    @Published private(set) var hasInternet: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.sonar.ios.reachability")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.hasInternet = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }
}
