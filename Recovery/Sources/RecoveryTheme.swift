import SwiftUI

struct RecoveryPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(OmarchyTheme.button)
      .textCase(.uppercase)
      .tracking(OmarchyTheme.buttonTracking)
      .foregroundColor(OmarchyTheme.accentText)
      .padding(.horizontal, 20)
      .frame(height: OmarchyTheme.buttonHeight)
      .background(
        configuration.isPressed ? OmarchyTheme.buttonPressed : OmarchyTheme.accent,
        in: RoundedRectangle(cornerRadius: OmarchyTheme.buttonRadius)
      )
      .opacity(isEnabled ? 1 : 0.45)
  }
}
