import UIKit
import SwiftUI

/// App-owned feedback follows the meaning of an action, never a render or a
/// progress tick. System controls keep their own native feedback.
enum FeedbackEvent: Equatable {
    case selection, navigation, activation, deactivation, confirmation, copy, boundary
    case success, warning, error
    case taskResult(TaskStatus)

    var priority: Int {
        switch self {
        case .error, .taskResult(.failed): return 3
        case .warning, .taskResult(.partial): return 2
        case .success, .taskResult(.completed): return 1
        default: return 0
        }
    }

    var isTaskResult: Bool {
        if case .taskResult = self { return true }
        return false
    }

    static func result(for status: TaskStatus) -> FeedbackEvent? {
        switch status {
        case .completed, .partial, .failed: return .taskResult(status)
        default: return nil
        }
    }
}

/// A monotonic clock makes burst suppression independent of wall-clock changes.
/// Results can interrupt lighter feedback; a quick failure must remain audible
/// to touch even when the user just pressed a button.
struct FeedbackGate {
    private var last: (time: TimeInterval, priority: Int)?
    private var lastResult: (time: TimeInterval, priority: Int)?
    private(set) var generation: UInt = 0

    mutating func invalidatePendingFeedback() { generation &+= 1 }

    mutating func allows(_ event: FeedbackEvent, enabled: Bool, active: Bool, now: TimeInterval,
                         generation expected: UInt? = nil) -> Bool {
        guard enabled, active else { return false }
        if let expected, expected != generation { return false }
        if event.isTaskResult {
            guard case .taskResult(let status) = event, FeedbackEvent.result(for: status) != nil else { return false }
            if let lastResult, now - lastResult.time < 1.5, event.priority <= lastResult.priority { return false }
        }
        if let last {
            let interval: TimeInterval = last.priority > 0 ? 0.35 : 0.06
            if now - last.time < interval, event.priority <= last.priority { return false }
        }
        last = (now, event.priority)
        if event.isTaskResult { lastResult = (now, event.priority) }
        return true
    }
}

@MainActor
enum AppFeedback {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let boundaryGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static var gate = FeedbackGate()

    static var enabled: Bool { FeedbackPreference.isEnabled(in: .standard) }
    private static var active: Bool { UIApplication.shared.applicationState == .active }
    static var canPlay: Bool { enabled && active }
    static var deferredGeneration: UInt { gate.generation }

    static func invalidatePendingFeedback() { gate.invalidatePendingFeedback() }

    static func prepareForGesture() {
        guard canPlay else { return }
        boundaryGenerator.prepare()
    }

    static func play(_ event: FeedbackEvent, generation: UInt? = nil) {
        guard gate.allows(event, enabled: enabled, active: active,
                          now: ProcessInfo.processInfo.systemUptime, generation: generation) else { return }
        switch event {
        case .selection:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .navigation, .deactivation:
            softGenerator.impactOccurred(intensity: 0.65)
            softGenerator.prepare()
        case .activation:
            mediumGenerator.impactOccurred(intensity: 0.65)
            mediumGenerator.prepare()
        case .confirmation, .copy:
            lightGenerator.impactOccurred(intensity: 0.8)
            lightGenerator.prepare()
        case .boundary:
            boundaryGenerator.impactOccurred(intensity: 0.45)
        case .success, .taskResult(.completed):
            notificationGenerator.notificationOccurred(.success)
        case .warning, .taskResult(.partial):
            notificationGenerator.notificationOccurred(.warning)
        case .error, .taskResult(.failed):
            notificationGenerator.notificationOccurred(.error)
        case .taskResult:
            break
        }
    }
}

extension View {
    /// Observe actual changes, without firing on appearance or on dismissal.
    func selectionFeedback<Value: Equatable>(_ value: Value) -> some View {
        onChange(of: value) { _, _ in AppFeedback.play(.selection) }
    }
}

extension Binding where Value: Equatable {
    /// Only a control's write triggers feedback; restoring a backup or loading
    /// preferences cannot produce a cascade of artificial selection ticks.
    @MainActor func feedbackSelection() -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { value in
            guard wrappedValue != value else { return }
            wrappedValue = value
            AppFeedback.play(.selection)
        })
    }
}
