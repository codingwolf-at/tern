import SwiftUI

struct MenuBarLabel: View {
    let needsYouCount: Int

    var body: some View {
        if needsYouCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bird.fill")
                Text("\(needsYouCount)")
            }
            .accessibilityLabel("Tern, \(needsYouCount) need you")
        } else {
            Image(systemName: "bird")
                .accessibilityLabel("Tern")
        }
    }
}
