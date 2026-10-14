import XCTest
@testable import InteractiveNotch

@MainActor
final class NotchInteractionControllerTests: XCTestCase {
    func testExpandsOnlyAfterContinuousTwoHundredMillisecondHover() {
        let scheduler = TestScheduler()
        let controller = NotchInteractionController(scheduler: scheduler)
        var changes: [Bool] = []
        controller.onExpansionChanged = { changes.append($0) }

        controller.pointerEntered()
        scheduler.advance(by: 0.199)

        XCTAssertEqual(controller.state, .arming)
        XCTAssertTrue(changes.isEmpty)

        scheduler.advance(by: 0.001)
        XCTAssertEqual(controller.state, .expanded)
        XCTAssertEqual(changes, [true])
    }

    func testInterruptedHoverDoesNotExpand() {
        let scheduler = TestScheduler()
        let controller = NotchInteractionController(scheduler: scheduler)
        var changes: [Bool] = []
        controller.onExpansionChanged = { changes.append($0) }

        controller.pointerEntered()
        scheduler.advance(by: 0.1)
        controller.pointerExited()
        scheduler.advance(by: 1)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(changes.isEmpty)
    }

    func testCollapseOccursAfterThreeHundredMillisecondsOutside() {
        let scheduler = TestScheduler()
        let controller = NotchInteractionController(scheduler: scheduler)
        var changes: [Bool] = []
        controller.onExpansionChanged = { changes.append($0) }

        controller.forceExpanded()
        controller.pointerExited()
        scheduler.advance(by: 0.299)
        XCTAssertEqual(controller.state, .collapsePending)

        scheduler.advance(by: 0.001)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(changes, [true, false])
    }

    func testReentryCancelsCollapse() {
        let scheduler = TestScheduler()
        let controller = NotchInteractionController(scheduler: scheduler)
        var changes: [Bool] = []
        controller.onExpansionChanged = { changes.append($0) }

        controller.forceExpanded()
        controller.pointerExited()
        scheduler.advance(by: 0.2)
        controller.pointerEntered()
        scheduler.advance(by: 1)

        XCTAssertEqual(controller.state, .expanded)
        XCTAssertEqual(changes, [true])
    }

    func testRapidReentryCreatesOnlyOneExpansion() {
        let scheduler = TestScheduler()
        let controller = NotchInteractionController(scheduler: scheduler)
        var changes: [Bool] = []
        controller.onExpansionChanged = { changes.append($0) }

        controller.pointerEntered()
        scheduler.advance(by: 0.05)
        controller.pointerExited()
        controller.pointerEntered()
        scheduler.advance(by: 0.2)

        XCTAssertEqual(controller.state, .expanded)
        XCTAssertEqual(changes, [true])
    }

    func testInteractionHoldDefersCollapseUntilRelease() {
        let scheduler = TestScheduler()
        let controller = NotchInteractionController(scheduler: scheduler)
        var changes: [Bool] = []
        controller.onExpansionChanged = { changes.append($0) }

        controller.pointerEntered()
        controller.forceExpanded()
        controller.setInteractionHeld(true)
        controller.pointerExited()
        scheduler.advance(by: 1)
        XCTAssertEqual(controller.state, .expanded)

        controller.setInteractionHeld(false)
        XCTAssertEqual(controller.state, .collapsePending)
        scheduler.advance(by: 0.3)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(changes, [true, false])
    }
}

@MainActor
private final class TestScheduler: NotchScheduling {
    private final class Task: NotchScheduledTask {
        let deadline: TimeInterval
        var action: (@MainActor () -> Void)?

        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }

        func cancel() {
            action = nil
        }
    }

    private var now: TimeInterval = 0
    private var tasks: [Task] = []

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> NotchScheduledTask {
        let task = Task(deadline: now + delay, action: action)
        tasks.append(task)
        return task
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = tasks
            .filter({ $0.action != nil && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline }) {
            now = next.deadline
            let action = next.action
            next.action = nil
            action?()
        }
        now = target
    }
}
