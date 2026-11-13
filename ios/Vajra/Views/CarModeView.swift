import SwiftUI
import UIKit

/// Режим «Авто»: весь экран — красная кнопка без текста, +1 — обычным тапом в любое место (без удержания 3 с).
/// Сверху — большая кнопка выхода. Тапы чаще раза в секунду не считаются (`AppModel.carTapCooldown`).
/// Экран в этом режиме не гаснет; ачивка, если случилась, покажется после выхода.
struct CarModeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var flash = false
    @State private var successGen = UINotificationFeedbackGenerator()

    var body: some View {
        VStack(spacing: 0) {
            Button { model.carMode = false } label: {
                HStack(spacing: 10) {
                    Image(systemName: "xmark").font(.system(size: 20, weight: .bold))
                    Text("Выйти из режима «Авто»").font(.system(size: 18, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 76)
                .background(Color.black.opacity(0.35))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Выйти из режима Авто")
            .accessibilityIdentifier("carExit")

            ZStack {
                Palette.crimson
                Color.white.opacity(flash ? 0.45 : 0)
            }
            .contentShape(Rectangle())
            // DragGesture с нулевой дистанцией: засчитывает любое касание, даже если палец съехал на кочке
            .gesture(DragGesture(minimumDistance: 0).onEnded { _ in tap() })
            .accessibilityElement()
            .accessibilityLabel("Плюс один")
            .accessibilityValue("за день \(model.total)")
            .accessibilityIdentifier("carSurface")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
        }
        .background(Palette.crimson.ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { successGen.prepare() }
    }

    private func tap() {
        guard model.carTap() else { return }
        successGen.notificationOccurred(.success)
        successGen.prepare()
        flash = true
        withAnimation(.easeOut(duration: 0.4)) { flash = false }
    }
}

/// Кнопка входа в режим «Авто» (шапка трекера и горизонтальный экран).
struct CarModeButton: View {
    @EnvironmentObject private var model: AppModel
    var size: CGFloat = 15
    var body: some View {
        Button { model.carMode = true } label: {
            Image(systemName: "car.fill").font(.system(size: size))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Режим Авто: плюс один тапом")
        .accessibilityIdentifier("carEnter")
    }
}
