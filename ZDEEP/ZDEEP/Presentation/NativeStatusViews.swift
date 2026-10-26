import AVFoundation
import SwiftUI
import ThinkingOrbsKit

struct StartupLogoView: View {
    var body: some View {
        GeometryReader { geometry in
            Image("StartupLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: max(0, geometry.size.width - 2 * WelcomeStyle.pageHorizontalInset))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WelcomeStyle.background.ignoresSafeArea())
        .accessibilityLabel("ZDEEP")
    }
}

struct NativeLoadingView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ThinkingOrb(state: .connecting, size: .px64, theme: .light)
                .accessibilityHidden(true)
            Text("Загрузка")
                .font(WelcomeStyle.font(.medium, size: 16, relativeTo: .body))
                .foregroundStyle(WelcomeStyle.text)
            Spacer()
        }
        .padding(.horizontal, WelcomeStyle.pageHorizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WelcomeStyle.background.ignoresSafeArea())
    }
}

struct NativeErrorView: View {
    let presentation: NativeErrorPresentation
    let onRetry: () -> Void
    let onStartOver: () -> Void
    let onRebind: () -> Void
    @State private var pendingConfirmation: NativeErrorAction?

    private let confirmationMessage = "Привязка на этом телефоне будет удалена. Для входа потребуется снова отсканировать QR-код машины"

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 300)
                    errorContent
                        .padding(.bottom, 40)
                    actions
                }
                .padding(.horizontal, WelcomeStyle.pageHorizontalInset)
                .padding(.top, 16)
                .padding(.bottom, WelcomeStyle.pageBottomInset)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .bottom)
            }
            .scrollIndicators(.hidden)
            .background(WelcomeStyle.background)
        }
        .background(WelcomeStyle.background.ignoresSafeArea())
        .accessibilityIdentifier("nativeErrorScreen")
        .alert("Подтвердите действие", isPresented: confirmationIsPresented) {
            Button("Отмена", role: .cancel) { pendingConfirmation = nil }
            Button(confirmationTitle, role: .destructive) {
                if pendingConfirmation == .rebind { onRebind() }
                else { onStartOver() }
                pendingConfirmation = nil
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var errorContent: some View {
        VStack(alignment: .center, spacing: 0) {
            Text("Ошибка подключения")
                .font(WelcomeStyle.font(.bold, size: 24, relativeTo: .title2))
                .multilineTextAlignment(.center)
                .foregroundStyle(WelcomeStyle.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(presentation.userExplanation)
                .font(WelcomeStyle.font(.regular, size: 14, relativeTo: .subheadline))
                .multilineTextAlignment(.center)
                .foregroundStyle(WelcomeStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 20)

            VStack(alignment: .center, spacing: 4) {
                Text(presentation.diagnosticLine)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("diagnostic-line")
                if let status = presentation.failure.httpStatus {
                    Text("HTTP \(status)")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("http-status")
                }
                Text(presentation.appVersion)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("app-version")
            }
            .font(.custom("JetBrainsMono-Regular", size: 12, relativeTo: .caption))
            .foregroundStyle(WelcomeStyle.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 24)

            Text("Закройте и снова откройте приложение")
                .font(WelcomeStyle.font(.medium, size: 14, relativeTo: .subheadline))
                .foregroundStyle(WelcomeStyle.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Приложите скриншот при обращении в поддержку")
                .font(WelcomeStyle.font(.regular, size: 12, relativeTo: .caption))
                .foregroundStyle(WelcomeStyle.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: WelcomeStyle.buttonGap) {
            ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, action in
                actionButton(action)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: NativeErrorAction) -> some View {
        switch action {
        case .retry:
            NativeActionButton(title: "Повторить", isPrimary: true, action: onRetry)
        case .startOver:
            NativeActionButton(title: "Начать сначала", isPrimary: true, action: onStartOver)
        case .reset:
            NativeActionButton(title: "Сбросить авторизацию", isPrimary: false) {
                pendingConfirmation = .reset
            }
        case .rebind:
            NativeActionButton(title: "Отвязать автомобиль", isPrimary: false) {
                pendingConfirmation = .rebind
            }
        }
    }

    private var confirmationTitle: String {
        pendingConfirmation == .rebind ? "Отвязать автомобиль" : "Сбросить авторизацию"
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }
}

struct CameraPermissionView: View {
    let status: AVAuthorizationStatus
    let onSettings: () -> Void
    let onBack: () -> Void

    private var isDenied: Bool { status == .denied }
    private var isRestricted: Bool { status == .restricted }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 12) {
                Text(title)
                    .font(WelcomeStyle.font(.bold, size: 24, relativeTo: .title2))
                    .foregroundStyle(WelcomeStyle.text)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(WelcomeStyle.font(.regular, size: 16, relativeTo: .body))
                    .foregroundStyle(WelcomeStyle.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isDenied {
                NativeActionButton(title: "Открыть настройки", isPrimary: true, action: onSettings)
            }
            NativeActionButton(title: "Назад", isPrimary: false, action: onBack)
            Spacer()
        }
        .padding(.horizontal, WelcomeStyle.pageHorizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WelcomeStyle.background.ignoresSafeArea())
    }

    private var title: String {
        if isDenied { return "Доступ к камере запрещён" }
        if isRestricted { return "Доступ к камере ограничен" }
        return "Доступ к камере"
    }

    private var message: String {
        if isRestricted {
            return "Изменить это ограничение можно в настройках устройства или с помощью администратора."
        }
        return "Разрешите доступ к камере, чтобы отсканировать QR-код машины."
    }
}

private struct NativeActionButton: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WelcomeStyle.font(.semibold, size: 16, relativeTo: .body))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(isPrimary ? WelcomeStyle.white : WelcomeStyle.text)
                .padding(.vertical, WelcomeStyle.buttonVerticalPadding)
                .padding(.horizontal, WelcomeStyle.buttonHorizontalPadding)
                .frame(maxWidth: .infinity)
                .background(
                    isPrimary ? WelcomeStyle.text : WelcomeStyle.white,
                    in: RoundedRectangle(cornerRadius: WelcomeStyle.buttonCornerRadius)
                )
                .contentShape(RoundedRectangle(cornerRadius: WelcomeStyle.buttonCornerRadius))
        }
        .buttonStyle(.plain)
    }
}
