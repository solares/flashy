import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Word frame tracking

struct WordFrameInfo: Equatable {
    let word: String
    let frame: CGRect
}

struct WordFramePreferenceKey: PreferenceKey {
    static var defaultValue: [WordFrameInfo] = []

    static func reduce(value: inout [WordFrameInfo], nextValue: () -> [WordFrameInfo]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = resolvedWidth(proposal.width)
        var rowWidth: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if rowWidth > 0, nextWidth > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }

            rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)

        return CGSize(width: min(totalWidth, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var row: [LayoutSubviews.Element] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var y = bounds.minY

        func placeRow() {
            guard !row.isEmpty else { return }
            var x = bounds.minX
            if alignment == .center {
                x += max(0, (bounds.width - rowWidth) / 2)
            }
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + lineSpacing
            row = []
            rowWidth = 0
            rowHeight = 0
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = row.isEmpty ? size.width : rowWidth + spacing + size.width
            if !row.isEmpty, nextWidth > bounds.width {
                placeRow()
            }
            if row.isEmpty {
                rowWidth = size.width
            } else {
                rowWidth += spacing + size.width
            }
            rowHeight = max(rowHeight, size.height)
            row.append(subview)
        }
        placeRow()
    }

    private func resolvedWidth(_ proposedWidth: CGFloat?) -> CGFloat {
        if let proposedWidth, proposedWidth.isFinite, proposedWidth > 0 {
            return proposedWidth
        }
        #if os(iOS)
        return min(max(UIScreen.main.bounds.width - 40, 240), 420)
        #else
        return 360
        #endif
    }
}

// MARK: - Tappable word text

struct TappableWordText: View {
    let text: String
    var font: Font = .body
    var foregroundColor: Color = .primary
    var accentColor: Color = .accentColor
    var coordinateSpace: String? = nil
    var interactive: Bool = true
    var centerAligned: Bool = false
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 6
    var onTapWord: ((String) -> Void)? = nil

    var body: some View {
        let tokens = Self.tokenize(text)
        FlowLayout(
            spacing: spacing,
            lineSpacing: lineSpacing,
            alignment: centerAligned ? .center : .leading
        ) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                if let lookupWord = token.lookupWord {
                    wordView(display: token.text, lookupWord: lookupWord)
                } else {
                    Text(token.text)
                        .font(font)
                        .foregroundStyle(foregroundColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: centerAligned ? .center : .leading)
    }

    @ViewBuilder
    private func wordView(display: String, lookupWord: String) -> some View {
        if interactive {
            Button {
                onTapWord?(lookupWord)
            } label: {
                Text(display)
                    .font(font)
                    .foregroundStyle(accentColor)
            }
            .buttonStyle(.plain)
            .background(wordFrameBackground(word: lookupWord))
        } else {
            Text(display)
                .font(font)
                .foregroundStyle(foregroundColor)
                .fixedSize()
                .background(wordFrameBackground(word: lookupWord))
        }
    }

    @ViewBuilder
    private func wordFrameBackground(word: String) -> some View {
        if let coordinateSpace {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: WordFramePreferenceKey.self,
                        value: [WordFrameInfo(
                            word: word,
                            frame: geo.frame(in: .named(coordinateSpace))
                        )]
                    )
            }
        } else {
            EmptyView()
        }
    }

    private struct Token {
        let text: String
        let lookupWord: String?
    }

    private static func tokenize(_ text: String) -> [Token] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map { rawChunk in
                let chunk = String(rawChunk)
                let lookup = DictionaryService.normalize(chunk)
                return Token(text: chunk, lookupWord: lookup.isEmpty ? nil : lookup)
            }
    }
}
