import SwiftUI
import ThinkingOrbsKit

struct WebLoadingView: View {
    let imageName: String

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .accessibilityHidden(true)

                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .blur(radius: 26)
                    .mask {
                        RadialGradient(
                            stops: [
                                .init(color: .black.opacity(0.9), location: 0.25),
                                .init(color: .black.opacity(0.68), location: 0.62),
                                .init(color: .clear, location: 1)
                            ],
                            center: UnitPoint(x: 0.5, y: 0.2),
                            startRadius: geometry.size.width * 0.18,
                            endRadius: geometry.size.width * 0.7
                        )
                    }
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    ThinkingOrb(state: .connecting, size: .px64, theme: .light)
                        .accessibilityHidden(true)
                    Text("Загрузка")
                        .font(WelcomeStyle.font(.medium, size: 16, relativeTo: .body))
                        .foregroundStyle(WelcomeStyle.text)
                        .shadow(color: .white.opacity(0.45), radius: 8)
                        .accessibilityIdentifier("webLoadingLabel")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, geometry.size.height * 0.14)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
            .accessibilityElement(children: .contain)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("webLoadingScreen")
    }
}
