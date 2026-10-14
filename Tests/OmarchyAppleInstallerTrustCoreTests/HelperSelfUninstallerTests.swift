#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class HelperSelfUninstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
      try? FileManager.default.removeItem(at: root)
    }

    func testRemovesJobFileBinaryAndAllStateThenUnloadsAndExits() throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()

      uninstaller(paths, recorder).uninstallNow()

      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.jobFile.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.binary.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
    }

    func testAPackageInstalledHelperRunningFromTheAppStaysInPlace() async throws {
      // The installer package's job runs the helper inside the app in
      // /Applications; only the package can register it again.
      let paths = try makeInstalledHelper()
      let inApp = root.appendingPathComponent(
        "Applications/Probe.app/Contents/Library/LaunchServices/probe.helper")
      let recorder = Recorder()

      let helper = uninstaller(paths, recorder, delay: .milliseconds(10), executable: inApp)
      XCTAssertFalse(helper.uninstallsAfterRemoval)
      helper.uninstallAfterRemoval()
      helper.uninstallNow()
      try await Task.sleep(for: .milliseconds(100))

      assertStillInstalled(paths)
      XCTAssertEqual(recorder.events, [], "a package-installed helper is never unloaded")
    }

    func testAHelperWithoutAuthorizedClientsStaysInPlaceEvenInPrivilegedHelperTools() throws {
      // The private ad hoc package copies its helper to PrivilegedHelperTools,
      // but that build's app cannot bless it again.
      let paths = try makeInstalledHelper()
      let recorder = Recorder()

      let helper = uninstaller(paths, recorder, declaresAuthorizedClients: false)
      XCTAssertFalse(helper.uninstallsAfterRemoval)
      helper.uninstallNow()

      assertStillInstalled(paths)
      XCTAssertEqual(recorder.events, [])
    }

    func testOnlyABlessedHelperRunningFromItsFixedBinaryUninstalls() throws {
      let binary = root.appendingPathComponent("PrivilegedHelperTools/probe.helper")
      let cases: [(URL, Bool, Bool)] = [
        (binary, true, true),
        (root.appendingPathComponent("PrivilegedHelperTools/./probe.helper"), true, true),
        (binary, false, false),
        (
          root.appendingPathComponent("Applications/A.app/Contents/MacOS/probe.helper"), true, false
        ),
      ]
      for (executable, declares, expected) in cases {
        XCTAssertEqual(
          LaunchdHelperSelfUninstaller.installedBySMJobBless(
            executable: executable, binary: binary, declaresAuthorizedClients: declares),
          expected, "\(executable.path) declares \(declares)")
      }
    }

    func testUninstallingAfterRemovalWaitsThenRunsInTheBackground() async throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()

      uninstaller(paths, recorder, delay: .milliseconds(50)).uninstallAfterRemoval()
      XCTAssertEqual(recorder.events, [], "unloading waits")

      for _ in 0..<200 where recorder.events.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
    }

    func testFilesGoAtOnceSoNoStaleHelperIsSeenWhileUnloadWaits() throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()

      uninstaller(paths, recorder, delay: .seconds(30)).uninstallAfterRemoval()

      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.jobFile.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.binary.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
      XCTAssertEqual(recorder.events, [], "unloading waits for the reply to reach the app")
    }

    func testTheAppTellsWhichRegisteredHelperStaysAfterRemoval() {
      let blessed = "/Library/PrivilegedHelperTools/probe.helper"
      let cases: [(String?, Bool, Bool)] = [
        (nil, true, false),
        (nil, false, false),
        (blessed, true, false),
        ("/Library/PrivilegedHelperTools/./probe.helper", true, false),
        (blessed, false, true),
        ("/Applications/Probe.app/Contents/Library/LaunchServices/probe.helper", true, true),
        ("/Applications/Probe.app/Contents/Library/LaunchServices/probe.helper", false, true),
      ]
      for (program, canInstall, stays) in cases {
        XCTAssertEqual(
          HelperRemovalFate.staysAfterRemoval(
            jobProgram: program, appCanInstallHelper: canInstall, blessedBinary: blessed),
          stays, "\(program ?? "no job") canInstall \(canInstall)")
      }
    }

    func testTheHelperAndTheAppNormalizeSymlinkedPathsTheSameWay() throws {
      // The job file may name the blessed binary through a symlink; the
      // helper resolves its own path, so the app must too, or one side keeps
      // a helper the other expects gone.
      let binary = root.appendingPathComponent("PrivilegedHelperTools/probe.helper")
      try FileManager.default.createDirectory(
        at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: binary)
      let link = root.appendingPathComponent("link.helper")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
      let dotted = root.appendingPathComponent("PrivilegedHelperTools/../link.helper")

      for path in [link.path, dotted.path] {
        XCTAssertEqual(HelperBinaryPath.normalized(path), HelperBinaryPath.normalized(binary.path))
        XCTAssertTrue(
          LaunchdHelperSelfUninstaller.installedBySMJobBless(
            executable: URL(fileURLWithPath: path), binary: binary,
            declaresAuthorizedClients: true), path)
        XCTAssertFalse(
          HelperRemovalFate.staysAfterRemoval(
            jobProgram: path, appCanInstallHelper: true, blessedBinary: binary.path), path)
      }
    }

    func testPackagedHelperMetadataIsReadTheWayTheBuildScriptsWriteIt() throws {
      let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      let packaging = repository.appendingPathComponent("Packaging")
      let identifier = InstallerProductIdentity.helperIdentifier

      // The helper's embedded Info.plist: ad hoc builds leave out
      // SMAuthorizedClients, signed ones name their app.
      for requirement in ["", #"identifier "com.example.app""#] {
        let output = root.appendingPathComponent("plists-\(requirement.isEmpty)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try run(
          packaging.appendingPathComponent("helper-plists"),
          [output.path, "7", "1.0"] + (requirement.isEmpty ? [] : [requirement]))
        let info = try PropertyListSerialization.propertyList(
          from: Data(contentsOf: output.appendingPathComponent("helper-info.plist")), format: nil)
        XCTAssertEqual(
          LaunchdHelperSelfUninstaller.declaresAuthorizedClients(info as? [String: Any]),
          !requirement.isEmpty, "requirement \(requirement)")
      }
      XCTAssertFalse(LaunchdHelperSelfUninstaller.declaresAuthorizedClients(nil))

      // The job file the installer package installs runs the helper from the
      // app in /Applications, so the app keeps it whatever it could bless.
      let app = root.appendingPathComponent("Probe Installer.app")
      let helper = "Contents/Library/LaunchServices/\(identifier)"
      let embedded = app.appendingPathComponent(
        "Contents/Library/LaunchDaemons/\(identifier).plist")
      for file in [app.appendingPathComponent(helper), embedded] {
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      }
      try Data("x".utf8).write(to: app.appendingPathComponent(helper))
      try PropertyListSerialization.data(
        fromPropertyList: [
          "Label": identifier, "BundleProgram": helper, "MachServices": [identifier: true],
          "UserName": "root",
        ], format: .xml, options: 0
      ).write(to: embedded)
      let job = root.appendingPathComponent("\(identifier).plist")
      try run(packaging.appendingPathComponent("pkg/derive-daemon-plist"), [app.path, job.path])
      let program = try XCTUnwrap(HelperRemovalFate.jobProgram(atPath: job.path))
      XCTAssertEqual(program, "/Applications/Probe Installer.app/\(helper)")
      for canInstall in [true, false] {
        XCTAssertTrue(
          HelperRemovalFate.staysAfterRemoval(jobProgram: program, appCanInstallHelper: canInstall))
      }
      XCTAssertNil(HelperRemovalFate.jobProgram(atPath: root.appendingPathComponent("none").path))
    }

    // MARK: Fixtures

    private func run(_ script: URL, _ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = [script.path] + arguments
      process.standardOutput = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0, script.lastPathComponent)
    }

    private struct Paths {
      let jobFile: URL
      let binary: URL
      let state: URL
    }

    private final class Recorder: @unchecked Sendable {
      private let lock = NSLock()
      private var recorded: [String] = []
      var events: [String] { lock.withLock { recorded } }
      func record(_ event: String) { lock.withLock { recorded.append(event) } }
    }

    private func makeInstalledHelper() throws -> Paths {
      let paths = Paths(
        jobFile: root.appendingPathComponent("LaunchDaemons/probe.helper.plist"),
        binary: root.appendingPathComponent("PrivilegedHelperTools/probe.helper"),
        state: root.appendingPathComponent("db/probe.app", isDirectory: true))
      for file in [paths.jobFile, paths.binary] {
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
      }
      let retired = paths.state.appendingPathComponent("retired-execution-journals/t")
      try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: retired.appendingPathComponent("abc.jsonl"))
      return paths
    }

    private func assertStillInstalled(
      _ paths: Paths, file: StaticString = #filePath, line: UInt = #line
    ) {
      for item in [paths.jobFile, paths.binary, paths.state] {
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: item.path), item.path, file: file, line: line)
      }
    }

    /// By default the helper runs from its fixed binary and its build declares
    /// the app that may install it: the `SMJobBless` case.
    private func uninstaller(
      _ paths: Paths, _ recorder: Recorder, delay: Duration = .zero,
      executable: URL? = nil, declaresAuthorizedClients: Bool = true
    ) -> LaunchdHelperSelfUninstaller {
      LaunchdHelperSelfUninstaller(
        label: "probe.helper", jobFile: paths.jobFile, binary: paths.binary,
        workingDirectory: paths.state, delay: delay,
        unload: { recorder.record("unload:\($0)") },
        exitProcess: { recorder.record("exit") },
        executable: executable ?? paths.binary,
        declaresAuthorizedClients: declaresAuthorizedClients)
    }
  }
#endif
