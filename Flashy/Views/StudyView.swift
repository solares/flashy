import SwiftUI
import SwiftData
import UIKit

// MARK: - Review undo stack (session-only; not persisted)

private struct ReviewSnapshot {
    let cardId: String
    let grade: Grade
    let wasFlipped: Bool
    let releaseOffset: CGSize
    let releaseRotation: Double
    let difficulty: Double
    let stability: Double
    let lapses: Int
    let reps: Int
    let state: ReviewState
    let lastReviewedAt: Date?
    let nextDueAt: Date
    let firstShownForPacingAt: Date?
    let historyJSON: Data
    let prevCurrentCardId: String?
    let prevBonusBudget: Int
    let prevBonusSeenIds: [String]
    let prevNewCardsIntroducedToday: Int
    let prevNewCardsIntroducedDay: Date?
}

private enum StudyChromeTypography {
    /// Shared label size for Reverso, Otra vez, Bien, Atrás.
    static let labelFont = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let iconFont = Font.system(size: 17, weight: .bold)
    /// Header remaining-count emphasis (slightly larger).
    static let countFont = Font.system(size: 23, weight: .semibold, design: .rounded)

    /// Horizontal / vertical padding for Reverso-style capsule pills.
    static let pillHPadding: CGFloat = 16
    static let pillVPadding: CGFloat = 9
    /// Total capsule row height matches Reverso and Atrás (content + symmetric padding).
    static let capsuleRowHeight: CGFloat = 43
}

struct StudyView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme

    @Query private var cards: [Card]
    @Query private var appStates: [AppState]

    @State private var isFlipped = false
    @State private var flyOffset: CGSize = .zero
    @State private var flyRotation: Double = 0
    @State private var flashColor: Color = .clear
    @State private var flashOpacity: Double = 0
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    @State private var showStats = false
    @State private var showSettings = false
    @State private var showUpcoming = false
    @State private var lookupWord: DictionaryLookupItem?

    @State private var showDeleteConfirm = false
    @State private var cardToDelete: Card?

    /// Scale factor for the counter capsule bump animation when the count increases.
    @State private var countBumpScale: CGFloat = 1.0

    /// Session-only graded-card undo trail (FIFO cap).
    @State private var undoStack: [ReviewSnapshot] = []
    @State private var undoStackAnchoredDay: Date?
    @State private var suppressNextFlipReset = false

    private let undoCap = 50

    private var appState: AppState? { appStates.first }

    private var undoAvailable: Bool {
        flyOffset == .zero && !undoStack.isEmpty
    }

    var body: some View {
        Group {
            if let app = appState {
                studyContent(app: app)
            } else {
                ProgressView("Cargando...")
            }
        }
        .task {
            await bootstrapAppState()
            await runDifficultyRescueIfNeeded()
        }
    }

    @ViewBuilder
    private func studyContent(app: AppState) -> some View {
        let now = Date()
        let queue = CardScheduler.studyQueue(cards: cards, appState: app, now: now)
        let hasStrict = CardScheduler.hasScheduledStudyWork(cards: cards, appState: app, now: now)
        let isCaughtUp = !cards.isEmpty && !hasStrict && app.effectiveBonusReviewBudget == 0

        let screenBg = FlashyTheme.StudyBackgroundPreset.resolved(raw: app.studyBackgroundRaw)
            .fillColor(colorScheme: colorScheme)

        ZStack {
            screenBg
                .ignoresSafeArea()

            // Full-screen grade flash — sits above the background, below all UI.
            flashColor
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                headerRow(app: app, hasStrict: hasStrict)
                if let activeCard = queue.first {
                    reverseModeRow(app: app, card: activeCard)
                }
                Spacer(minLength: 8)
                GeometryReader { geo in
                    middleStudyCanvas(geo: geo, queue: queue, isCaughtUp: isCaughtUp, app: app)
                }
                bottomArrowsRow(active: swipeCommitTargetCard(queue: queue, app: app), app: app)
            }
            .padding(.horizontal, 16)

            if let toast {
                VStack {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.top, 12)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: cards.count) {
            await MainActor.run {
                syncCurrentCardIfNeeded(app: app)
            }
        }
        .task(id: app.effectiveBonusReviewBudget) {
            await MainActor.run {
                syncCurrentCardIfNeeded(app: app)
            }
        }
        .onChange(of: queue.first?.id) { _, newId in
            if suppressNextFlipReset {
                suppressNextFlipReset = false
                return
            }
            if newId != nil {
                isFlipped = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .flashyProgressReset)) { _ in
            clearUndoStack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .flashyOpenCSV)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            importCSV(from: url)
        }
        .sheet(isPresented: $showStats) {
            StatsView()
        }
        .sheet(isPresented: $showUpcoming) {
            UpcomingView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(item: $lookupWord) { item in
            DictionaryView(suggestedWords: item.suggestedWords)
        }
        .task {
            await MainActor.run {
                StreakUpdater.update(app: app, now: Date())
                try? modelContext.save()
            }
        }
        .alert("¿Eliminar esta tarjeta?", isPresented: $showDeleteConfirm) {
            Button("Cancelar", role: .cancel) {
                cardToDelete = nil
            }
            Button("Eliminar", role: .destructive) {
                if let card = cardToDelete {
                    performDelete(card: card, app: app)
                }
                cardToDelete = nil
            }
        } message: {
            Text("No se puede deshacer.")
        }
    }

    /// Resolves swipe targets when `studyQueue`'s leading card is briefly out of sync with SwiftUI (keeps bottom bar steady).
    private func swipeCommitTargetCard(queue: [Card], app: AppState) -> Card? {
        let now = Date()
        let inSession =
            CardScheduler.hasScheduledStudyWork(cards: cards, appState: app, now: now)
                || app.effectiveBonusReviewBudget > 0
        guard inSession else { return nil }
        if let c = queue.first { return c }
        if let id = app.currentCardId,
           let c = cards.first(where: { $0.id == id }) {
            return c
        }
        return CardScheduler.pickStudyCard(cards: cards, appState: app, now: now, respectCurrentCard: false)?
            .card
    }

    @ViewBuilder
    private func middleStudyCanvas(
        geo: GeometryProxy,
        queue: [Card],
        isCaughtUp: Bool,
        app: AppState
    ) -> some View {
        let w = min(geo.size.width - 32, 340)
        if let active = queue.first {
            CardStack(
                stack: queue,
                cardWidth: w,
                hapticsEnabled: app.hapticsEnabled,
                reduceMotion: reduceMotion,
                colorSchemeContrast: colorSchemeContrast,
                reverseModeEnabled: app.effectiveReverseModeEnabled,
                isFlipped: $isFlipped,
                flyOffset: $flyOffset,
                flyRotation: $flyRotation,
                onCommit: { grade, offset, rotation in
                    commit(active: active, grade: grade, app: app, releaseOffset: offset, releaseRotation: rotation)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -44)
        } else if let salvage = swipeCommitTargetCard(queue: queue, app: app) {
            CardStack(
                stack: [salvage],
                cardWidth: w,
                hapticsEnabled: app.hapticsEnabled,
                reduceMotion: reduceMotion,
                colorSchemeContrast: colorSchemeContrast,
                reverseModeEnabled: app.effectiveReverseModeEnabled,
                isFlipped: $isFlipped,
                flyOffset: $flyOffset,
                flyRotation: $flyRotation,
                onCommit: { grade, offset, rotation in
                    commit(active: salvage, grade: grade, app: app, releaseOffset: offset, releaseRotation: rotation)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -44)
        } else if isCaughtUp {
            caughtUpState(app: app)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if cards.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("Sin tarjetas")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Envía un CSV por AirDrop con las columnas front, back y tags para agregar tarjetas.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func caughtUpState(app: AppState) -> some View {
        let n = CardScheduler.bonusSessionReviewCount
        return VStack(spacing: 20) {
            Spacer()
            Text("Estás al día")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Repaso de refuerzo: hasta \(n) tarjetas olvidadas y difíciles, a tu ritmo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                app.bonusReviewBudget = CardScheduler.bonusSessionReviewCount
                app.bonusSeenCardIds = []
                try? modelContext.save()
                syncCurrentCardIfNeeded(app: app)
            } label: {
                Text("Reforzar vocabulario")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 78)
            }
            .buttonStyle(.borderedProminent)
            .tint(FlashyTheme.accent(colorScheme: colorScheme))
            .accessibilityHint("Repasa tarjetas olvidadas y difíciles; hasta \(n) repasos.")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func reverseModeRow(app: AppState, card: Card) -> some View {
        let accent = FlashyTheme.accent(colorScheme: colorScheme)
        return HStack(alignment: .center, spacing: 0) {
            Button {
                openDictionary(for: card)
            } label: {
                Image(systemName: "book")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .tint(accent)
            .clipShape(Circle())
            .accessibilityLabel("Diccionario")
            .accessibilityHint("Abre el diccionario.")

            Button {
                copyAndTranslate(card: card)
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .tint(accent)
            .clipShape(Circle())
            .accessibilityLabel("Copiar y traducir")
            .accessibilityHint("Copia el texto en español y abre Traductor de Google.")

            Spacer(minLength: 8)

            Button {
                cardToDelete = card
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .clipShape(Circle())
            .accessibilityLabel("Eliminar tarjeta")
            .accessibilityHint("Elimina esta tarjeta de la colección.")
        }
        .padding(.horizontal, -16)
        .padding(.top, 34)
        .padding(.bottom, 8)
    }

    private func copyAndTranslate(card: Card) {
        UIPasteboard.general.string = card.front

        let gtURL = URL(string: "googletranslate://")!
        if UIApplication.shared.canOpenURL(gtURL) {
            UIApplication.shared.open(gtURL)
        } else {
            var components = URLComponents(string: "https://translate.google.com/")
            components?.queryItems = [
                URLQueryItem(name: "text", value: card.front),
                URLQueryItem(name: "sl", value: "es"),
                URLQueryItem(name: "tl", value: "en"),
            ]
            if let url = components?.url {
                UIApplication.shared.open(url)
            }
        }

        showToast("Copiado")
    }

    private func openDictionary(for card: Card) {
        lookupWord = DictionaryLookupItem(
            suggestedWords: dictionaryMenuWords(from: card.front)
        )
    }

    private func dictionaryMenuWords(from text: String) -> [String] {
        var seen: Set<String> = []
        return text
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .compactMap { raw -> String? in
                let word = DictionaryService.normalize(String(raw))
                guard word.count > 1, !commonDictionarySkipWords.contains(word), !seen.contains(word) else {
                    return nil
                }
                seen.insert(word)
                return word
            }
    }

    private var commonDictionarySkipWords: Set<String> {
        [
            "a", "al", "algo", "ante", "aquel", "aquella", "aquellas", "aquello", "aquellos",
            "como", "con", "cual", "cuando", "de", "del", "desde", "donde", "e", "el", "ella",
            "él",
            "ellas", "ello", "ellos", "en", "entre", "era", "eran", "eres", "es", "esa", "esas",
            "ese", "eso", "esos", "esta", "estaba", "estaban", "estado", "estamos", "estan",
            "están", "estar", "estas", "este", "esto", "estos", "estoy", "ha", "han", "hasta", "hay",
            "he", "la", "las", "le", "les", "lo", "los", "mas", "más", "me", "mi", "mí", "mis", "muy", "no",
            "nos", "o", "para", "pero", "por", "que", "se", "ser", "si", "sin", "son", "soy",
            "sí", "su", "sus", "te", "tu", "tú", "tus", "un", "una", "unas", "uno", "unos", "y", "yo"
        ]
    }

    private func performDelete(card: Card, app: AppState) {
        modelContext.delete(card)
        var seen = app.bonusSeenCardIds
        seen.removeAll { $0 == card.id }
        app.bonusSeenCardIds = seen
        if app.currentCardId == card.id {
            app.currentCardId = nil
        }
        clearUndoStack()
        try? modelContext.save()
        syncCurrentCardIfNeeded(app: app)
    }

    private func remainingDiscCount(hasStrict: Bool, app: AppState) -> Int? {
        guard !cards.isEmpty else { return nil }
        let strictCount = hasStrict
            ? CardScheduler.scheduledStrictQueueCount(cards: cards, appState: app)
            : 0
        let total = strictCount + app.effectiveBonusReviewBudget
        return total > 0 ? total : nil
    }

    private func headerRow(app: AppState, hasStrict: Bool) -> some View {
        let accent = FlashyTheme.accent(colorScheme: colorScheme)
        let bonusMode = !hasStrict && app.effectiveBonusReviewBudget > 0
        let discAccessibility: String = {
            if let n = remainingDiscCount(hasStrict: hasStrict, app: app) {
                return bonusMode
                    ? "Repaso de refuerzo: quedan \(n)"
                    : "\(n) para hoy"
            }
            return ""
        }()
        return HStack(alignment: .center) {
            if let count = remainingDiscCount(hasStrict: hasStrict, app: app) {
                Button {
                    showUpcoming = true
                } label: {
                    Text("\(count)")
                        .font(StudyChromeTypography.countFont)
                        .foregroundStyle(Color.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(accent.opacity(colorScheme == .dark ? 0.92 : 0.88))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(accent.opacity(0.92), lineWidth: 1.25)
                        )
                }
                .buttonStyle(.plain)
                .scaleEffect(countBumpScale)
                .onChange(of: count) { old, new in
                    guard new > old, !reduceMotion else { return }
                    countBumpScale = 1.22
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.38)) {
                        countBumpScale = 1.0
                    }
                }
                .accessibilityLabel(discAccessibility)
                .accessibilityHint("Abre próximos repasos y pronóstico.")
            } else {
                Color.clear
                    .frame(minWidth: 44, minHeight: 36)
                    .accessibilityHidden(true)
            }
            Spacer()
            HStack(spacing: 8) {
                reverseModeHeaderButton(app: app, accent: accent)

                Button {
                    showStats = true
                } label: {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .tint(accent)

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .tint(accent)
            }
        }
        .padding(.top, 8)
        .frame(height: 44)
    }

    @ViewBuilder
    private func bottomArrowsRow(active: Card?, app: AppState) -> some View {
        if let active {
            HStack(spacing: 12) {
                swipeHintBox(
                    title: "Otra vez",
                    systemImage: "arrow.left",
                    color: FlashyTheme.swipeRed
                ) {
                    commit(active: active, grade: .again, app: app)
                }
                swipeHintBox(
                    title: "Bien",
                    systemImage: "arrow.right",
                    color: FlashyTheme.swipeGreen
                ) {
                    commit(active: active, grade: .good, app: app)
                }
            }
            .padding(.bottom, 8)
            .background(alignment: .top) {
                if undoAvailable {
                    undoButton(app: app)
                        .fixedSize()
                        .offset(y: -(StudyChromeTypography.capsuleRowHeight + 14))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: undoAvailable)
        }
    }

    private func undoButton(app: AppState) -> some View {
        let accent = FlashyTheme.accent(colorScheme: colorScheme)
        return Button {
            undoLast(app: app)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(StudyChromeTypography.iconFont)
                Text("Atrás")
                    .font(StudyChromeTypography.labelFont)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, StudyChromeTypography.pillHPadding)
            .padding(.vertical, StudyChromeTypography.pillVPadding)
            .frame(height: StudyChromeTypography.capsuleRowHeight)
            .background(accent.opacity(0.1))
            .overlay(
                Capsule()
                    .strokeBorder(accent.opacity(0.42), lineWidth: 1.5)
            )
            .clipShape(Capsule())
            .studyPillShadowBackdrop(colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Atrás")
        .accessibilityHint(Text("Retroceder un repaso; cancela la última clasificación si fue un error."))
    }

    private func clearUndoStack() {
        undoStack.removeAll()
        undoStackAnchoredDay = nil
    }

    /// Clears stacked undos after local midnight (anchored day differs from today).
    private func invalidateUndoStackIfAnchoredDayMismatch() {
        let today = DateRollover.startOfLocalDay(for: Date())
        if let anchor = undoStackAnchoredDay, anchor != today {
            clearUndoStack()
        }
    }

    private func enqueueUndoSnapshot(_ snap: ReviewSnapshot) {
        if undoStack.count >= undoCap {
            undoStack.removeFirst()
        }
        if undoStack.isEmpty {
            undoStackAnchoredDay = DateRollover.startOfLocalDay(for: Date())
        }
        undoStack.append(snap)
    }

    private func swipeHintBox(title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(StudyChromeTypography.iconFont)
                Text(title)
                    .font(StudyChromeTypography.labelFont)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(color.opacity(colorScheme == .dark ? 0.9 : 0.82))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(color.opacity(colorScheme == .dark ? 0.95 : 0.88), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(flyOffset != .zero)
        .accessibilityHint("Repasa la tarjeta actual y avanza a la siguiente.")
    }

    @ViewBuilder
    private func reverseModeHeaderButton(app: AppState, accent: Color) -> some View {
        let isOn = app.effectiveReverseModeEnabled
        let label = Button {
            app.reverseModeEnabled = !isOn
            isFlipped = false
            try? modelContext.save()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .tint(accent)
        .clipShape(Circle())
        .accessibilityLabel("Modo reverso")
        .accessibilityValue(isOn ? "Activado" : "Desactivado")
        .accessibilityHint("Activa o desactiva mostrar primero el reverso de la tarjeta.")

        if isOn {
            label.buttonStyle(.borderedProminent)
        } else {
            label.buttonStyle(.bordered)
        }
    }

    private func syncCurrentCardIfNeeded(app: AppState) {
        let now = Date()
        let hasStrict = CardScheduler.hasScheduledStudyWork(cards: cards, appState: app, now: now)
        let allowPick = hasStrict || app.effectiveBonusReviewBudget > 0
        if !allowPick {
            if app.currentCardId != nil {
                app.currentCardId = nil
                try? modelContext.save()
            }
            return
        }

        if app.currentCardId == nil {
            if let pick = CardScheduler.pickStudyCard(cards: cards, appState: app, now: now) {
                app.currentCardId = pick.card.id
                CardScheduler.beginDisplaying(
                    pick.card,
                    appState: app,
                    countTowardDailyNewCap: pick.countNewTowardDailyCap
                )
                try? modelContext.save()
            } else if !hasStrict {
                app.bonusReviewBudget = 0
                app.bonusSeenCardIds = []
                try? modelContext.save()
            }
        } else if let id = app.currentCardId,
                  let c = cards.first(where: { $0.id == id }) {
            CardScheduler.beginDisplaying(
                c,
                appState: app,
                countTowardDailyNewCap: CardScheduler.shouldApplyNewCardDailyPacingWhenShowing(
                    card: c,
                    appState: app
                )
            )
        }
    }

    private func commit(
        active: Card,
        grade: Grade,
        app: AppState,
        releaseOffset: CGSize = .zero,
        releaseRotation: Double = 0
    ) {
        invalidateUndoStackIfAnchoredDayMismatch()
        enqueueUndoSnapshot(
            ReviewSnapshot(
                cardId: active.id,
                grade: grade,
                wasFlipped: isFlipped,
                releaseOffset: releaseOffset,
                releaseRotation: releaseRotation,
                difficulty: active.difficulty,
                stability: active.stability,
                lapses: active.lapses,
                reps: active.reps,
                state: active.state,
                lastReviewedAt: active.lastReviewedAt,
                nextDueAt: active.nextDueAt,
                firstShownForPacingAt: active.firstShownForPacingAt,
                historyJSON: active.historyJSON,
                prevCurrentCardId: app.currentCardId,
                prevBonusBudget: app.effectiveBonusReviewBudget,
                prevBonusSeenIds: app.bonusSeenCardIds,
                prevNewCardsIntroducedToday: app.newCardsIntroducedToday,
                prevNewCardsIntroducedDay: app.newCardsIntroducedDay
            )
        )

        let screenW = UIScreen.main.bounds.width
        let dir: CGFloat = grade == .good ? 1 : -1
        if app.hapticsEnabled {
            let gen = UINotificationFeedbackGenerator()
            gen.notificationOccurred(grade == .good ? .success : .warning)
        }

        flashColor = grade == .good ? FlashyTheme.flashTeal : FlashyTheme.flashRed
        withAnimation(.easeOut(duration: 0.25)) {
            flashOpacity = 0.35
        }

        flyOffset = releaseOffset
        flyRotation = releaseRotation
        withAnimation(.easeOut(duration: 0.3)) {
            flyOffset = CGSize(
                width: releaseOffset.width + dir * (screenW + 50),
                height: releaseOffset.height
            )
            flyRotation = dir > 0 ? 20 : -20
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            FSRS.applyReview(to: active, grade: grade, now: Date(), retention: app.retentionTarget)
            let bonusBefore = app.effectiveBonusReviewBudget
            if bonusBefore > 0 {
                var seen = app.bonusSeenCardIds
                if !seen.contains(active.id) {
                    seen.append(active.id)
                    app.bonusSeenCardIds = seen
                }
                app.bonusReviewBudget = bonusBefore - 1
            }
            flyOffset = .zero
            flyRotation = 0
            isFlipped = false
            let refreshed = (try? modelContext.fetch(FetchDescriptor<Card>())) ?? []
            let now = Date()
            let hasStrict = CardScheduler.hasScheduledStudyWork(cards: refreshed, appState: app, now: now)
            let allowNext = hasStrict || app.effectiveBonusReviewBudget > 0
            if allowNext, let pick = CardScheduler.pickStudyCard(
                cards: refreshed,
                appState: app,
                now: now,
                respectCurrentCard: false
            ) {
                app.currentCardId = pick.card.id
                CardScheduler.beginDisplaying(
                    pick.card,
                    appState: app,
                    countTowardDailyNewCap: pick.countNewTowardDailyCap
                )
            } else if !hasStrict {
                app.currentCardId = nil
                app.bonusReviewBudget = 0
                app.bonusSeenCardIds = []
            } else {
                app.currentCardId = nil
            }
            withAnimation(.easeOut(duration: 0.2)) {
                flashOpacity = 0
            }
            try? modelContext.save()
        }
    }

    private func undoLast(app: AppState) {
        guard let snap = undoStack.popLast() else { return }
        if undoStack.isEmpty {
            undoStackAnchoredDay = nil
        }

        guard
            let allCards = try? modelContext.fetch(FetchDescriptor<Card>()),
            let card = allCards.first(where: { $0.id == snap.cardId })
        else {
            enqueueUndoSnapshot(snap)
            return
        }

        suppressNextFlipReset = true

        card.difficulty = snap.difficulty
        card.stability = snap.stability
        card.lapses = snap.lapses
        card.reps = snap.reps
        card.state = snap.state
        card.lastReviewedAt = snap.lastReviewedAt
        card.nextDueAt = snap.nextDueAt
        card.firstShownForPacingAt = snap.firstShownForPacingAt
        card.historyJSON = snap.historyJSON

        app.currentCardId = snap.prevCurrentCardId ?? snap.cardId
        app.bonusReviewBudget = snap.prevBonusBudget
        app.bonusSeenCardIds = snap.prevBonusSeenIds
        app.newCardsIntroducedToday = snap.prevNewCardsIntroducedToday
        app.newCardsIntroducedDay = snap.prevNewCardsIntroducedDay
        try? modelContext.save()

        isFlipped = snap.wasFlipped

        let dir: CGFloat = snap.grade == .good ? 1 : -1
        let screenW = UIScreen.main.bounds.width
        flyOffset = CGSize(
            width: snap.releaseOffset.width + dir * (screenW + 50),
            height: snap.releaseOffset.height
        )
        flyRotation = snap.grade == .good ? 20 : -20
        withAnimation(reduceMotion ? .linear(duration: 0.28) : .easeOut(duration: 0.3)) {
            flyOffset = .zero
            flyRotation = 0
        }
        if app.hapticsEnabled {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }

    private func importCSV(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let result = try CSVImporter.import(data: data, context: modelContext)
            var parts = ["Importadas \(result.inserted)", "actualizadas \(result.updated)", "omitidas \(result.skippedDuplicates) duplicadas"]
            if result.invalidRows > 0 {
                parts.append("\(result.invalidRows) omitidas (inválidas)")
            }
            clearUndoStack()
            showToast(parts.joined(separator: " · "))
        } catch {
            showToast("Error al importar")
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            toast = message
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                withAnimation {
                    toast = nil
                }
            }
        }
    }

    @MainActor
    private func bootstrapAppState() async {
        guard appStates.isEmpty else { return }
        let a = AppState()
        modelContext.insert(a)
        try? modelContext.save()
    }

    @MainActor
    private func runDifficultyRescueIfNeeded() async {
        guard let app = appState else { return }
        guard !app.effectiveDidRunDifficultyRescueV1 else { return }
        let allCards = (try? modelContext.fetch(FetchDescriptor<Card>())) ?? []
        _ = DifficultyRescue.runIfNeeded(cards: allCards, appState: app)
        try? modelContext.save()
    }
}

private extension View {
    /// Soft drop shadow behind floating capsule pills (Reverso, Atrás).
    func studyPillShadowBackdrop(colorScheme: ColorScheme) -> some View {
        let primaryOpacity = colorScheme == .dark ? 0.38 : 0.16
        let secondaryOpacity = colorScheme == .dark ? 0.22 : 0.07
        return compositingGroup()
            .shadow(color: .black.opacity(primaryOpacity), radius: 10, x: 0, y: 5)
            .shadow(color: .black.opacity(secondaryOpacity), radius: 3, x: 0, y: 2)
    }
}

enum StreakUpdater {
    static func update(app: AppState, now: Date) {
        let cal = Calendar.current
        if let last = app.lastSessionDate {
            if cal.isDate(last, inSameDayAs: now) { return }
            if cal.isDateInYesterday(last) {
                app.streakDays += 1
            } else {
                app.streakDays = 1
            }
        } else {
            app.streakDays = 1
        }
        app.lastSessionDate = now
    }
}
