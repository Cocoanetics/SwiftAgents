import UIKit

@MainActor
final class BackgroundTaskController {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String) {
        guard identifier == .invalid else { return }

        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor [weak self] in
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
