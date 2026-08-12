import SwiftUI

enum AppTheme {
    static let navy = Color(red: 0.08, green: 0.15, blue: 0.22)
    static let teal = Color(red: 0.12, green: 0.47, blue: 0.48)
    static let mist = Color(red: 0.95, green: 0.97, blue: 0.97)
    static let amber = Color(red: 0.80, green: 0.49, blue: 0.13)
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: AppTheme.navy.opacity(0.07), radius: 18, y: 8)
    }
}

extension View {
    func medBoxCard() -> some View { modifier(CardStyle()) }
}

