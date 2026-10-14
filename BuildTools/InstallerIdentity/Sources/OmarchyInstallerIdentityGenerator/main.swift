import Foundation

// Turns Packaging/identity.conf into Swift constants for the trust core. The
// shell side sources the same file, so the parser accepts only lines whose
// meaning is identical in both: NAME="value" with no quoting or expansion.

struct IdentityEntry {
  let name: String
  let value: String

  var propertyName: String {
    let words = name.dropFirst(namePrefix.count).lowercased().split(separator: "_")
    return words.enumerated().map { index, word in
      index == 0 ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
    }.joined()
  }
}

let namePrefix = "INSTALLER_"
let forbiddenValueCharacters: Set<Character> = ["\"", "\\", "$", "`"]

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("identity generator: \(message)\n".utf8))
  exit(1)
}

// INSTALLER_ then words of A-Z and 0-9 joined by single underscores, the
// first starting with a letter, so every name maps to a distinct identifier.
func isValidName(_ name: Substring) -> Bool {
  guard name.hasPrefix(namePrefix) else {
    return false
  }
  let words = name.dropFirst(namePrefix.count)
    .split(separator: "_", omittingEmptySubsequences: false)
  guard let first = words.first?.first, ("A"..."Z").contains(first) else {
    return false
  }
  return words.allSatisfy { word in
    !word.isEmpty
      && word.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
  }
}

func parse(_ source: String) -> [IdentityEntry] {
  var entries: [IdentityEntry] = []
  var seen: Set<String> = []
  for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
    .enumerated()
  {
    let lineNumber = index + 1
    if line.isEmpty || line.hasPrefix("#") {
      continue
    }
    guard let equals = line.firstIndex(of: "=") else {
      fail("line \(lineNumber) is not NAME=\"value\"")
    }
    let name = line[..<equals]
    let quoted = line[line.index(after: equals)...]
    guard isValidName(name) else {
      fail("line \(lineNumber) has an invalid name")
    }
    guard quoted.count >= 3, quoted.first == "\"", quoted.last == "\"" else {
      fail("line \(lineNumber) needs a non-empty double-quoted value")
    }
    let value = quoted.dropFirst().dropLast()
    guard !value.contains(where: forbiddenValueCharacters.contains) else {
      fail("line \(lineNumber) value contains a quote, backslash, dollar or backtick")
    }
    let entry = IdentityEntry(name: String(name), value: String(value))
    guard entry.propertyName != "entries" else {
      fail("line \(lineNumber) uses the reserved name \(name)")
    }
    guard seen.insert(entry.propertyName).inserted else {
      fail("line \(lineNumber) repeats \(name)")
    }
    entries.append(entry)
  }
  guard !entries.isEmpty else {
    fail("the configuration defines no values")
  }
  return entries
}

func render(_ entries: [IdentityEntry]) -> String {
  var lines = [
    "// Generated from Packaging/identity.conf. Edit that file, not this one.",
    "enum InstallerBuildConfiguration {",
  ]
  for entry in entries {
    lines.append("  static let \(entry.propertyName) = \"\(entry.value)\"")
  }
  lines.append("")
  lines.append("  static let entries: [String: String] = [")
  for entry in entries {
    lines.append("    \"\(entry.name)\": \(entry.propertyName),")
  }
  lines.append("  ]")
  lines.append("}")
  return lines.joined(separator: "\n") + "\n"
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  fail("usage: OmarchyInstallerIdentityGenerator CONFIGURATION OUTPUT")
}
let configuration = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let source: String
do {
  source = try String(contentsOf: configuration, encoding: .utf8)
} catch {
  fail("cannot read \(configuration.path): \(error)")
}
let rendered = Data(render(parse(source)).utf8)
if (try? Data(contentsOf: output)) != rendered {
  do {
    try rendered.write(to: output, options: .atomic)
  } catch {
    fail("cannot write \(output.path): \(error)")
  }
}
