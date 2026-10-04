import SwiftUI

struct MenuBarLabel: View {
    let needsYouCount: Int

    /// Debug builds carry a "D" so they can't be mistaken for the installed Tern running beside them.
    private var buildMark: String { BuildEnvironment.current == .debug ? "D" : "" }
    private var name: String { BuildEnvironment.current == .debug ? "Tern Debug" : "Tern" }

    var body: some View {
        if needsYouCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bird.fill")
                Text("\(needsYouCount)")
                if !buildMark.isEmpty { Text(buildMark) }
            }
            .accessibilityLabel("\(name), \(needsYouCount) need you")
        } else {
            HStack(spacing: 2) {
                Image(systemName: "bird")
                if !buildMark.isEmpty { Text(buildMark) }
            }
            .accessibilityLabel(name)
        }
    }
}
