import Foundation

/// Input validation only. Creating the target account and granting ownership
/// require the separate, resumable installer helper.
public struct RecoveryAccountDraft: Equatable, Sendable {
  public var username = ""
  public var password = ""
  public var confirmation = ""

  public init() {}

  public var usernameIssue: String? {
    guard !username.isEmpty else { return nil }
    guard username.range(of: "\\A[a-z][a-z0-9_-]{0,30}\\z", options: .regularExpression) != nil
    else {
      return "Start with a lowercase letter. Use letters, numbers, hyphens or underscores."
    }
    return nil
  }

  public var passwordIssue: String? {
    guard !password.isEmpty else { return nil }
    if password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
      return "Use a password without line breaks."
    }
    return nil
  }

  public var confirmationIssue: String? {
    guard !confirmation.isEmpty else { return nil }
    return password == confirmation ? nil : "Passwords don’t match."
  }

  public var isValid: Bool {
    !username.isEmpty && usernameIssue == nil && !password.isEmpty && passwordIssue == nil
      && !confirmation.isEmpty && confirmationIssue == nil
  }

  public mutating func clearPasswords() {
    password = ""
    confirmation = ""
  }
}
