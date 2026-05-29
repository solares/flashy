import SwiftUI

struct CardStack: View {
    let stack: [Card]
    let cardWidth: CGFloat
    let hapticsEnabled: Bool
    let reduceMotion: Bool
    let colorSchemeContrast: ColorSchemeContrast
    let reverseModeEnabled: Bool

    @Binding var isFlipped: Bool
    @Binding var flyOffset: CGSize
    @Binding var flyRotation: Double

    var onCommit: (Grade, CGSize, Double) -> Void

    var body: some View {
        let visible = Array(stack.prefix(CardScheduler.visibleStackSlots))
        ZStack {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, card in
                let isActive = index == 0
                CardView(
                    card: card,
                    cardWidth: cardWidth,
                    stackDepth: index,
                    isActive: isActive,
                    hapticsEnabled: hapticsEnabled,
                    reduceMotion: reduceMotion,
                    colorSchemeContrast: colorSchemeContrast,
                    reverseModeEnabled: reverseModeEnabled,
                    isFlipped: isActive ? $isFlipped : .constant(false),
                    onCommit: { grade, offset, rotation in
                        if isActive {
                            onCommit(grade, offset, rotation)
                        }
                    }
                )
                .frame(maxWidth: 340)
                .scaleEffect(stackPeekScale(depth: index))
                .offset(y: index == 0 ? 0 : stackPeekOffsetY(depth: index))
                .offset(x: isActive ? flyOffset.width : 0, y: isActive ? flyOffset.height : 0)
                .rotationEffect(.degrees(isActive ? flyRotation : 0))
                .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85), value: stackSignature(stack))
                .zIndex(Double(visible.count - index))
                .allowsHitTesting(isActive)
            }
        }
        .frame(maxWidth: 340)
    }

    private func stackPeekScale(depth: Int) -> CGFloat {
        switch depth {
        case 0: return 1
        case 1: return 0.97
        case 2: return 0.94
        case 3: return 0.915
        case 4: return 0.895
        default: return 0.875
        }
    }

    private func stackPeekOffsetY(depth: Int) -> CGFloat {
        CGFloat(depth) * 11
    }

    /// Stable key for stack animations (order + ids only — avoids churn from non-stack state updates).
    private func stackSignature(_ cards: [Card]) -> String {
        Array(cards.prefix(CardScheduler.visibleStackSlots)).map(\.id).joined(separator: "|")
    }
}
