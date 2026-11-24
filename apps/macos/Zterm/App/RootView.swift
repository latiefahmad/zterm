import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .welcome, .createPassword, .restore, .locked:
                OnboardingContainer()
                    .transition(.opacity)
            case .main:
                MainView()
                    .transition(.opacity)
            }
        }
        .animation(.zterm, value: model.phase)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThickMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.1)))
                    .shadow(radius: 20)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
