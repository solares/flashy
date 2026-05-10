import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var appStates: [AppState]
    @Query private var cards: [Card]

    @State private var confirmReset = false

    private var app: AppState? { appStates.first }

    var body: some View {
        NavigationStack {
            Form {
                if let app {
                    Section("Estudio") {
                        Stepper(value: Binding(
                            get: { app.newCardsPerDay },
                            set: { app.newCardsPerDay = min(50, max(0, $0)) }
                        ), in: 0 ... 50) {
                            Text("Tarjetas nuevas por día: \(app.newCardsPerDay)")
                        }

                        Picker("Meta de retención", selection: Binding(
                            get: { app.retentionTarget },
                            set: { app.retentionTarget = $0 }
                        )) {
                            Text("85%").tag(0.85)
                            Text("90%").tag(0.9)
                            Text("95%").tag(0.95)
                        }
                        .pickerStyle(.segmented)

                        Toggle("Vibración", isOn: Binding(
                            get: { app.hapticsEnabled },
                            set: { app.hapticsEnabled = $0 }
                        ))

                        Picker("Fondo de estudio", selection: Binding(
                            get: { FlashyTheme.StudyBackgroundPreset.resolved(raw: app.studyBackgroundRaw) },
                            set: { app.studyBackgroundRaw = $0.rawValue }
                        )) {
                            ForEach(FlashyTheme.StudyBackgroundPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                    }

                    Section {
                        Button("Reiniciar progreso", role: .destructive) {
                            confirmReset = true
                        }
                    }

                    Section("Acerca de") {
                        LabeledContent("Versión") {
                            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        }
                        Text("Todos los datos permanecen en tu dispositivo")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Agrega aquí la URL del repositorio cuando sea público.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("Cargando", systemImage: "gearshape")
                }
            }
            .navigationTitle("Ajustes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .alert("¿Reiniciar todo el progreso?", isPresented: $confirmReset) {
                Button("Cancelar", role: .cancel) {}
                Button("Reiniciar", role: .destructive) {
                    resetProgress()
                }
            } message: {
                Text("Esto borra el estado de repaso, pero conserva el contenido de las tarjetas.")
            }
        }
    }

    private func resetProgress() {
        guard let app else { return }
        for c in cards {
            c.difficulty = 5
            c.stability = 0.1
            c.lapses = 0
            c.reps = 0
            c.state = .new
            c.lastReviewedAt = nil
            c.nextDueAt = Date()
            c.history = []
            c.firstShownForPacingAt = nil
        }
        app.currentCardId = nil
        app.newCardsIntroducedToday = 0
        app.newCardsIntroducedDay = DateRollover.startOfLocalDay(for: Date())
        try? modelContext.save()
        NotificationCenter.default.post(name: .flashyProgressReset, object: nil)
        dismiss()
    }
}
