import Foundation

/// Pure push-to-talk state machine. Timestamps come in with events so the
/// machine itself has no clock dependency and is fully unit-testable.
public struct FnStateMachine {
    public enum State: Equatable {
        case idle
        case recording(since: Date)
        case processing
    }

    public enum Event {
        case hotkeyDown(at: Date)
        case hotkeyUp(at: Date)
        case otherKeyDown          // any plain key pressed (fn was a chord modifier)
        case abort                 // audio device changed, engine failure, etc.
        case maxDurationReached(at: Date)
        case pipelineFinished
    }

    public enum Action: Equatable {
        case none
        case startRecording
        case cancelRecording       // discard captured audio
        case stopAndProcess
        case flashBusy             // hotkey pressed while a pipeline is in flight
    }

    public private(set) var state: State = .idle
    public let minHold: TimeInterval

    public init(minHold: TimeInterval = 0.25) {
        self.minHold = minHold
    }

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .hotkeyDown(let now)):
            state = .recording(since: now)
            return .startRecording

        case (.recording, .otherKeyDown), (.recording, .abort):
            state = .idle
            return .cancelRecording

        case (.recording(let since), .hotkeyUp(let now)):
            if now.timeIntervalSince(since) < minHold {
                state = .idle
                return .cancelRecording
            }
            state = .processing
            return .stopAndProcess

        case (.recording, .maxDurationReached):
            state = .processing
            return .stopAndProcess

        case (.processing, .hotkeyDown):
            return .flashBusy

        case (.processing, .pipelineFinished):
            state = .idle
            return .none

        // Spurious or irrelevant events in every other combination.
        default:
            return .none
        }
    }
}
