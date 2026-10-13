import SwiftUI

/// A steady brand position, scrollable content and a persistent action footer.
struct InstallerPageLayout<Header: View, Content: View, Actions: View>: View {
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Content
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    GeometryReader { geometry in
      let topInset = min(96.0, max(72.0, geometry.size.height * 0.14))
      let wordmarkHeight = 400.0 * CGFloat(OmarchyWordmark.rows) / CGFloat(OmarchyWordmark.columns)

      VStack(spacing: 0) {
        ScrollView {
          VStack(spacing: 0) {
            OmarchyWordmark()
              .frame(width: 400, height: wordmarkHeight)
              .padding(.top, topInset)
              .padding(.bottom, 20)
            header()
              .frame(minHeight: 24)
              .padding(.bottom, 18)
            content()
              .frame(maxWidth: 560)
              .padding(.bottom, 24)
          }
          .padding(.horizontal, 48)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)

        actions()
          .frame(maxWidth: .infinity, minHeight: OmarchyTheme.buttonHeight)
          .padding(.horizontal, 48)
          .padding(.top, 16)
          .padding(.bottom, 32)
          .background(OmarchyTheme.window)
      }
    }
  }
}
