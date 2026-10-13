import Foundation

@main struct BootSelectionCheck {
  static func main() throws {
    let initial = BootSelection()
    precondition(initial.mode == .raw && !initial.nestedVirtualization)
    let volume = "/Volumes/Volume With Spaces"
    for macho in [false, true] {
      for nv in [false, true] {
        let selection = BootSelection(machoEnabled: macho, nestedVirtualization: nv)
        precondition(!selection.nestedVirtualization || selection.mode == .macho)
        let stage1 = "/payloads/" + selection.mode.stage1Path
        let arguments = selection.mode.enrollmentArguments(stage1: stage1, volume: volume)
        precondition(arguments[0] == "configure-boot")
        precondition(arguments[2] == stage1 && arguments[4] == volume)
        if macho {
          precondition(arguments.count == 5)
          precondition(selection.mode.stage2Path.hasSuffix(".pkg"))
        } else {
          precondition(
            Array(arguments.dropFirst(5)) == [
              "--raw", "--entry-point", "2048", "--lowest-virtual-address", "0",
            ])
          precondition(selection.mode.stage2Path.hasSuffix("boot.bin"))
        }
        let restored = try JSONDecoder().decode(
          BootSelection.self, from: JSONEncoder().encode(selection))
        precondition(
          restored.mode == selection.mode
            && restored.nestedVirtualization == selection.nestedVirtualization)
      }
    }
    print(
      "PASS default raw; all four option combinations; exact raw/Mach-O argument separation; paths with spaces; JSON round trip"
    )
  }
}
