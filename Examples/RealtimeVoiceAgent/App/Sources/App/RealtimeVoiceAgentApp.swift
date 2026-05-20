import SwiftUI
import UIKit

enum CallLaunchConstants {
    static let defaultHandle = "Clawdys"
    static let urlScheme = "realtimevoiceagent"
}

final class StartCallRouter {
    private var pendingHandles: [String] = []

    var onStartCallRequested: ((String) -> Void)? {
        didSet {
            flushPendingHandles()
        }
    }

    @discardableResult
    func handle(url: URL) -> Bool {
        guard let handle = url.startCallHandle else {
            return false
        }

        requestStartCall(handle: handle)
        return true
    }

    func requestStartCall(handle: String) {
        guard !handle.isEmpty else { return }

        if let onStartCallRequested {
            onStartCallRequested(handle)
        } else {
            pendingHandles.append(handle)
        }
    }

    private func flushPendingHandles() {
        guard let onStartCallRequested, !pendingHandles.isEmpty else { return }

        let handles = pendingHandles
        pendingHandles.removeAll()

        for handle in handles {
            onStartCallRequested(handle)
        }
    }
}

final class AppServices {
    static let shared = AppServices()

    let callKitController = CallKitController()
    let startCallRouter = StartCallRouter()

    private init() {}
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = AppServices.shared.callKitController
        return true
    }
}

@main
struct RealtimeVoiceAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let isUITestCallKitMode: Bool

    @StateObject private var viewModel: ConversationViewModel

    init() {
        let isUITestCallKitMode = ProcessInfo.processInfo.arguments.contains("UITEST_CALLKIT_SIMULATION")
        self.isUITestCallKitMode = isUITestCallKitMode

        let configuration = isUITestCallKitMode ? .uiTestStub : AppConfiguration.load()
        let services = AppServices.shared
        _viewModel = StateObject(
            wrappedValue: ConversationViewModel(
                configuration: configuration,
                isUITestCallKitMode: isUITestCallKitMode,
                callKitController: services.callKitController,
                startCallRouter: services.startCallRouter
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ConversationView(viewModel: viewModel)
                .onChange(of: scenePhase) { _, newPhase in
                    viewModel.handleScenePhase(newPhase)
                }
                .onOpenURL { url in
                    _ = AppServices.shared.startCallRouter.handle(url: url)
                }
        }
    }
}

extension URL {
    var startCallHandle: String? {
        guard let scheme,
              scheme.caseInsensitiveCompare(CallLaunchConstants.urlScheme) == .orderedSame,
              let host,
              !host.isEmpty else {
            return nil
        }

        return host.removingPercentEncoding ?? host
    }
}
