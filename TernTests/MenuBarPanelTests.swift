import Testing
@testable import Tern

@Suite("Menu bar icon")
struct MenuBarPanelTests {
    @Test("The icon shows the attention count, and Debug builds are marked")
    func label() {
        #expect(MenuBarPanel.label(needsYou: 0, build: .release) == ("bird", "", "Tern"))
        #expect(MenuBarPanel.label(needsYou: 2, build: .release) == ("bird.fill", " 2", "Tern, 2 need you"))
        #expect(MenuBarPanel.label(needsYou: 1, build: .release).accessibility == "Tern, 1 needs you")
        #expect(MenuBarPanel.label(needsYou: 0, build: .debug) == ("bird", " D", "Tern Debug"))
        #expect(MenuBarPanel.label(needsYou: 3, build: .debug) == ("bird.fill", " 3 D", "Tern Debug, 3 need you"))
    }
}
