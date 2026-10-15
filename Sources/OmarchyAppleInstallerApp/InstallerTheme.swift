import AppKit
import SwiftUI

/// Design tokens for the approved installer look: Try Omarchy's monospaced
/// type and buttons on omarchy.org's Tokyo Night colours (blue accent), with
/// light and dark palettes that follow the system appearance.
enum OmarchyTheme {
  // MARK: Palette

  // Dark palette: omarchy.org's Tokyo Night tokens (background night/storm,
  // foreground lavender, blue accent, red and yellow from the same scheme).
  // Secondary text is the accent, slightly muted like Try Omarchy's but kept
  // at 4.5:1 or better for its small sizes. Light palette: the Tokyo Night
  // "Day" counterparts, darkened where small text needs the contrast.
  static let window = dynamic(light: 0xE1_E2E7, dark: 0x1A_1B26)
  static let card = dynamic(light: 0xFF_FFFF, dark: 0x24_283B)
  static let text = dynamic(light: 0x37_60BF, dark: 0xC0_CAF5)
  static let secondaryText = dynamic(light: 0x4A_5A9E, dark: 0x7A_A2F7, darkOpacity: 0.9)
  static let separator = dynamic(light: 0xC4_C8DA, dark: 0x41_4868)
  static let track = dynamic(light: 0xD0_D5E3, dark: 0x2F_334D)
  static let accent = dynamic(light: 0x2E_7DE9, dark: 0x7A_A2F7)
  static let accentText = dynamic(light: 0xFF_FFFF, dark: 0x1A_1B26)
  static let success = dynamic(light: 0x48_5E30, dark: 0x9E_Cb6B)
  static let danger = dynamic(light: 0xF5_2A65, dark: 0xF7_768E)
  static let caution = dynamic(light: 0x8C_6C3E, dark: 0xE0_AF68)

  /// The disk divider handle: a firm blue that reads on the pale Omarchy
  /// segment in both appearances.
  static let handle = dynamic(light: 0x1F_5FD6, dark: 0x3D_74E8)

  // Try Omarchy's button feedback: in dark mode a primary button brightens to
  // pale cyan under the pointer and turns cyan while pressed; in light mode it
  // deepens instead, so its white label keeps its contrast. A secondary button
  // takes an accent border and brighter text on hover and a tinted surface
  // when pressed; every label stays at 4.5:1 or better.
  static let buttonHover = dynamic(light: 0x2A_6FD6, dark: 0xB4_F9F8)
  static let buttonPressed = dynamic(light: 0x00_7197, dark: 0x7D_CFFF)
  static let buttonHoverText = dynamic(light: 0x25_63C9, dark: 0xB4_F9F8)
  static let buttonPressedSurface = dynamic(light: 0xE6_E8EF, dark: 0x41_4868)

  // MARK: Metrics

  static let cardRadius: CGFloat = 8
  static let buttonRadius: CGFloat = 6
  static let buttonHeight: CGFloat = 34
  static let buttonTracking: CGFloat = 0.35
  /// Extra leading for small help text, which often wraps: about 1.4 times
  /// its size instead of SF Mono's default 1.2.
  static let helpLineSpacing: CGFloat = 2

  // MARK: Type

  // Try Omarchy's scale, all in the system monospaced face. Views pick a role
  // and never set their own point size.
  static let title = mono(22, .bold)
  static let heading = mono(15, .bold)
  /// Try Omarchy's subtitle line ("OMARCHY  ·  APPLE SILICON"): short facts
  /// drawn uppercase in the accent colour.
  static let eyebrow = mono(11, .semibold)
  static let body = mono(13)
  static let detail = mono(11)
  static let control = mono(12, .medium)
  static let button = mono(12, .bold)
  static let badge = mono(11, .bold)
  static let technical = mono(10)
  static let numeral = mono(13, .bold)

  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }

  private static func dynamic(light: Int, dark: Int, darkOpacity: CGFloat = 1) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark =
          appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(hex: dark, alpha: darkOpacity) : NSColor(hex: light)
      }
    )
  }
}

extension View {
  /// Small secondary help text that may wrap onto several lines.
  func omarchyHelpText() -> some View {
    font(OmarchyTheme.detail)
      .foregroundStyle(OmarchyTheme.secondaryText)
      .lineSpacing(OmarchyTheme.helpLineSpacing)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// The default type for a window or sheet, so text and controls without a
  /// role of their own are monospaced too.
  func omarchyTypography() -> some View {
    font(OmarchyTheme.body).fontDesign(.monospaced)
  }
}

extension NSColor {
  fileprivate convenience init(hex: Int, alpha: CGFloat = 1) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: alpha
    )
  }
}
