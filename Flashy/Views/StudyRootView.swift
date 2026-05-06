import SwiftData
import SwiftUI

struct StudyRootView: View {
    @Query private var appStates: [AppState]

    var body: some View {
        StudyView()
            .preferredColorScheme(colorSchemeOverride)
    }

    private var colorSchemeOverride: ColorScheme? {
        switch appStates.first?.darkModeOverrideRaw {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}
