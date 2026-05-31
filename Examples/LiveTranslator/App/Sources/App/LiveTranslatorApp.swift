import SwiftUI

@main
struct LiveTranslatorApp: App {
    @StateObject private var viewModel = TranslatorViewModel(configuration: AppConfiguration.load())

    var body: some Scene {
        WindowGroup {
            TranslatorView(viewModel: viewModel)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
    }
}
