import Foundation

@MainActor
protocol NotchScheduledTask: AnyObject {
    func cancel()
}

@MainActor
protocol NotchScheduling {
    @discardableResult
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> NotchScheduledTask
}

@MainActor
final class DispatchNotchScheduler: NotchScheduling {
    @discardableResult
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> NotchScheduledTask {
        let task = DispatchScheduledTask(action: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak task] in
            task?.perform()
        }
        return task
    }
}

@MainActor
private final class DispatchScheduledTask: NotchScheduledTask {
    private var action: (@MainActor () -> Void)?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func perform() {
        let pendingAction = action
        action = nil
        pendingAction?()
    }

    func cancel() {
        action = nil
    }
}

@MainActor
final class NotchInteractionController {
    enum State: Equatable {
        case idle
        case arming
        case expanded
        case collapsePending
    }

    private(set) var state: State = .idle
    var onExpansionChanged: ((Bool) -> Void)?

    private let scheduler: NotchScheduling
    private let activationDelay: TimeInterval
    private let collapseDelay: TimeInterval
    private var pendingTask: NotchScheduledTask?
    private var isPointerInside = false
    private var isInteractionHeld = false

    init(
        scheduler: NotchScheduling? = nil,
        activationDelay: TimeInterval = 0.2,
        collapseDelay: TimeInterval = 0.3
    ) {
        self.scheduler = scheduler ?? DispatchNotchScheduler()
        self.activationDelay = activationDelay
        self.collapseDelay = collapseDelay
    }

    func pointerEntered() {
        isPointerInside = true
        switch state {
        case .idle:
            armExpansion()
        case .arming, .expanded:
            break
        case .collapsePending:
            cancelPendingTask()
            state = .expanded
        }
    }

    func pointerExited() {
        isPointerInside = false
        if isInteractionHeld {
            if state == .collapsePending {
                cancelPendingTask()
                state = .expanded
            }
            return
        }
        switch state {
        case .idle:
            break
        case .arming:
            cancelPendingTask()
            state = .idle
        case .expanded:
            armCollapse()
        case .collapsePending:
            break
        }
    }

    func forceExpanded() {
        cancelPendingTask()
        guard state != .expanded else { return }
        state = .expanded
        onExpansionChanged?(true)
    }

    func forceCollapsed() {
        cancelPendingTask()
        guard state != .idle else { return }
        state = .idle
        onExpansionChanged?(false)
    }

    func reset() {
        isPointerInside = false
        isInteractionHeld = false
        forceCollapsed()
    }

    func setInteractionHeld(_ held: Bool) {
        guard isInteractionHeld != held else { return }
        isInteractionHeld = held
        if held, state == .collapsePending {
            cancelPendingTask()
            state = .expanded
        } else if !held, state == .expanded, !isPointerInside {
            armCollapse()
        }
    }

    private func armExpansion() {
        cancelPendingTask()
        state = .arming
        pendingTask = scheduler.schedule(after: activationDelay) { [weak self] in
            guard let self, self.state == .arming else { return }
            self.pendingTask = nil
            self.state = .expanded
            self.onExpansionChanged?(true)
        }
    }

    private func armCollapse() {
        cancelPendingTask()
        state = .collapsePending
        pendingTask = scheduler.schedule(after: collapseDelay) { [weak self] in
            guard let self, self.state == .collapsePending else { return }
            self.pendingTask = nil
            self.state = .idle
            self.onExpansionChanged?(false)
        }
    }

    private func cancelPendingTask() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}
