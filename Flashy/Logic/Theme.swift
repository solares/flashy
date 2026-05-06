import SwiftUI

enum FlashyTheme {
    static let swipeGreen = Color(red: 15 / 255, green: 110 / 255, blue: 86 / 255)
    static let swipeRed = Color(red: 163 / 255, green: 45 / 255, blue: 45 / 255)
    static let flashTeal = Color(red: 15 / 255, green: 110 / 255, blue: 86 / 255).opacity(0.5)
    static let flashRed = Color(red: 163 / 255, green: 45 / 255, blue: 45 / 255).opacity(0.5)

    /// Card faces use a light surface in every app color scheme; ink must stay dark so text never follows `.primary` (which is light in dark mode).
    static func cardFacePrimaryText(colorSchemeContrast: ColorSchemeContrast) -> Color {
        switch colorSchemeContrast {
        case .increased:
            return Color.black
        default:
            return Color(red: 0.11, green: 0.11, blue: 0.13)
        }
    }

    static func cardFaceSecondaryText(colorSchemeContrast: ColorSchemeContrast) -> Color {
        switch colorSchemeContrast {
        case .increased:
            return Color(red: 0.22, green: 0.22, blue: 0.24)
        default:
            return Color(red: 0.38, green: 0.39, blue: 0.43)
        }
    }

    /// Solid study screen tints (opaque). Card faces stay white for contrast.
    enum StudyBackgroundPreset: String, CaseIterable, Identifiable {
        case offWhite
        case warmCream
        case softMist
        case paleSlate
        case systemChrome

        var id: String { rawValue }

        var title: String {
            switch self {
            case .offWhite: return "Blanco suave"
            case .warmCream: return "Crema cálida"
            case .softMist: return "Niebla suave"
            case .paleSlate: return "Pizarra clara"
            case .systemChrome: return "Sistema"
            }
        }

        func fillColor(colorScheme: ColorScheme) -> Color {
            switch self {
            case .offWhite:
                return colorScheme == .light
                    ? Color(red: 0.97, green: 0.97, blue: 0.955)
                    : Color(red: 0.11, green: 0.11, blue: 0.12)
            case .warmCream:
                return colorScheme == .light
                    ? Color(red: 0.99, green: 0.965, blue: 0.93)
                    : Color(red: 0.13, green: 0.11, blue: 0.09)
            case .softMist:
                return colorScheme == .light
                    ? Color(red: 0.94, green: 0.955, blue: 0.97)
                    : Color(red: 0.09, green: 0.11, blue: 0.13)
            case .paleSlate:
                return colorScheme == .light
                    ? Color(red: 0.91, green: 0.93, blue: 0.94)
                    : Color(red: 0.08, green: 0.09, blue: 0.11)
            case .systemChrome:
                return Color(uiColor: .systemGroupedBackground)
            }
        }

        static func resolved(raw: String?) -> StudyBackgroundPreset {
            guard let raw, let p = StudyBackgroundPreset(rawValue: raw) else { return .offWhite }
            return p
        }
    }
}
