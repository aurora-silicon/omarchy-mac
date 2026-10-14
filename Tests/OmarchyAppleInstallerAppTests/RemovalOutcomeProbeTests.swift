#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyAppleInstallerApp

  final class RemovalOutcomeProbeTests: XCTestCase {
    func testAKeptHelperIsAskedAgainOnlyWhileBusy() async {
      for (answers, expected, asked) in [
        ([RemovalFinalization.busy, .busy, .finalized], RemovalFinalization.finalized, 3),
        ([.unfinished], .unfinished, 1),
        ([.busy, .installRecordUncleared], .installRecordUncleared, 2),
        // A dropped connection or an older helper answers nothing.
        ([nil, .finalized], nil, 1),
        // Still busy at the end confirms nothing.
        ([.busy, .busy, .busy, .finalized], .busy, 3),
      ] as [([RemovalFinalization?], RemovalFinalization?, Int)] {
        let script = Script(answers)
        let answer = await RemovalOutcomeProbe.finalization(attempts: 3, pause: .zero) {
          script.next()
        }
        XCTAssertEqual(answer, expected, "\(answers)")
        XCTAssertEqual(script.asked, asked, "\(answers)")
      }
    }

    func testNoNewQuestionAfterTheDeadline() async {
      let script = Script([.busy, .finalized])
      let answer = await RemovalOutcomeProbe.finalization(
        attempts: 10, pause: .milliseconds(20), deadline: .milliseconds(10)
      ) { script.next() }
      XCTAssertEqual(answer, .busy)
      XCTAssertEqual(script.asked, 1)
    }

    private final class Script: @unchecked Sendable {
      private let lock = NSLock()
      private var answers: [RemovalFinalization?]
      private var count = 0
      init(_ answers: [RemovalFinalization?]) { self.answers = answers }
      var asked: Int { lock.withLock { count } }
      func next() -> RemovalFinalization? {
        lock.withLock {
          count += 1
          return answers.isEmpty ? nil : answers.removeFirst()
        }
      }
    }
  }
#endif
