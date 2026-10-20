import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch auth.state {
            case .checking:
                ProgressView().tint(Palette.mint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.bg.ignoresSafeArea())
            case .signedOut:
                LoginView()
            case .signedIn:
                MainView()
            }
        }
        .onChange(of: auth.state) { _, st in
            if st == .signedIn { Task { await model.refresh(); await model.refreshBank(force: true) } }   // вход подтверждён — синк сразу
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            GemShapeView(size: 64).padding(.bottom, 14)
            Text("Ваджра-трекер")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Palette.text)
                .padding(.bottom, 4)
            Text("вход паролем Life")
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
                .padding(.bottom, 32)

            VStack(spacing: 10) {
                SecureField("", text: $password, prompt: Text("пароль").foregroundColor(Palette.text3))
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.text)
                    .textContentType(.password)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Palette.crimson.opacity(0.5) : Palette.border, lineWidth: 1))

                Button(action: submit) {
                    Group {
                        if busy { ProgressView().tint(.white) } else { Text("Войти").font(.system(size: 15, weight: .semibold)) }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Palette.mint, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(busy || password.isEmpty)
                .opacity(password.isEmpty ? 0.6 : 1)
                .padding(.top, 4)

                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x991b1b))
                    .frame(minHeight: 18)

                Text("Отметки, сделанные без входа, сохранены на телефоне и дойдут на сервер после входа.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg.ignoresSafeArea())
        .onAppear { focused = !ProcessInfo.processInfo.arguments.contains("-noFocus") }
    }

    private func submit() {
        guard !busy, !password.isEmpty else { return }
        busy = true
        error = ""
        let pw = password
        Task {
            let err = await auth.signIn(password: pw)
            busy = false
            if let err { error = err } else {
                password = ""
            }
        }
    }
}
