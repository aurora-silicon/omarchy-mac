#if os(macOS)
  public enum MacPowerButtonGuide: String, Equatable, Sendable {
    case notebook, desktopRear, desktopUnderside, generic

    public init(deviceIdentifier: String, modelIdentifier: String) {
      switch MacModelNames.entry(for: deviceIdentifier)?.family {
      case "MacBook Air", "MacBook Pro", "MacBook Neo": self = .notebook
      case "Mac mini", "Mac Studio": self = .desktopRear
      default:
        // Apple's 2024 mini moved its power button to the underside.
        // This is presentation metadata, not an installation support gate.
        self = ["Mac16,10", "Mac16,11"].contains(modelIdentifier) ? .desktopUnderside : .generic
      }
    }

    public var assetName: String? {
      switch self {
      case .notebook: "MacBookPowerButton"
      case .desktopRear: "MacDesktopPowerButton"
      case .desktopUnderside, .generic: nil
      }
    }

    public var location: String {
      switch self {
      case .notebook: "The power button is at the top-right of the keyboard."
      case .desktopRear: "The power button is on the back of your Mac."
      case .desktopUnderside: "The power button is on the underside of your Mac mini."
      case .generic: "Use the power button on your Mac."
      }
    }

    public var holdInstruction: String {
      switch self {
      case .desktopRear: "Hold the rear power button until startup options appear."
      case .desktopUnderside: "Hold the underside power button until startup options appear."
      case .notebook, .generic: "Hold the power button until startup options appear."
      }
    }
  }
#endif
