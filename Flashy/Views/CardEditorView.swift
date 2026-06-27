import SwiftUI
import SwiftData

// MARK: - Presentation token

enum CardEditorPresentation: Identifiable {
    case add
    case edit(Card)

    var id: String {
        switch self {
        case .add: return "__add__"
        case .edit(let card): return card.id
        }
    }
}

// MARK: - CardEditorView

struct CardEditorView: View {
    let presentation: CardEditorPresentation

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var appStates: [AppState]

    @State private var front: String = ""
    @State private var back: String = ""
    @State private var isFlipped = false
    @State private var savedCount = 0

    @FocusState private var focusedField: EditorField?

    private enum EditorField { case front, back }

    private var isAddMode: Bool {
        if case .add = presentation { return true }
        return false
    }

    private var existingCard: Card? {
        if case .edit(let c) = presentation { return c }
        return nil
    }

    private var canSave: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Placeholder ("ghost") text color — less faded than the system default so it stays readable on the white card.
    private var placeholderColor: Color {
        FlashyTheme.cardFaceSecondaryText(colorSchemeContrast: colorSchemeContrast)
    }

    private var screenBg: Color {
        let app = appStates.first
        return FlashyTheme.StudyBackgroundPreset
            .resolved(raw: app?.studyBackgroundRaw)
            .fillColor(colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            screenBg.ignoresSafeArea()

            VStack(spacing: 0) {
                editorHeader
                Spacer(minLength: 8)
                sideLabel
                editorCard
                Spacer(minLength: 24)
                editorBottomBar
            }
            .padding(.horizontal, 16)
        }
        .onAppear {
            if let card = existingCard {
                front = card.front
                back = card.back
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focusedField = .front
            }
        }
    }

    // MARK: - Header

    private var editorHeader: some View {
        HStack {
            Text(isAddMode ? "Nueva tarjeta" : "Editar tarjeta")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            if isAddMode && savedCount > 0 {
                Text("\(savedCount) guardada\(savedCount == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .frame(height: 44)
    }

    // MARK: - Side label (Pregunta / Respuesta)

    private var sideLabel: some View {
        Text(isFlipped ? "Respuesta" : "Pregunta")
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(FlashyTheme.editAccent(colorScheme: colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.2), value: isFlipped)
    }

    // MARK: - Card face

    private var editorCard: some View {
        ZStack {
            backFace
                .rotation3DEffect(
                    .degrees(reduceMotion ? 0 : (isFlipped ? 0 : -180)),
                    axis: (x: 0, y: 1, z: 0)
                )
                .opacity(isFlipped ? 1 : 0)

            frontFace
                .rotation3DEffect(
                    .degrees(reduceMotion ? 0 : (isFlipped ? 180 : 0)),
                    axis: (x: 0, y: 1, z: 0)
                )
                .opacity(isFlipped ? 0 : 1)
        }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.78),
            value: isFlipped
        )
        .compositingGroup()
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.26),
            radius: 16, x: 0, y: 9
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12),
            radius: 7, x: 0, y: 4
        )
    }

    private var frontFace: some View {
        cardSurface {
            VStack(spacing: 16) {
                ZStack {
                    if front.isEmpty {
                        Text("Español")
                            .font(.system(size: 34, weight: .medium, design: .rounded))
                            .foregroundStyle(placeholderColor)
                    }
                    TextField("", text: $front, axis: .vertical)
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .foregroundStyle(FlashyTheme.cardFacePrimaryText(colorSchemeContrast: colorSchemeContrast))
                        .focused($focusedField, equals: .front)
                        .submitLabel(.next)
                        .onSubmit { flipToBack() }
                        .tint(FlashyTheme.editAccent(colorScheme: colorScheme))
                }

                Button {
                    flipToBack()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Voltear")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(FlashyTheme.editAccent(colorScheme: colorScheme))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
    }

    private var backFace: some View {
        cardSurface {
            VStack(spacing: 16) {
                ZStack {
                    if back.isEmpty {
                        Text("Inglés")
                            .font(.system(size: 34, weight: .medium, design: .rounded))
                            .foregroundStyle(placeholderColor)
                    }
                    TextField("", text: $back, axis: .vertical)
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .foregroundStyle(FlashyTheme.cardFacePrimaryText(colorSchemeContrast: colorSchemeContrast))
                        .focused($focusedField, equals: .back)
                        .submitLabel(.done)
                        .tint(FlashyTheme.editAccent(colorScheme: colorScheme))
                }

                let displayFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
                if !displayFront.isEmpty {
                    Text(displayFront)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(FlashyTheme.cardFaceSecondaryText(colorSchemeContrast: colorSchemeContrast))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }

                Button {
                    flipToFront()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Voltear")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(FlashyTheme.editAccent(colorScheme: colorScheme))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func cardSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let surface: Color = colorScheme == .dark
            ? Color(red: 0.99, green: 0.99, blue: 0.995)
            : Color.white
        let borderColor: Color = colorScheme == .dark
            ? Color.black.opacity(colorSchemeContrast == .increased ? 0.42 : 0.3)
            : Color.black.opacity(colorSchemeContrast == .increased ? 0.3 : 0.2)
        let borderWidth: CGFloat = colorSchemeContrast == .increased ? 1.75 : 1.15

        content()
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Bottom bar

    private var editorBottomBar: some View {
        HStack(spacing: 12) {
            // Left: Salir (add) / Cancelar (edit) — red, dismiss without saving
            dismissButton

            // Right: Guardar — green, save
            saveButton
        }
        .padding(.bottom, 8)
    }

    private var dismissButton: some View {
        Button {
            dismissEditor()
        } label: {
            Text(isAddMode ? "Salir" : "Cancelar")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(FlashyTheme.swipeRed.opacity(colorScheme == .dark ? 0.9 : 0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(FlashyTheme.swipeRed.opacity(colorScheme == .dark ? 0.95 : 0.88), lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button {
            saveCard()
        } label: {
            Text("Guardar")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(
                    (canSave ? FlashyTheme.swipeGreen : Color.gray)
                        .opacity(colorScheme == .dark ? 0.9 : 0.82)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            (canSave ? FlashyTheme.swipeGreen : Color.gray)
                                .opacity(colorScheme == .dark ? 0.95 : 0.88),
                            lineWidth: 1.5
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
    }

    // MARK: - Actions

    private func flipToBack() {
        guard !isFlipped else { return }
        isFlipped = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            focusedField = .back
        }
    }

    private func flipToFront() {
        guard isFlipped else { return }
        isFlipped = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            focusedField = .front
        }
    }

    private func dismissEditor() {
        focusedField = nil
        // Parent (StudyView) clears its fullScreenCover binding on this notification.
        NotificationCenter.default.post(
            name: .flashyEditorDismiss,
            object: nil,
            userInfo: ["added": savedCount]
        )
    }

    private func saveCard() {
        let trimmedFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBack = back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFront.isEmpty, !trimmedBack.isEmpty else { return }

        switch presentation {
        case .add:
            upsertCard(front: trimmedFront, back: trimmedBack)
            savedCount += 1
            // Auto-otra: reset fields and flip for next card
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)) {
                isFlipped = false
            }
            front = ""
            back = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                focusedField = .front
            }

        case .edit(let card):
            card.front = trimmedFront
            card.back = trimmedBack
            try? modelContext.save()
            NotificationCenter.default.post(
                name: .flashyEditorDismiss,
                object: nil,
                userInfo: ["added": 0]
            )
        }
    }

    private func upsertCard(front: String, back: String) {
        let cardId = HashID.cardId(forFront: front)
        let fd = FetchDescriptor<Card>(predicate: #Predicate { $0.id == cardId })
        if let existing = try? modelContext.fetch(fd).first {
            existing.back = back
        } else {
            let now = Date()
            let card = Card(
                id: cardId,
                front: front,
                back: back,
                difficulty: 5.0,
                stability: 0.1,
                lapses: 0,
                reps: 0,
                state: .new,
                createdAt: now,
                nextDueAt: now
            )
            modelContext.insert(card)
        }
        try? modelContext.save()
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let flashyEditorDismiss = Notification.Name("flashyEditorDismiss")
}
