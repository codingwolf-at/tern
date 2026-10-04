import SwiftUI

/// The Turn mark (docs/brand/concept-turn.svg), drawn from the two template layers in the asset
/// catalog so each can take its own colour: the path follows the text colour, and the ball turns
/// coral when something needs the user.
struct TurnMark: View {
    let isYourTurn: Bool

    var body: some View {
        ZStack {
            Image(.ternMarkPath)
                .resizable()
                .foregroundStyle(.primary)
            Image(.ternMarkBall)
                .resizable()
                .foregroundStyle(isYourTurn ? AnyShapeStyle(TernColor.yourTurn) : AnyShapeStyle(.tertiary))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
