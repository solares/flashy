import SwiftUI

struct DictionaryLookupItem: Identifiable {
    let id = UUID()
    let suggestedWords: [String]
}

struct DictionaryView: View {
    let suggestedWords: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var path: [String] = []
    @State private var dragOffset: CGFloat = 0
    @State private var searchText = ""
    @State private var activeWord: String?
    @State private var isSearchMode = true
    @FocusState private var searchFocused: Bool

    private let dismissDragThreshold: CGFloat = 160

    var body: some View {
        Group {
            if isSearchMode {
                searchPage
            } else if let word = activeWord {
                NavigationStack(path: $path) {
                    DictionaryWordScreen(word: word, onTapWord: { path.append($0) })
                        .navigationDestination(for: String.self) { tappedWord in
                            DictionaryWordScreen(word: tappedWord, onTapWord: { path.append($0) })
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationBarBackButtonHidden(true)
                        }
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationBarBackButtonHidden(true)
                }
                .id(word)
            }
        }
        .offset(y: max(0, dragOffset))
        .overlay(alignment: .top) {
            if isSearchMode {
                searchModeHeader
            } else {
                dictionaryPageHeader
            }
        }
        .background(dictionaryBackground.ignoresSafeArea())
        .onAppear {
            focusSearchFieldIfNeeded()
        }
        .onChange(of: isSearchMode) { _, newValue in
            if newValue {
                focusSearchFieldIfNeeded()
            } else {
                searchFocused = false
            }
        }
    }

    private var dictionaryBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.97, green: 0.97, blue: 0.955)
    }

    private var searchTextColor: Color {
        colorScheme == .dark
            ? Color(red: 0.96, green: 0.96, blue: 0.94)
            : FlashyTheme.cardFacePrimaryText(colorSchemeContrast: colorSchemeContrast)
    }

    // MARK: - Search page

    private var searchPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TextField("Buscar palabra…", text: $searchText)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        performLookup(searchText)
                    }
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .foregroundStyle(searchTextColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Buscar palabra")

                if !suggestedWords.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Palabras de esta tarjeta")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)

                        FlowSynonymRow(words: suggestedWords) { word in
                            performLookup(word)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 88)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Headers

    private var dragHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 40, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }

    private var searchModeHeader: some View {
        VStack(spacing: 0) {
            dragHandle

            HStack {
                Color.clear
                    .frame(width: 39, height: 39)

                Spacer()

                closeButton
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
        .contentShape(Rectangle())
        .gesture(dismissDragGesture)
    }

    private var dictionaryPageHeader: some View {
        VStack(spacing: 0) {
            dragHandle

            HStack {
                if !path.isEmpty {
                    backButton
                } else {
                    searchButton
                }

                Spacer()

                closeButton
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
        .contentShape(Rectangle())
        .gesture(dismissDragGesture)
    }

    private var backButton: some View {
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
    }

    private var searchButton: some View {
        Button {
            enterSearchMode()
        } label: {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 39))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Buscar")
        .accessibilityHint("Vuelve a la búsqueda del diccionario.")
    }

    private var closeButton: some View {
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

    private var dismissDragGesture: some Gesture {
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
    }

    // MARK: - Actions

    private func performLookup(_ raw: String) {
        let normalized = DictionaryService.normalize(raw)
        guard !normalized.isEmpty else { return }
        #if DEBUG
        print("[Dictionary] lookup word='\(raw)' normalized='\(normalized)'")
        #endif
        searchText = normalized
        activeWord = normalized
        path.removeAll()
        isSearchMode = false
        searchFocused = false
    }

    private func enterSearchMode() {
        path.removeAll()
        isSearchMode = true
    }

    private func focusSearchFieldIfNeeded() {
        guard isSearchMode else { return }
        DispatchQueue.main.async {
            searchFocused = true
        }
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

    private var entryWordColor: Color {
        colorScheme == .dark
            ? .white
            : FlashyTheme.cardFacePrimaryText(colorSchemeContrast: colorSchemeContrast)
    }

    private var definitionTextColor: Color {
        colorScheme == .dark
            ? Color(red: 0.50, green: 0.72, blue: 0.96)
            : FlashyTheme.accent(colorScheme: colorScheme)
    }

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
            .foregroundStyle(entryWordColor)
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
                foregroundColor: definitionTextColor,
                accentColor: definitionTextColor,
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

    private var chipTextColor: Color {
        colorScheme == .dark
            ? Color(red: 0.94, green: 0.94, blue: 0.91)
            : .white
    }

    private var chipBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : FlashyTheme.accent(colorScheme: colorScheme).opacity(0.9)
    }

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Button {
                    onTapWord(DictionaryService.normalize(word))
                } label: {
                    Text(word)
                        .font(.system(size: 31, weight: .medium, design: .rounded))
                        .foregroundStyle(chipTextColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(chipBackground)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(word)
                .accessibilityHint("Buscar esta palabra en el diccionario.")
            }
        }
    }
}
