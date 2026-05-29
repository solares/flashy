import SwiftUI

struct DictionaryLookupItem: Identifiable {
    let id = UUID()
    let word: String
}

struct DictionaryView: View {
    let initialWord: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var path: [String] = []
    @State private var dragOffset: CGFloat = 0

    private let dismissDragThreshold: CGFloat = 160

    var body: some View {
        NavigationStack(path: $path) {
            DictionaryWordScreen(word: initialWord, onTapWord: { path.append($0) })
                .navigationDestination(for: String.self) { word in
                    DictionaryWordScreen(word: word, onTapWord: { path.append($0) })
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationBarBackButtonHidden(true)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
        }
        .offset(y: max(0, dragOffset))
        .overlay(alignment: .top) {
            dictionaryHeader
        }
        .background(dictionaryBackground.ignoresSafeArea())
    }

    private var dictionaryBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.97, green: 0.97, blue: 0.955)
    }

    private var dictionaryHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 40, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 8)

            HStack {
                if !path.isEmpty {
                    Button {
                        path.removeLast()
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.system(size: 39))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Atrás")
                } else {
                    Color.clear
                        .frame(width: 34, height: 34)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 39))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar diccionario")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    let isMostlyVertical = abs(value.translation.height) > abs(value.translation.width)
                    if isMostlyVertical, value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    let isMostlyVertical = abs(value.translation.height) > abs(value.translation.width)
                    if isMostlyVertical, value.translation.height > dismissDragThreshold {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
}

// MARK: - Word screen

private struct DictionaryWordScreen: View {
    let word: String
    let onTapWord: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private enum LoadState {
        case loading
        case loaded(RAEEntry)
        case failed(String)
    }

    @State private var loadState: LoadState = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch loadState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                case .loaded(let entry):
                    entryContent(entry)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("Búsqueda: \(DictionaryService.normalize(word))")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 72)
            .padding(.bottom, 32)
        }
        .task(id: word) {
            await fetchWord()
        }
    }

    @ViewBuilder
    private func entryContent(_ entry: RAEEntry) -> some View {
        Text(entry.word)
            .font(.system(size: 55, weight: .bold, design: .rounded))
            .foregroundStyle(FlashyTheme.cardFacePrimaryText(colorSchemeContrast: colorSchemeContrast))
            .frame(maxWidth: .infinity, alignment: .leading)

        ForEach(Array(entry.meanings.enumerated()), id: \.offset) { _, meaning in
            if let origin = meaning.origin {
                Text(origin.raw)
                    .font(.system(size: 25, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
                    .italic()
            }

            ForEach(Array(meaning.senses.enumerated()), id: \.offset) { _, sense in
                senseBlock(sense)
            }
        }
    }

    @ViewBuilder
    private func senseBlock(_ sense: RAESense) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(sense.meaningNumber).")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                if !sense.category.isEmpty {
                    Text(sense.category)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            TappableWordText(
                text: sense.description,
                font: .system(size: 33, weight: .medium, design: .rounded),
                foregroundColor: FlashyTheme.cardFacePrimaryText(colorSchemeContrast: colorSchemeContrast),
                accentColor: FlashyTheme.accent(colorScheme: colorScheme),
                spacing: 5,
                lineSpacing: 8,
                onTapWord: onTapWord
            )

            if let synonyms = sense.synonyms, !synonyms.isEmpty {
                synonymRow(title: "Sin.", words: synonyms)
            }

            if let crossRefs = sense.crossReferences, !crossRefs.isEmpty {
                synonymRow(title: "Véase", words: crossRefs)
            }

            if let antonyms = sense.antonyms, !antonyms.isEmpty {
                synonymRow(title: "Ant.", words: antonyms)
            }
        }
    }

    @ViewBuilder
    private func synonymRow(title: String, words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title):")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.secondary)
            FlowSynonymRow(words: words, onTapWord: onTapWord)
        }
    }

    private func fetchWord() async {
        loadState = .loading
        do {
            let entry = try await DictionaryService.lookup(word)
            loadState = .loaded(entry)
        } catch {
            #if DEBUG
            print("[DictionaryView] lookup failed word='\(word)' normalized='\(DictionaryService.normalize(word))' error='\(error)'")
            #endif
            loadState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Synonym row

private struct FlowSynonymRow: View {
    let words: [String]
    let onTapWord: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Button {
                    onTapWord(DictionaryService.normalize(word))
                } label: {
                    Text(word)
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .foregroundStyle(FlashyTheme.accent(colorScheme: colorScheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(FlashyTheme.accent(colorScheme: colorScheme).opacity(0.11))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
