import Darwin
import Foundation

// Fixed startup milestones only: no command output, boot arguments or credentials.
enum LaunchTrace {
  static func mark(_ milestone: String) {
    let line = "\(Date().timeIntervalSince1970) pid=\(getpid()) ppid=\(getppid()) \(milestone)\n"
    let bytes = Data(line.utf8)
    var paths = ["/tmp/aurora-installer-startup.log"]
    // Best-effort persistence only. Never remount or wait for disk services
    // before creating our window; Recovery's progress screen waits for it.
    if FileManager.default.fileExists(atPath: "/System/Installation/CDIS") {
      paths.append(RecoveryActions.state.appendingPathComponent("startup.log").path)
    }
    for path in paths {
      let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
      guard fd >= 0 else { continue }
      bytes.withUnsafeBytes { buffer in
        _ = Darwin.write(fd, buffer.baseAddress, buffer.count)
      }
      close(fd)
    }
  }
}
