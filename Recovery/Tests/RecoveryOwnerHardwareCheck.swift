import Foundation

@main struct Check {
  static func main() throws {
    let owner = try RecoveryActions.resolveOwner()
    print("Verified target owner: \(owner.username) [\(owner.uuid.uuidString)]")
  }
}
