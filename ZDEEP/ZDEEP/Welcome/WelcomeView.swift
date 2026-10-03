import SwiftUI

struct WelcomeView: View {
    @ScaledMetric(relativeTo: .body) private var bodyLineSpacing: CGFloat = 6.4

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    welcomeContent

                    Spacer(minLength: 0)

                    actions
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                .padding(.horizontal, WelcomeStyle.pageHorizontalInset)
                .padding(.bottom, WelcomeStyle.pageBottomInset)
            }
            .scrollIndicators(.hidden)
            .background(WelcomeStyle.background)
        }
        .background(WelcomeStyle.background.ignoresSafeArea())
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("WelcomeBolt")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(WelcomeStyle.text)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                Text("ZDEEP")
                    .font(WelcomeStyle.font(.bold, size: 20, relativeTo: .headline))
                    .tracking(-1)
                    .foregroundStyle(WelcomeStyle.text)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("ZDEEP")

            heroImage
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 0) {
                Text("Подключите ваш Zeekr")
                    .font(WelcomeStyle.font(.bold, size: 30, relativeTo: .largeTitle))
                    .tracking(-0.75)
                    .foregroundStyle(WelcomeStyle.text)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Отсканируйте QR-код на экране автомобиля, чтобы подключить Zeekr к ZDEEP")
                    .font(WelcomeStyle.font(.regular, size: 16, relativeTo: .body))
                    .lineSpacing(bodyLineSpacing)
                    .foregroundStyle(WelcomeStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 4)
            .padding(.top, 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroImage: some View {
        Image("WelcomeHero")
            .resizable()
            .aspectRatio(1672.0 / 941.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(WelcomeStyle.white)
            .clipShape(RoundedRectangle(cornerRadius: WelcomeStyle.heroCornerRadius))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .accessibilityLabel("Сканирование QR-кода в электромобиле")
    }

    private var actions: some View {
        VStack(spacing: WelcomeStyle.buttonGap) {
            Button(action: {}) {
                HStack(spacing: 12) {
                    Image("WelcomeScan")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(WelcomeStyle.white)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)

                    Text("Сканировать QR-код")
                        .font(WelcomeStyle.font(.semibold, size: 16, relativeTo: .body))
                        .tracking(-0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(WelcomeStyle.white)
                .padding(.vertical, WelcomeStyle.buttonVerticalPadding)
                .padding(.horizontal, WelcomeStyle.buttonHorizontalPadding)
                .frame(maxWidth: .infinity)
                .background(
                    WelcomeStyle.text,
                    in: RoundedRectangle(cornerRadius: WelcomeStyle.buttonCornerRadius)
                )
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                .contentShape(RoundedRectangle(cornerRadius: WelcomeStyle.buttonCornerRadius))
            }
            .buttonStyle(.plain)

            Button(action: {}) {
                HStack(spacing: 12) {
                    Image("WelcomeHelp")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(WelcomeStyle.text)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)

                    Text("Как подключить автомобиль")
                        .font(WelcomeStyle.font(.medium, size: 16, relativeTo: .body))
                        .tracking(-0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(WelcomeStyle.text)
                .padding(.vertical, WelcomeStyle.buttonVerticalPadding)
                .padding(.horizontal, WelcomeStyle.buttonHorizontalPadding)
                .frame(maxWidth: .infinity)
                .background(
                    WelcomeStyle.white,
                    in: RoundedRectangle(cornerRadius: WelcomeStyle.buttonCornerRadius)
                )
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                .contentShape(RoundedRectangle(cornerRadius: WelcomeStyle.buttonCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, WelcomeStyle.sectionGap)
        .accessibilityIdentifier("welcomeActions")
    }
}
