import SwiftData
import SwiftUI

@main
struct FlashyApp: App {
    private let sharedModelContainer: ModelContainer = {
        let schema = Schema([Card.self, AppState.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    var body: some Scene {
        WindowGroup {
            StudyRootView()
                .modelContainer(sharedModelContainer)
                .onOpenURL { url in
                    NotificationCenter.default.post(
                        name: .flashyOpenCSV,
                        object: nil,
                        userInfo: ["url": url]
                    )
                }
        }
    }
}
