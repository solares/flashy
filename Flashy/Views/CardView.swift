import SwiftUI
import UIKit

struct CardView: View {
    let card: Card
    let cardWidth: CGFloat
    /// 0 = active (front), 1–2 = peek cards behind.
    let stackDepth: Int
    let isActive: Bool
    let hapticsEnabled: Bool
    let reduceMotion: Bool
    let colorSchemeContrast: ColorSchemeContrast
    let reverseModeEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    @Binding var isFlipped: Bool

    /// `(grade, releaseTranslation, releaseRotationDegrees)` — translation/rotation match the card at finger-up so the parent can continue the motion without snapping to center.
    var onCommit: (Grade, CGSize, Double) -> Void

    @State private var drag = CGSize.zero
    @State private var startedAt: Date?
    @State private var lastTranslationWidth: CGFloat = 0
    @State private var lastTick: Date?
    @State private var velocityPtsPerSec: CGFloat = 0
    @State private var isHolding = false
    @State private var holdStarted = false
    @State private var holdTask: Task<Void, Never>?

    private let commitDistance: CGFloat = 100
    private let velocityThreshold: CGFloat = 800

    private var cardSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.99, green: 0.99, blue: 0.995)
            : Color.white
    }

    private var cardBorderWidth: CGFloat {
        colorSchemeContrast == .increased ? 1.75 : 1.15
    }

    private var cardBorderColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(colorSchemeContrast == .increased ? 0.42 : 0.3)
        }
        return Color.black.opacity(colorSchemeContrast == .increased ? 0.3 : 0.2)
    }

    var body: some View {
        let clampedY = min(max(drag.height, -20), 20)
        let w = max(cardWidth, 200)
        let rotation = Double(drag.width / w) * 10
        let promptText = reverseModeEnabled ? card.back : card.front
        let answerText = reverseModeEnabled ? card.front : card.back
        let answerSecondaryText = reverseModeEnabled ? card.back : card.front

        Group {
            if reduceMotion {
                ZStack {
                    cardFace(text: answerText, secondary: answerSecondaryText)
                        .opacity(isFlipped ? 1 : 0)
                    cardFace(text: promptText, secondary: nil)
                        .opacity(isFlipped ? 0 : 1)
                }
            } else {
                ZStack {
                    cardFace(text: answerText, secondary: answerSecondaryText)
                        .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
                        .opacity(isFlipped ? 1 : 0)

                    cardFace(text: promptText, secondary: nil)
                        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                        .opacity(isFlipped ? 0 : 1)
                }
            }
        }
        .compositingGroup()
        .scaleEffect(isActive ? (isHolding ? 1.04 : 1) : 1)
        .offset(x: drag.width, y: clampedY)
        .rotationEffect(.degrees(rotation))
        .animation(reduceMotion ? .linear(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8), value: isFlipped)
        .cardStackShadows(
            colorScheme: colorScheme,
            stackDepth: stackDepth,
            isHolding: isHolding,
            isActive: isActive
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFlipped ? answerText : promptText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Voltear") {
            flipWithAnimation()
        }
        .accessibilityAction(named: "Lo sé") {
            onCommit(.good, .zero, 0)
        }
        .accessibilityAction(named: "Otra vez") {
            onCommit(.again, .zero, 0)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isActive else { return }
                    if startedAt == nil { startedAt = Date() }
                    updateVelocity(translationWidth: value.translation.width)
                    drag = value.translation

                    let moved = hypot(value.translation.width, value.translation.height)
                    if moved > 8 {
                        cancelHold()
                    } else {
                        scheduleHoldIfNeeded()
                    }
                }
                .onEnded { value in
                    guard isActive else { return }
                    cancelHold()

                    let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    let moved = hypot(value.translation.width, value.translation.height)

                    if moved < 8, duration < 0.3 {
                        flipWithAnimation()
                        resetDragState()
                        return
                    }

                    let predictedDelta = value.predictedEndTranslation.width - value.translation.width
                    let shouldCommitRight = value.translation.width > commitDistance || predictedDelta > velocityThreshold
                    let shouldCommitLeft = value.translation.width < -commitDistance || predictedDelta < -velocityThreshold

                    let w = max(cardWidth, 200)
                    let clampedY = min(max(value.translation.height, -20), 20)
                    let release = CGSize(width: value.translation.width, height: clampedY)
                    let releaseRotation = Double(release.width / w) * 10

                    if shouldCommitRight {
                        drag = .zero
                        onCommit(.good, release, releaseRotation)
                        resetGestureTracking()
                    } else if shouldCommitLeft {
                        drag = .zero
                        onCommit(.again, release, releaseRotation)
                        resetGestureTracking()
                    } else {
                        withAnimation(.interpolatingSpring(stiffness: 280, damping: 18)) {
                            drag = .zero
                        }
                        resetGestureTracking()
                    }
                }
        )
    }

    private func flipWithAnimation() {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) {
                isFlipped.toggle()
            }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                isFlipped.toggle()
            }
        }
    }

    private func scheduleHoldIfNeeded() {
        guard !holdStarted else { return }
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            beginHold()
        }
    }

    private func beginHold() {
        guard !holdStarted else { return }
        holdStarted = true
        isHolding = true
        if hapticsEnabled {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        if isHolding {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isHolding = false
            }
        } else {
            isHolding = false
        }
        holdStarted = false
    }

    private func resetDragState() {
        drag = .zero
        resetGestureTracking()
    }

    private func resetGestureTracking() {
        startedAt = nil
        lastTranslationWidth = 0
        lastTick = nil
        velocityPtsPerSec = 0
    }

    private func updateVelocity(translationWidth: CGFloat) {
        let now = Date()
        if let lastTick, lastTick != now {
            let dt = now.timeIntervalSince(lastTick)
            if dt > 0 {
                velocityPtsPerSec = CGFloat((translationWidth - lastTranslationWidth) / CGFloat(dt))
            }
        }
        lastTick = now
        lastTranslationWidth = translationWidth
    }

    @ViewBuilder
    private func cardFace(text: String, secondary: String?) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 38, weight: .medium, design: .rounded))
                .minimumScaleFactor(22.0 / 38.0)
                .lineSpacing(38 * 0.15)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .foregroundStyle(FlashyTheme.cardFacePrimaryText(colorSchemeContrast: colorSchemeContrast))

            if let secondary {
                Text(secondary)
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundStyle(FlashyTheme.cardFaceSecondaryText(colorSchemeContrast: colorSchemeContrast))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(20)
        .background(cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: cardBorderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Card shadows (opaque cards; no “see-through” while dragging)

private extension View {
    func cardStackShadows(
        colorScheme: ColorScheme,
        stackDepth: Int,
        isHolding: Bool,
        isActive: Bool
    ) -> some View {
        let isDark = colorScheme == .dark
        let d = min(stackDepth, 5)
        let lift: CGFloat = isActive ? (isHolding ? 22 : 18) : max(4, 16 - CGFloat(d) * 2)
        let spread: CGFloat = isActive ? (isHolding ? 20 : 16) : max(4, 14 - CGFloat(d) * 2)
        let yOff: CGFloat = isActive ? (isHolding ? 11 : 9) : max(3, 8 - CGFloat(d))
        let primaryOpacity = isDark ? 0.5 : 0.26
        let secondaryOpacity = isDark ? 0.28 : 0.12
        let holdBoost: CGFloat = isHolding ? 6 : 0

        return self
            .shadow(
                color: Color.black.opacity(primaryOpacity),
                radius: spread + holdBoost,
                x: 0,
                y: yOff + (isHolding ? 2 : 0)
            )
            .shadow(
                color: Color.black.opacity(secondaryOpacity),
                radius: lift * 0.45 + holdBoost * 0.5,
                x: 0,
                y: max(2, yOff * 0.45)
            )
    }
}
