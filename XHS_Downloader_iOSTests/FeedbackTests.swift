import Foundation
import CoreGraphics
import Testing
@testable import XHS_Downloader_iOS

struct FeedbackTests {
    @Test func deferredResultsCannotReplayAfterFeedbackWasInterrupted() {
        var gate = FeedbackGate()
        let beforeLeaving = gate.generation
        gate.invalidatePendingFeedback()
        let staleSuccess = gate.allows(.taskResult(.completed), enabled: true, active: true, now: 10,
                                      generation: beforeLeaving)
        #expect(!staleSuccess)
        // Rejecting a stale result must not consume the rate limit for new work.
        let currentSuccess = gate.allows(.taskResult(.completed), enabled: true, active: true, now: 10,
                                        generation: gate.generation)
        #expect(currentSuccess)
        let beforeDisabling = gate.generation
        gate.invalidatePendingFeedback()
        let staleFailure = gate.allows(.taskResult(.failed), enabled: true, active: true, now: 12,
                                      generation: beforeDisabling)
        #expect(!staleFailure)
        let currentFailure = gate.allows(.taskResult(.failed), enabled: true, active: true, now: 12,
                                        generation: gate.generation)
        #expect(currentFailure)
    }

    @Test func disablingAndBackgroundingSuppressEveryEventWithoutConsumingIt() async {
        let events: [FeedbackEvent] = [.selection, .navigation, .activation, .deactivation,
            .confirmation, .copy, .boundary, .success, .warning, .error,
            .taskResult(.completed), .taskResult(.partial), .taskResult(.failed)]
        for event in events {
            var gate = FeedbackGate()
            let accepted1 = !gate.allows(event, enabled: false, active: true, now: 10)
            #expect(accepted1)
            let accepted2 = !gate.allows(event, enabled: true, active: false, now: 10)
            #expect(accepted2)
            let accepted3 = gate.allows(event, enabled: true, active: true, now: 10)
            #expect(accepted3)
        }
    }

    @Test func rapidInteractionTicksAreCoalescedButFailuresCanInterrupt() async {
        var gate = FeedbackGate()
        let accepted4 = gate.allows(.selection, enabled: true, active: true, now: 0)
        #expect(accepted4)
        let accepted5 = !gate.allows(.selection, enabled: true, active: true, now: 0.02)
        #expect(accepted5)
        let accepted6 = gate.allows(.selection, enabled: true, active: true, now: 0.1)
        #expect(accepted6)
        let accepted7 = gate.allows(.error, enabled: true, active: true, now: 0.11)
        #expect(accepted7)
        let accepted8 = !gate.allows(.error, enabled: true, active: true, now: 0.12)
        #expect(accepted8)
        let accepted9 = !gate.allows(.navigation, enabled: true, active: true, now: 0.13)
        #expect(accepted9)
        let accepted10 = gate.allows(.navigation, enabled: true, active: true, now: 0.6)
        #expect(accepted10)
    }

    @Test func batchResultsAreLimitedAndMoreSevereResultsRemainVisible() async {
        var gate = FeedbackGate()
        let accepted11 = gate.allows(.taskResult(.completed), enabled: true, active: true, now: 0)
        #expect(accepted11)
        let accepted12 = !gate.allows(.taskResult(.completed), enabled: true, active: true, now: 1)
        #expect(accepted12)
        let accepted13 = gate.allows(.taskResult(.partial), enabled: true, active: true, now: 1.01)
        #expect(accepted13)
        let accepted14 = gate.allows(.taskResult(.failed), enabled: true, active: true, now: 1.02)
        #expect(accepted14)
        let accepted15 = !gate.allows(.taskResult(.completed), enabled: true, active: true, now: 2)
        #expect(accepted15)
        let accepted16 = gate.allows(.taskResult(.completed), enabled: true, active: true, now: 3)
        #expect(accepted16)
    }

    @Test func progressAndCancellationAreNotCompletionEvents() async {
        for status in [TaskStatus.queued, .downloading, .waitingForUser, .paused, .cancelled] {
            #expect(FeedbackEvent.result(for: status) == nil)
            var gate = FeedbackGate()
            let accepted17 = !gate.allows(.taskResult(status), enabled: true, active: true, now: 0)
            #expect(accepted17)
        }
        #expect(FeedbackEvent.result(for: .partial)?.priority == 2)
        #expect(FeedbackEvent.result(for: .failed)?.priority == 3)
    }

    @Test func dismissalTicksOnceEvenIfTheFingerRecrossesTheThreshold() async {
        var gesture = NoteDismissalFeedback()
        let accepted18 = gesture.moved(distance: 99, threshold: 100) == nil
        #expect(accepted18)
        let accepted19 = gesture.moved(distance: 101, threshold: 100) == .boundary
        #expect(accepted19)
        let accepted20 = gesture.moved(distance: 80, threshold: 100) == nil
        #expect(accepted20)
        let accepted21 = gesture.moved(distance: 120, threshold: 100) == nil
        #expect(accepted21)
        #expect(gesture.released(completed: true) == nil)
        #expect(gesture.released(completed: false) == nil)
        #expect(NoteDismissalFeedback().released(completed: true) == .navigation)
        #expect(NoteDismissalFeedback().released(completed: false) == nil)
    }

    @Test func rightwardReturnLeavesLeftwardPagingAndVerticalReadingAlone() {
        #expect(NoteHeroReturnDirection.isHorizontal(CGPoint(x: 500, y: 80)))
        #expect(!NoteHeroReturnDirection.isHorizontal(CGPoint(x: -500, y: 80)))
        #expect(!NoteHeroReturnDirection.isHorizontal(CGPoint(x: 80, y: 500)))
        #expect(!NoteHeroReturnDirection.isHorizontal(CGPoint(x: 80, y: -500)))
    }
}
