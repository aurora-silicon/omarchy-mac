import Foundation

enum AuraBootMode: String, Codable {
  case raw
  case macho

  var stage1Path: String {
    self == .raw ? "raw/aura-raw.bin" : "macho/aura-boot.macho"
  }

  var stage2Path: String {
    self == .raw ? "raw/boot.bin" : "macho/aura-stage2.pkg"
  }

  func enrollmentArguments(stage1: String, volume: String) -> [String] {
    var arguments = ["configure-boot", "-c", stage1, "-v", volume]
    if self == .raw {
      arguments += ["--raw", "--entry-point", "2048", "--lowest-virtual-address", "0"]
    }
    return arguments
  }
}

struct BootSelection: Codable {
  let mode: AuraBootMode
  let nestedVirtualization: Bool

  init(machoEnabled: Bool = false, nestedVirtualization: Bool = false) {
    mode = machoEnabled ? .macho : .raw
    self.nestedVirtualization = machoEnabled && nestedVirtualization
  }
}
