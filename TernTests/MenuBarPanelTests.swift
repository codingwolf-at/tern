import Testing
@testable import Tern

@Suite("Menu bar icon")
struct MenuBarPanelTests {
    @Test("The icon shows the attention count, and Debug builds are marked")
    func label() {
        #expect(MenuBarPanel.label(needsYou: 0, build: .release) == ("TernMarkPath", "", "Tern"))
        #expect(MenuBarPanel.label(needsYou: 2, build: .release) == ("TernMark", " 2", "Tern, 2 need you"))
        #expect(MenuBarPanel.label(needsYou: 1, build: .release).accessibility == "Tern, 1 needs you")
        #expect(MenuBarPanel.label(needsYou: 0, build: .debug) == ("TernMarkPath", " D", "Tern Debug"))
        #expect(MenuBarPanel.label(needsYou: 3, build: .debug) == ("TernMark", " 3 D", "Tern Debug, 3 need you"))
    }

    @Test("Idle is the path alone; the ball appears only when something needs you")
    func ballMeansYourTurn() {
        #expect(MenuBarPanel.label(needsYou: 0, build: .release).image == "TernMarkPath")
        for count in [1, 5, 99] {
            #expect(MenuBarPanel.label(needsYou: count, build: .release).image == "TernMark")
        }
    }
}
