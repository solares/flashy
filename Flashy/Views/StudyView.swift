import SwiftUI
import SwiftData
import UIKit

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

    private var appState: AppState? { appStates.first }

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
        }
    }

    @ViewBuilder
    private func studyContent(app: AppState) -> some View {
        let now = Date()
        let queue = CardScheduler.studyQueue(cards: cards, appState: app, now: now)
        let dueNow = cards.filter { CardScheduler.isReviewDue($0, now: now) }.count
        let hasStrict = CardScheduler.hasScheduledStudyWork(cards: cards, appState: app, now: now)
        let isCaughtUp = !cards.isEmpty && !hasStrict && app.effectiveBonusReviewBudget == 0
        let headerLeft: String = {
            if dueNow > 0 { return "\(dueNow) para hoy" }
            if cards.isEmpty { return "Sin tarjetas" }
            if hasStrict { return "Listo para estudiar" }
            let bonus = app.effectiveBonusReviewBudget
            if bonus > 0 { return "Práctica extra · quedan \(bonus)" }
            return "Estás al día"
        }()

        ZStack {
            FlashyTheme.StudyBackgroundPreset.resolved(raw: app.studyBackgroundRaw)
                .fillColor(colorScheme: colorScheme)
                .ignoresSafeArea()

            flashColor.opacity(flashOpacity)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerRow(app: app, headerLeft: headerLeft)
                if queue.first != nil {
                    reverseModeToggle(app: app)
                }
                Spacer(minLength: 8)
                GeometryReader { geo in
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
                bottomArrowsRow(active: queue.first, app: app)
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
            if newId != nil {
                isFlipped = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .flashyOpenCSV)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            importCSV(from: url)
        }
        .sheet(isPresented: $showStats) {
            StatsView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            await MainActor.run {
                StreakUpdater.update(app: app, now: Date())
                try? modelContext.save()
            }
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
            Text("No hay nada pendiente ahora. Seguir estudiando agrega hasta \(n) repasos extra antes del próximo descanso.")
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
                Text("Seguir estudiando")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 78)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Empieza hasta \(n) repasos extra.")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func reverseModeToggle(app: AppState) -> some View {
        let isOn = app.effectiveReverseModeEnabled
        let tint = isOn ? FlashyTheme.swipeGreen : Color.secondary
        return Button {
            app.reverseModeEnabled = !isOn
            isFlipped = false
            try? modelContext.save()
        } label: {
            Label("Reverso", systemImage: "arrow.left.arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.white : tint)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(isOn ? tint.opacity(colorScheme == .dark ? 0.9 : 0.82) : tint.opacity(0.09))
                .overlay(
                    Capsule()
                        .strokeBorder(tint.opacity(isOn ? 0.85 : 0.35), lineWidth: 1.5)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 34)
        .padding(.bottom, 8)
        .accessibilityLabel("Modo reverso")
        .accessibilityValue(isOn ? "Activado" : "Desactivado")
        .accessibilityHint("Activa o desactiva mostrar primero el reverso de la tarjeta.")
    }

    private func headerRow(app: AppState, headerLeft: String) -> some View {
        HStack(alignment: .center) {
            Text(headerLeft)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 8) {
                Button {
                    toggleColorScheme(app: app)
                } label: {
                    Image(systemName: colorSchemeIcon(app: app))
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())

                Button {
                    showStats = true
                } label: {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
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
            .frame(height: 68)
            .padding(.bottom, 8)
        }
    }

    private func swipeHintBox(title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(color.opacity(colorScheme == .dark ? 0.18 : 0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(color.opacity(colorScheme == .dark ? 0.9 : 0.75), lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(flyOffset != .zero)
        .accessibilityHint("Repasa la tarjeta actual y avanza a la siguiente.")
    }

    private func colorSchemeIcon(app: AppState) -> String {
        switch app.darkModeOverrideRaw {
        case "dark": return "moon.fill"
        case "light": return "sun.max.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    private func toggleColorScheme(app: AppState) {
        switch app.darkModeOverrideRaw {
        case nil:
            app.darkModeOverrideRaw = "dark"
        case "dark":
            app.darkModeOverrideRaw = "light"
        default:
            app.darkModeOverrideRaw = nil
        }
        try? modelContext.save()
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
