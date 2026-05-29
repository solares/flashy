import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var appStates: [AppState]
    @Query private var cards: [Card]

    @State private var confirmReset = false
    @State private var exportSheetItem: ExportSheetItem?
    @State private var showExportError = false
    @State private var showImportPicker = false
    @State private var importFeedback: ImportFeedback?

    private var app: AppState? { appStates.first }

    var body: some View {
        NavigationStack {
            Form {
                if let app {
                    Section("Apariencia") {
                        Picker("Tema", selection: Binding(
                            get: { app.darkModeOverrideRaw ?? "system" },
                            set: { newValue in
                                app.darkModeOverrideRaw = newValue == "system" ? nil : newValue
                                try? modelContext.save()
                            }
                        )) {
                            Text("Sistema").tag("system")
                            Text("Oscuro").tag("dark")
                            Text("Claro").tag("light")
                        }
                        .pickerStyle(.segmented)
                    }

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

                    Section("Datos") {
                        Button("Exportar") {
                            exportBackup()
                        }
                        Button("Importar") {
                            showImportPicker = true
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
            .sheet(item: $exportSheetItem) { item in
                ShareSheet(items: [item.url])
            }
            .alert("No se pudo exportar", isPresented: $showExportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Inténtalo de nuevo.")
            }
            .fileImporter(
                isPresented: $showImportPicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                guard let app = appStates.first else { return }
                handleImportResult(result, app: app)
            }
            .alert(
                importFeedback?.title ?? "Importación",
                isPresented: Binding(
                    get: { importFeedback != nil },
                    set: { if !$0 { importFeedback = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    importFeedback = nil
                }
            } message: {
                Text(importFeedback?.message ?? "")
            }
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>, app: AppState) {
        switch result {
        case .failure:
            importFeedback = ImportFeedback(title: "Importación", message: "No se pudo abrir el archivo.")
        case .success(let urls):
            guard let url = urls.first else {
                importFeedback = ImportFeedback(title: "Importación", message: "No se eligió ningún archivo.")
                return
            }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                try BackupImporter.importBackup(data: data, modelContext: modelContext, appState: app)
                try modelContext.save()
                NotificationCenter.default.post(name: .flashyProgressReset, object: nil)
                importFeedback = ImportFeedback(
                    title: "Importación correcta",
                    message: "Se restauró la copia de seguridad. Las tarjetas y ajustes anteriores en este dispositivo fueron reemplazados."
                )
            } catch {
                importFeedback = ImportFeedback(
                    title: "No se pudo importar",
                    message: "El archivo no es una copia válida de Flashy."
                )
            }
        }
    }

    private func exportBackup() {
        guard let app else { return }
        do {
            let url = try BackupExporter.export(cards: cards, appState: app)
            exportSheetItem = ExportSheetItem(url: url)
        } catch {
            showExportError = true
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

// MARK: - Export share sheet

private struct ImportFeedback {
    let title: String
    let message: String
}

private struct ExportSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
