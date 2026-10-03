import SwiftUI

struct MenuBarLabel: View {
    let backWithYouCount: Int

    var body: some View {
        if backWithYouCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bird.fill")
                Text("\(backWithYouCount)")
            }
            .accessibilityLabel("Tern, \(backWithYouCount) back with you")
        } else {
            Image(systemName: "bird")
                .accessibilityLabel("Tern")
        }
    }
}
