import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import GameController
import IOKit.hid

struct ScrollConfiguration {
    var speed: Double = 18
    var mouseSpeed: Double = 18
    var deadzone: Float = 0.16
    var invertX = false
    var invertY = false
    var invertMouseX = false
    var invertMouseY = false
    var disableHorizontal = false
    var disableMouse = false
    var disableClicks = false
    var disableDictation = false
    var debug = false
    var diagnose = false
    var testScroll = false
    var inputMode: InputMode = .auto
    var rightStick: AxisPair?
    var triggers: AxisPair?
    var dictationButton: RemoteButton = .b
    var eventTap: CGEventTapLocation = .cgSessionEventTap
    var unit: CGScrollEventUnit = .pixel

    enum InputMode: String {
        case auto
        case gameController
        case hid
    }

    enum AxisPair: String {
        case xY = "xy"
        case rxRy = "rxry"
        case zRz = "zrz"

        var usages: (x: UInt32, y: UInt32) {
            switch self {
            case .xY:
                return (UInt32(kHIDUsage_GD_X), UInt32(kHIDUsage_GD_Y))
            case .rxRy:
                return (UInt32(kHIDUsage_GD_Rx), UInt32(kHIDUsage_GD_Ry))
            case .zRz:
                return (UInt32(kHIDUsage_GD_Z), UInt32(kHIDUsage_GD_Rz))
            }
        }
    }

    static func parse(arguments: [String]) -> ScrollConfiguration {
        var config = ScrollConfiguration()
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--speed":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    config.speed = max(1, value)
                    index += 1
                }
            case "--mouse-speed":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    config.mouseSpeed = max(1, value)
                    index += 1
                }
            case "--deadzone":
                if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                    config.deadzone = min(max(0, value), 0.95)
                    index += 1
                }
            case "--invert-x":
                config.invertX = true
            case "--invert-y":
                config.invertY = true
            case "--invert-mouse-x":
                config.invertMouseX = true
            case "--invert-mouse-y":
                config.invertMouseY = true
            case "--no-horizontal":
                config.disableHorizontal = true
            case "--no-mouse":
                config.disableMouse = true
            case "--no-clicks":
                config.disableClicks = true
            case "--no-fn", "--no-dictation":
                config.disableDictation = true
            case "--debug":
                config.debug = true
            case "--diagnose":
                config.debug = true
                config.diagnose = true
            case "--test-scroll":
                config.testScroll = true
            case "--right-stick":
                if index + 1 < arguments.count, let pair = AxisPair(rawValue: arguments[index + 1]) {
                    config.rightStick = pair
                    index += 1
                } else if index + 1 < arguments.count, arguments[index + 1] == "auto" {
                    config.rightStick = nil
                    index += 1
                } else {
                    print("Unknown right stick pair. Use auto, xy, rxry, or zrz.")
                    printHelpAndExit(exitCode: 1)
                }
            case "--triggers":
                if index + 1 < arguments.count, let pair = AxisPair(rawValue: arguments[index + 1]) {
                    config.triggers = pair
                    index += 1
                } else if index + 1 < arguments.count, arguments[index + 1] == "none" {
                    config.triggers = nil
                    index += 1
                } else {
                    print("Unknown trigger pair. Use none, xy, rxry, or zrz.")
                    printHelpAndExit(exitCode: 1)
                }
            case "--fn-button", "--dictation-button":
                if index + 1 < arguments.count, let button = RemoteButton(fnRawValue: arguments[index + 1]) {
                    config.dictationButton = button
                    index += 1
                } else {
                    print("Unknown dictation button. Use a, b, x, y, menu, view, home, share, lb, rb, l3, or r3.")
                    printHelpAndExit(exitCode: 1)
                }
            case "--input":
                if index + 1 < arguments.count, let mode = InputMode(rawValue: arguments[index + 1]) {
                    config.inputMode = mode
                    index += 1
                } else {
                    print("Unknown input mode. Use auto, gameController, or hid.")
                    printHelpAndExit(exitCode: 1)
                }
            case "--tap":
                if index + 1 < arguments.count {
                    switch arguments[index + 1] {
                    case "session":
                        config.eventTap = .cgSessionEventTap
                    case "hid":
                        config.eventTap = .cghidEventTap
                    default:
                        print("Unknown tap: \(arguments[index + 1])")
                        printHelpAndExit(exitCode: 1)
                    }
                    index += 1
                }
            case "--unit":
                if index + 1 < arguments.count {
                    switch arguments[index + 1] {
                    case "pixel":
                        config.unit = .pixel
                    case "line":
                        config.unit = .line
                    default:
                        print("Unknown unit: \(arguments[index + 1])")
                        printHelpAndExit(exitCode: 1)
                    }
                    index += 1
                }
            case "--help", "-h":
                printHelpAndExit()
            default:
                print("Unknown option: \(argument)")
                printHelpAndExit(exitCode: 1)
            }

            index += 1
        }

        return config
    }
}

final class ControllerScrollApp: @unchecked Sendable {
    private let config: ScrollConfiguration
    private let hidReader = HIDGamepadReader()
    private var activeController: GCController?
    private var xAxis: Float = 0
    private var yAxis: Float = 0
    private var rightXAxis: Float = 0
    private var rightYAxis: Float = 0
    private var leftTrigger: Float = 0
    private var rightTrigger: Float = 0
    private var residualX: Double = 0
    private var residualY: Double = 0
    private var residualMouseX: Double = 0
    private var residualMouseY: Double = 0
    private var leftMouseDown = false
    private var rightMouseDown = false
    private var previousButtons = Set<RemoteButton>()
    private var previousActionButtons = Set<RemoteButton>()
    private var optionCommandDown = false
    private var lastDeleteRepeat = Date.distantPast
    private var deleteHoldStartedAt: Date?
    private var lastDebugPrint = Date.distantPast
    private var lastMouseDebugPrint = Date.distantPast
    private var scanTimer: Timer?
    private var scrollTimer: Timer?

    init(config: ScrollConfiguration) {
        self.config = config
    }

    func start() {
        requestAccessibilityPermissionIfNeeded()

        if config.testScroll {
            print("Posting test scroll events for 2 seconds...")
            postTestScroll()
            print("Test complete.")
            exit(0)
        }

        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery()
        hidReader.start(debug: config.debug, diagnose: config.diagnose)

        print("Xbox scroll controller is running.")
        print("Move the left stick to scroll. Press Control-C to quit.")
        print("speed=\(Int(config.speed)), mouseSpeed=\(Int(config.mouseSpeed)), deadzone=\(String(format: "%.2f", config.deadzone)), input=\(config.inputMode.rawValue), dictation=\(config.dictationButton.name) -> hold Control, tap=\(tapName), unit=\(unitName)")
        if config.diagnose {
            print("Diagnose mode: move the right stick and press candidate Fn buttons. Watch for HID value/page lines and buttons=[...].")
        }

        scanForController()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.scanForController()
        }
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.processInputFrame()
        }
    }

    func stop() {
        scanTimer?.invalidate()
        scrollTimer?.invalidate()
        releaseMouseButtons()
        setControl(down: false)
        GCController.stopWirelessControllerDiscovery()
        hidReader.stop()
        print("\nStopped.")
    }

    private func scanForController() {
        guard activeController == nil || !(GCController.controllers().contains { $0 === activeController }) else {
            return
        }

        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }) else {
            if activeController != nil {
                print("Controller disconnected. Waiting for a controller...")
            } else {
                print("Waiting for an Xbox controller...")
            }
            activeController = nil
            xAxis = 0
            yAxis = 0
            rightXAxis = 0
            rightYAxis = 0
            leftTrigger = 0
            rightTrigger = 0
            return
        }

        activeController = controller
        let name = controller.vendorName ?? controller.productCategory
        print("Connected: \(name)")

        controller.extendedGamepad?.valueChangedHandler = { [weak self] gamepad, _ in
            let xValue = gamepad.leftThumbstick.xAxis.value
            let yValue = gamepad.leftThumbstick.yAxis.value
            let rightXValue = gamepad.rightThumbstick.xAxis.value
            let rightYValue = gamepad.rightThumbstick.yAxis.value
            let leftTriggerValue = gamepad.leftTrigger.value
            let rightTriggerValue = gamepad.rightTrigger.value
            DispatchQueue.main.async {
                self?.xAxis = xValue
                self?.yAxis = yValue
                self?.rightXAxis = rightXValue
                self?.rightYAxis = rightYValue
                self?.leftTrigger = leftTriggerValue
                self?.rightTrigger = rightTriggerValue
            }
        }
    }

    private func processInputFrame() {
        if let gamepad = activeController?.extendedGamepad {
            xAxis = gamepad.leftThumbstick.xAxis.value
            yAxis = gamepad.leftThumbstick.yAxis.value
            rightXAxis = gamepad.rightThumbstick.xAxis.value
            rightYAxis = gamepad.rightThumbstick.yAxis.value
            leftTrigger = gamepad.leftTrigger.value
            rightTrigger = gamepad.rightTrigger.value
        }

        emitScrollIfNeeded()
        emitMouseMoveIfNeeded()
        emitClicksIfNeeded()
        emitDictationShortcutIfNeeded()
        emitActionButtonsIfNeeded()
    }

    private func emitScrollIfNeeded() {
        let hidAxes = hidReader.axes(pair: .xY)
        let selectedAxes = selectAxes(gameController: (xAxis, yAxis), hid: hidAxes)
        let x = filteredAxis(selectedAxes.x)
        let y = filteredAxis(selectedAxes.y)

        guard x != 0 || y != 0 else {
            residualX = 0
            residualY = 0
            printDebugIfNeeded(
                gameControllerX: xAxis,
                gameControllerY: yAxis,
                hidX: hidAxes.x,
                hidY: hidAxes.y,
                source: selectedAxes.source,
                filteredX: x,
                filteredY: y,
                horizontal: 0,
                vertical: 0
            )
            return
        }

        let horizontalSign = config.invertX ? -1.0 : 1.0
        let verticalSign = config.invertY ? -1.0 : 1.0

        if !config.disableHorizontal {
            residualX += Double(x) * config.speed * horizontalSign
        }
        residualY += Double(y) * config.speed * verticalSign

        let horizontalPixels = takeWholePixels(from: &residualX)
        let verticalPixels = takeWholePixels(from: &residualY)

        guard horizontalPixels != 0 || verticalPixels != 0 else {
            printDebugIfNeeded(
                gameControllerX: xAxis,
                gameControllerY: yAxis,
                hidX: hidAxes.x,
                hidY: hidAxes.y,
                source: selectedAxes.source,
                filteredX: x,
                filteredY: y,
                horizontal: 0,
                vertical: 0
            )
            return
        }

        postScroll(horizontal: horizontalPixels, vertical: verticalPixels)
        printDebugIfNeeded(
            gameControllerX: xAxis,
            gameControllerY: yAxis,
            hidX: hidAxes.x,
            hidY: hidAxes.y,
            source: selectedAxes.source,
            filteredX: x,
            filteredY: y,
            horizontal: horizontalPixels,
            vertical: verticalPixels
        )
    }

    private func emitMouseMoveIfNeeded() {
        guard !config.disableMouse else {
            return
        }

        let hidRightAxes = hidReader.axesForPointer(configuredPair: config.rightStick, triggerPair: config.triggers)
        let selectedAxes = selectAxes(gameController: (rightXAxis, rightYAxis), hid: hidRightAxes)
        let x = filteredAxis(selectedAxes.x)
        let y = filteredAxis(selectedAxes.y)

        guard x != 0 || y != 0 else {
            residualMouseX = 0
            residualMouseY = 0
            printMouseDebugIfNeeded(
                gameControllerX: rightXAxis,
                gameControllerY: rightYAxis,
                hidX: hidRightAxes.x,
                hidY: hidRightAxes.y,
                source: selectedAxes.source,
                filteredX: x,
                filteredY: y,
                dx: 0,
                dy: 0
            )
            return
        }

        let horizontalSign = config.invertMouseX ? -1.0 : 1.0
        let verticalSign = config.invertMouseY ? -1.0 : 1.0

        residualMouseX += Double(x) * config.mouseSpeed * horizontalSign
        residualMouseY += Double(y) * config.mouseSpeed * verticalSign

        let dx = takeWholePixels(from: &residualMouseX)
        let dy = takeWholePixels(from: &residualMouseY)

        guard dx != 0 || dy != 0 else {
            printMouseDebugIfNeeded(
                gameControllerX: rightXAxis,
                gameControllerY: rightYAxis,
                hidX: hidRightAxes.x,
                hidY: hidRightAxes.y,
                source: selectedAxes.source,
                filteredX: x,
                filteredY: y,
                dx: 0,
                dy: 0
            )
            return
        }

        moveMouseBy(x: CGFloat(dx), y: CGFloat(dy))
        printMouseDebugIfNeeded(
            gameControllerX: rightXAxis,
            gameControllerY: rightYAxis,
            hidX: hidRightAxes.x,
            hidY: hidRightAxes.y,
            source: selectedAxes.source,
            filteredX: x,
            filteredY: y,
            dx: dx,
            dy: dy
        )
    }

    private func emitClicksIfNeeded() {
        guard !config.disableClicks else {
            releaseMouseButtons()
            return
        }

        let hidTriggers = config.triggers.map { hidReader.axes(pair: $0) } ?? (x: 0, y: 0)
        let leftPressed = isTriggerPressed(gameControllerValue: leftTrigger, hidValue: hidTriggers.x)
        let rightPressed = isTriggerPressed(gameControllerValue: rightTrigger, hidValue: hidTriggers.y)

        setMouseButton(.right, down: leftPressed)
        setMouseButton(.left, down: rightPressed)
    }

    private func emitDictationShortcutIfNeeded() {
        let buttons = currentRemoteButtons()
        defer {
            previousButtons = buttons
        }

        guard !config.disableDictation else {
            return
        }

        setControl(down: buttons.contains(config.dictationButton))
    }

    private func emitActionButtonsIfNeeded() {
        let buttons = currentRemoteButtons()
        defer {
            previousActionButtons = buttons
        }

        for button in buttons.subtracting(previousActionButtons) {
            handleActionButton(button)
        }

        handleDeleteRepeat(isPressed: buttons.contains(.rightShoulder))
    }

    private func handleActionButton(_ button: RemoteButton) {
        switch button {
        case .a:
            postKey(.returnKey)
            printActionDebug("A -> Return")
        case .x:
            postKey(.v, flags: .maskCommand)
            printActionDebug("X -> Command-V")
        case .y:
            postKey(.c, flags: .maskCommand)
            printActionDebug("Y -> Command-C")
        case .leftShoulder:
            postKey(.z, flags: .maskCommand)
            printActionDebug("LB -> Command-Z")
        case .rightShoulder:
            postKey(.delete)
            printActionDebug("RB -> Delete")
        case .dpadLeft:
            guard isDpadSpaceSwitchAllowed() else {
                printActionDebug("D-pad left ignored while stick is active")
                break
            }
            switchSpace(with: .leftArrow)
            printActionDebug("D-pad left -> Control-Left")
        case .dpadRight:
            guard isDpadSpaceSwitchAllowed() else {
                printActionDebug("D-pad right ignored while stick is active")
                break
            }
            switchSpace(with: .rightArrow)
            printActionDebug("D-pad right -> Control-Right")
        default:
            break
        }
    }

    private func handleDeleteRepeat(isPressed: Bool) {
        guard isPressed else {
            deleteHoldStartedAt = nil
            lastDeleteRepeat = .distantPast
            return
        }

        let now = Date()
        if deleteHoldStartedAt == nil {
            deleteHoldStartedAt = now
            lastDeleteRepeat = now
            return
        }

        guard let startedAt = deleteHoldStartedAt, now.timeIntervalSince(startedAt) >= 0.35 else {
            return
        }

        guard now.timeIntervalSince(lastDeleteRepeat) >= 0.06 else {
            return
        }

        lastDeleteRepeat = now
        postKey(.delete)
        printActionDebug("RB -> Delete repeat")
    }

    private func printActionDebug(_ message: String) {
        guard config.debug else {
            return
        }

        print("Action: \(message)")
    }

    private func currentRemoteButtons() -> Set<RemoteButton> {
        var buttons = Set<RemoteButton>()

        for button in hidReader.buttons {
            if let remoteButton = RemoteButton(hidUsage: button) {
                buttons.insert(remoteButton)
            }
        }
        if let gamepad = activeController?.extendedGamepad {
            if gamepad.buttonA.isPressed { buttons.insert(.a) }
            if gamepad.buttonB.isPressed { buttons.insert(.b) }
            if gamepad.buttonX.isPressed { buttons.insert(.x) }
            if gamepad.buttonY.isPressed { buttons.insert(.y) }
            if isDpadSpaceSwitchAllowed() {
                if gamepad.dpad.left.isPressed { buttons.insert(.dpadLeft) }
                if gamepad.dpad.right.isPressed { buttons.insert(.dpadRight) }
            }
            if gamepad.leftShoulder.isPressed { buttons.insert(.leftShoulder) }
            if gamepad.rightShoulder.isPressed { buttons.insert(.rightShoulder) }
            if gamepad.leftThumbstickButton?.isPressed == true { buttons.insert(.leftThumbstick) }
            if gamepad.rightThumbstickButton?.isPressed == true { buttons.insert(.rightThumbstick) }
            if gamepad.buttonMenu.isPressed { buttons.insert(.menu) }
            if gamepad.buttonOptions?.isPressed == true { buttons.insert(.view) }
            if gamepad.buttonHome?.isPressed == true { buttons.insert(.home) }
            if let xboxGamepad = gamepad as? GCXboxGamepad, xboxGamepad.buttonShare?.isPressed == true {
                buttons.insert(.share)
            }
        }

        if config.debug, !buttons.isEmpty {
            printRemoteButtonsIfNeeded(buttons)
        }

        return buttons
    }

    private func isDpadSpaceSwitchAllowed() -> Bool {
        if abs(xAxis) > config.deadzone || abs(yAxis) > config.deadzone {
            return false
        }

        if abs(rightXAxis) > config.deadzone || abs(rightYAxis) > config.deadzone {
            return false
        }

        let hidLeftAxes = hidReader.axes(pair: .xY)
        if abs(hidLeftAxes.x) > config.deadzone || abs(hidLeftAxes.y) > config.deadzone {
            return false
        }

        let hidRightAxes = hidReader.axesForPointer(configuredPair: config.rightStick, triggerPair: config.triggers)
        if abs(hidRightAxes.x) > config.deadzone || abs(hidRightAxes.y) > config.deadzone {
            return false
        }

        return true
    }

    private func selectAxes(
        gameController: (x: Float, y: Float),
        hid: (x: Float, y: Float)
    ) -> (x: Float, y: Float, source: String) {
        switch config.inputMode {
        case .gameController:
            return (gameController.x, gameController.y, "gameController")
        case .hid:
            return (hid.x, hid.y, "hid")
        case .auto:
            if abs(gameController.x) > config.deadzone || abs(gameController.y) > config.deadzone {
                return (gameController.x, gameController.y, "gameController")
            }
            return (hid.x, hid.y, "hid")
        }
    }

    private func postScroll(horizontal: Int32, vertical: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: config.unit,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else {
            return
        }

        if let mouseEvent = CGEvent(source: nil) {
            event.location = mouseEvent.location
        }

        event.post(tap: config.eventTap)
    }

    private func moveMouseBy(x: CGFloat, y: CGFloat) {
        guard let mouseEvent = CGEvent(source: nil) else {
            return
        }

        let current = mouseEvent.location
        let destination = CGPoint(x: current.x + x, y: current.y + y)
        CGWarpMouseCursorPosition(destination)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        postMouseEvent(type: .mouseMoved, at: destination, button: .left)
    }

    private func setMouseButton(_ button: CGMouseButton, down: Bool) {
        switch button {
        case .left:
            guard down != leftMouseDown else {
                return
            }
            leftMouseDown = down
            postMouseEvent(type: down ? .leftMouseDown : .leftMouseUp, button: .left)
        case .right:
            guard down != rightMouseDown else {
                return
            }
            rightMouseDown = down
            postMouseEvent(type: down ? .rightMouseDown : .rightMouseUp, button: .right)
        default:
            break
        }
    }

    private func releaseMouseButtons() {
        setMouseButton(.left, down: false)
        setMouseButton(.right, down: false)
    }

    private func postMouseEvent(type: CGEventType, at location: CGPoint? = nil, button: CGMouseButton) {
        let target = location ?? CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: button) else {
            return
        }

        event.post(tap: config.eventTap)
    }

    private func postKey(_ key: KeyCode, flags: CGEventFlags = [], tap: CGEventTapLocation? = nil) {
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: key.rawValue, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: key.rawValue, keyDown: false)
        else {
            return
        }

        down.flags = flags
        up.flags = flags
        down.post(tap: tap ?? config.eventTap)
        up.post(tap: tap ?? config.eventTap)
    }

    private func postControlArrow(_ key: KeyCode) {
        let tap = CGEventTapLocation.cghidEventTap
        postModifier(.control, down: true, flags: .maskControl, tap: tap)
        usleep(12_000)
        postKey(key, flags: .maskControl, tap: tap)
        usleep(12_000)
        postModifier(.control, down: false, flags: [], tap: tap)
    }

    private func switchSpace(with key: KeyCode) {
        if postControlArrowViaSystemEvents(key) {
            return
        }

        postControlArrow(key)
    }

    private func postControlArrowViaSystemEvents(_ key: KeyCode) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"System Events\" to key code \(Int(key.rawValue)) using control down"
        ]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            if config.debug {
                print("System Events shortcut failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    private func setControl(down: Bool) {
        guard down != optionCommandDown else {
            return
        }

        optionCommandDown = down
        if down {
            postModifier(.control, down: true, flags: .maskControl)
        } else {
            postModifier(.control, down: false, flags: [])
        }

        if config.debug {
            print("Control \(down ? "down" : "up") via \(config.dictationButton.name)")
        }
    }

    private func postModifier(_ key: ModifierKey, down: Bool, flags: CGEventFlags, tap: CGEventTapLocation? = nil) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key.rawValue, keyDown: down) else {
            return
        }

        event.flags = flags
        event.post(tap: tap ?? config.eventTap)
    }

    private func postTestScroll() {
        print("Move the pointer over a scrollable area. Test starts in 3 seconds...")
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        for _ in 0..<120 {
            postScroll(horizontal: 0, vertical: -8)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }
    }

    private func printDebugIfNeeded(
        gameControllerX: Float,
        gameControllerY: Float,
        hidX: Float,
        hidY: Float,
        source: String,
        filteredX: Float,
        filteredY: Float,
        horizontal: Int32,
        vertical: Int32
    ) {
        guard config.debug else {
            return
        }

        if config.diagnose, horizontal == 0, vertical == 0 {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastDebugPrint) >= 0.2 else {
            return
        }

        lastDebugPrint = now
        print(
            String(
                format: "gc=(%.3f, %.3f) hid=(%.3f, %.3f) source=%@ filtered=(%.3f, %.3f) scroll=(%d, %d)",
                gameControllerX,
                gameControllerY,
                hidX,
                hidY,
                source,
                filteredX,
                filteredY,
                horizontal,
                vertical
            )
        )
    }

    private func printMouseDebugIfNeeded(
        gameControllerX: Float,
        gameControllerY: Float,
        hidX: Float,
        hidY: Float,
        source: String,
        filteredX: Float,
        filteredY: Float,
        dx: Int32,
        dy: Int32
    ) {
        guard config.debug else {
            return
        }

        if config.diagnose, dx == 0, dy == 0 {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastMouseDebugPrint) >= 0.2 else {
            return
        }

        lastMouseDebugPrint = now
        print(
            String(
                format: "mouse gc=(%.3f, %.3f) hid=(%.3f, %.3f) source=%@ filtered=(%.3f, %.3f) move=(%d, %d)",
                gameControllerX,
                gameControllerY,
                hidX,
                hidY,
                source,
                filteredX,
                filteredY,
                dx,
                dy
            )
        )
    }

    private func printRemoteButtonsIfNeeded(_ buttons: Set<RemoteButton>) {
        let now = Date()
        guard now.timeIntervalSince(lastDebugPrint) >= 0.2 else {
            return
        }

        lastDebugPrint = now
        let names = buttons.map(\.name).sorted().joined(separator: ",")
        print("buttons=[\(names)]")
    }

    private func filteredAxis(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude >= config.deadzone else {
            return 0
        }

        let normalized = (magnitude - config.deadzone) / (1 - config.deadzone)
        return copysign(normalized * normalized, value)
    }

    private func isTriggerPressed(gameControllerValue: Float, hidValue: Float) -> Bool {
        if gameControllerValue > 0.55 {
            return true
        }

        return hidValue > 0.55
    }

    private func takeWholePixels(from value: inout Double) -> Int32 {
        let whole = value.rounded(.towardZero)
        value -= whole
        return Int32(whole)
    }

    private var tapName: String {
        config.eventTap == .cgSessionEventTap ? "session" : "hid"
    }

    private var unitName: String {
        config.unit == .pixel ? "pixel" : "line"
    }
}

final class HIDGamepadReader {
    private var manager: IOHIDManager?
    private var axisValues: [UInt32: Float] = [:]
    private var buttonValues = Set<UInt32>()
    private var lastAxisDebugPrint: [UInt32: Date] = [:]
    private var lastButtonDebugPrint: [UInt32: Date] = [:]
    private var lastDiagnosticRawValues: [String: Int] = [:]
    private var lastDiagnosticPrint: [String: Date] = [:]
    private var debug = false
    private var diagnose = false

    var buttons: Set<UInt32> {
        buttonValues
    }

    var axes: (x: Float, y: Float) {
        for pair in axisPairs {
            let xValue = axisValues[pair.x] ?? 0
            let yValue = axisValues[pair.y] ?? 0

            if abs(xValue) > 0.02 || abs(yValue) > 0.02 {
                return (xValue, yValue)
            }
        }

        return (
            axisValues[UInt32(kHIDUsage_GD_X)] ?? 0,
            axisValues[UInt32(kHIDUsage_GD_Y)] ?? 0
        )
    }

    func axes(pair: ScrollConfiguration.AxisPair) -> (x: Float, y: Float) {
        let usages = pair.usages
        return (
            axisValues[usages.x] ?? 0,
            axisValues[usages.y] ?? 0
        )
    }

    func axesForPointer(
        configuredPair: ScrollConfiguration.AxisPair?,
        triggerPair: ScrollConfiguration.AxisPair?
    ) -> (x: Float, y: Float) {
        if let configuredPair {
            return axes(pair: configuredPair)
        }

        let candidates = axisPairs.filter { pair in
            if pair.x == UInt32(kHIDUsage_GD_X) || pair.y == UInt32(kHIDUsage_GD_Y) {
                return false
            }

            guard let triggerPair else {
                return true
            }

            let triggerUsages = triggerPair.usages
            return pair.x != triggerUsages.x && pair.y != triggerUsages.y
        }

        if let activePair = candidates.max(by: { magnitude($0) < magnitude($1) }), magnitude(activePair) > 0.02 {
            return (
                axisValues[activePair.x] ?? 0,
                axisValues[activePair.y] ?? 0
            )
        }

        let fallback = ScrollConfiguration.AxisPair.rxRy.usages
        return (
            axisValues[fallback.x] ?? 0,
            axisValues[fallback.y] ?? 0
        )
    }

    func start(debug: Bool, diagnose: Bool) {
        self.debug = debug
        self.diagnose = diagnose

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matches: [[String: Int]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_GamePad
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Joystick
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_MultiAxisController
            ]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, HIDGamepadReader.deviceMatched, context)
        IOHIDManagerRegisterInputValueCallback(manager, HIDGamepadReader.inputValueChanged, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if debug {
            print("HID manager open result: \(openResult)")
            printMatchedDevices(manager)
        }
    }

    func stop() {
        guard let manager else {
            return
        }

        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private func handle(device: IOHIDDevice) {
        guard debug else {
            return
        }

        print("HID connected: \(deviceName(device))")
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)

        printDiagnosticValueIfNeeded(value: value, element: element, usagePage: usagePage, usage: usage)

        if usagePage == UInt32(kHIDPage_Button) {
            handleButton(usage: usage, pressed: IOHIDValueGetIntegerValue(value) != 0)
            return
        }

        guard usagePage == UInt32(kHIDPage_GenericDesktop), Self.axisUsageNames.keys.contains(usage) else {
            return
        }

        let normalized = normalize(value: value, element: element)
        axisValues[usage] = normalized

        printAxisDebugIfNeeded(usage: usage, value: normalized)
    }

    private func handleButton(usage: UInt32, pressed: Bool) {
        if pressed {
            buttonValues.insert(usage)
        } else {
            buttonValues.remove(usage)
        }

        printButtonDebugIfNeeded(usage: usage, pressed: pressed)
    }

    private func normalize(value: IOHIDValue, element: IOHIDElement) -> Float {
        let integerValue = Double(IOHIDValueGetIntegerValue(value))
        let minValue = Double(IOHIDElementGetLogicalMin(element))
        let maxValue = Double(IOHIDElementGetLogicalMax(element))

        guard maxValue > minValue else {
            return 0
        }

        let center = (minValue + maxValue) / 2
        let radius = (maxValue - minValue) / 2
        let normalized = (integerValue - center) / radius
        return Float(max(-1, min(1, normalized)))
    }

    private func printMatchedDevices(_ manager: IOHIDManager) {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            print("HID matched devices: none")
            return
        }

        for device in devices {
            print("HID matched: \(deviceName(device))")
        }
    }

    private func deviceName(_ device: IOHIDDevice) -> String {
        if let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
            return product
        }
        return "Unknown HID device"
    }

    private func printAxisDebugIfNeeded(usage: UInt32, value: Float) {
        guard debug, abs(value) > 0.02 else {
            return
        }

        let now = Date()
        if let lastPrint = lastAxisDebugPrint[usage], now.timeIntervalSince(lastPrint) < 0.15 {
            return
        }

        lastAxisDebugPrint[usage] = now
        let name = Self.axisUsageNames[usage] ?? String(format: "0x%02x", usage)
        print(String(format: "HID axis %@ = %.3f", name, value))
    }

    private func printButtonDebugIfNeeded(usage: UInt32, pressed: Bool) {
        guard debug else {
            return
        }

        let now = Date()
        if let lastPrint = lastButtonDebugPrint[usage], now.timeIntervalSince(lastPrint) < 0.1 {
            return
        }

        lastButtonDebugPrint[usage] = now
        let name = XboxHIDButton(rawValue: usage)?.name ?? "button\(usage)"
        print("HID button \(name) \(pressed ? "down" : "up")")
    }

    private func printDiagnosticValueIfNeeded(
        value: IOHIDValue,
        element: IOHIDElement,
        usagePage: UInt32,
        usage: UInt32
    ) {
        guard diagnose else {
            return
        }

        let rawValue = IOHIDValueGetIntegerValue(value)
        let key = "\(usagePage):\(usage)"

        if lastDiagnosticRawValues[key] == rawValue {
            return
        }

        let now = Date()
        if let lastPrint = lastDiagnosticPrint[key], now.timeIntervalSince(lastPrint) < 0.08 {
            return
        }

        lastDiagnosticRawValues[key] = rawValue
        lastDiagnosticPrint[key] = now

        let minValue = IOHIDElementGetLogicalMin(element)
        let maxValue = IOHIDElementGetLogicalMax(element)
        let normalized = normalize(value: value, element: element)
        print(
            String(
                format: "HID value page=%@ usage=%@ raw=%ld min=%ld max=%ld normalized=%.3f",
                pageName(usagePage),
                usageName(page: usagePage, usage: usage),
                rawValue,
                minValue,
                maxValue,
                normalized
            )
        )
    }

    private var axisPairs: [(x: UInt32, y: UInt32)] {
        [
            (UInt32(kHIDUsage_GD_X), UInt32(kHIDUsage_GD_Y)),
            (UInt32(kHIDUsage_GD_Rx), UInt32(kHIDUsage_GD_Ry)),
            (UInt32(kHIDUsage_GD_Z), UInt32(kHIDUsage_GD_Rz))
        ]
    }

    private static let axisUsageNames: [UInt32: String] = [
        UInt32(kHIDUsage_GD_X): "X",
        UInt32(kHIDUsage_GD_Y): "Y",
        UInt32(kHIDUsage_GD_Z): "Z",
        UInt32(kHIDUsage_GD_Rx): "Rx",
        UInt32(kHIDUsage_GD_Ry): "Ry",
            UInt32(kHIDUsage_GD_Rz): "Rz"
    ]

    private func pageName(_ page: UInt32) -> String {
        switch page {
        case UInt32(kHIDPage_GenericDesktop):
            return "GenericDesktop(0x01)"
        case UInt32(kHIDPage_Button):
            return "Button(0x09)"
        case UInt32(kHIDPage_Consumer):
            return "Consumer(0x0c)"
        default:
            return String(format: "0x%02x", page)
        }
    }

    private func usageName(page: UInt32, usage: UInt32) -> String {
        if page == UInt32(kHIDPage_GenericDesktop), let name = Self.axisUsageNames[usage] {
            return "\(name)(\(usage))"
        }

        if page == UInt32(kHIDPage_Button) {
            let name = XboxHIDButton(rawValue: usage)?.name ?? "button\(usage)"
            return "\(name)(\(usage))"
        }

        return String(format: "0x%02x", usage)
    }

    private func magnitude(_ pair: (x: UInt32, y: UInt32)) -> Float {
        let xValue = axisValues[pair.x] ?? 0
        let yValue = axisValues[pair.y] ?? 0
        return max(abs(xValue), abs(yValue))
    }

    private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }

        let reader = Unmanaged<HIDGamepadReader>.fromOpaque(context).takeUnretainedValue()
        reader.handle(device: device)
    }

    private static let inputValueChanged: IOHIDValueCallback = { context, _, _, value in
        guard let context else {
            return
        }

        let reader = Unmanaged<HIDGamepadReader>.fromOpaque(context).takeUnretainedValue()
        reader.handle(value: value)
    }
}

enum RemoteButton: Hashable {
    case a
    case b
    case x
    case y
    case dpadLeft
    case dpadRight
    case leftShoulder
    case rightShoulder
    case view
    case menu
    case home
    case share
    case leftThumbstick
    case rightThumbstick

    init?(hidUsage: UInt32) {
        switch hidUsage {
        case 1:
            self = .a
        case 2:
            self = .b
        case 3:
            self = .x
        case 4:
            self = .y
        case 7:
            self = .leftShoulder
        case 8:
            self = .rightShoulder
        case 9:
            self = .leftThumbstick
        case 10:
            self = .rightThumbstick
        case 11:
            self = .view
        case 12:
            self = .menu
        default:
            return nil
        }
    }

    init?(fnRawValue: String) {
        switch fnRawValue {
        case "a":
            self = .a
        case "b":
            self = .b
        case "x":
            self = .x
        case "y":
            self = .y
        case "menu":
            self = .menu
        case "view":
            self = .view
        case "home":
            self = .home
        case "share":
            self = .share
        case "lb":
            self = .leftShoulder
        case "rb":
            self = .rightShoulder
        case "l3":
            self = .leftThumbstick
        case "r3":
            self = .rightThumbstick
        default:
            return nil
        }
    }

    var name: String {
        switch self {
        case .a:
            return "A"
        case .b:
            return "B"
        case .x:
            return "X"
        case .y:
            return "Y"
        case .dpadLeft:
            return "DPadLeft"
        case .dpadRight:
            return "DPadRight"
        case .leftShoulder:
            return "LB"
        case .rightShoulder:
            return "RB"
        case .view:
            return "View"
        case .menu:
            return "Menu/Fn"
        case .home:
            return "Home"
        case .share:
            return "Share"
        case .leftThumbstick:
            return "L3"
        case .rightThumbstick:
            return "R3"
        }
    }
}

enum XboxHIDButton: UInt32 {
    case a = 1
    case b = 2
    case x = 3
    case y = 4
    case leftThumbstick = 9
    case rightThumbstick = 10
    case view = 11
    case menu = 12
    case leftShoulder = 7
    case rightShoulder = 8

    var name: String {
        RemoteButton(hidUsage: rawValue)?.name ?? "button\(rawValue)"
    }
}

enum KeyCode: CGKeyCode {
    case a = 0
    case d = 2
    case c = 8
    case v = 9
    case z = 6
    case w = 13
    case tab = 48
    case returnKey = 36
    case escape = 53
    case leftBracket = 33
    case rightBracket = 30
    case leftArrow = 123
    case rightArrow = 124
    case upArrow = 126
    case delete = 51
}

enum ModifierKey: CGKeyCode {
    case control = 0x3B
    case command = 0x37
    case option = 0x3A
}

private func requestAccessibilityPermissionIfNeeded() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary

    if AXIsProcessTrustedWithOptions(options) {
        print("Accessibility permission: granted")
    } else {
        print("Accessibility permission: not granted")
        print("Accessibility permission is required to post system scroll events.")
        print("Open System Settings -> Privacy & Security -> Accessibility, then allow this terminal/app and run again if scrolling does not work.")
    }
}

private func printHelpAndExit(exitCode: Int32 = 0) -> Never {
    print(
        """
        Usage:
          swift run xbox-scroll [options]

        Options:
          --speed <number>      Scroll speed in pixels per frame. Default: 18
          --mouse-speed <num>   Pointer speed in pixels per frame. Default: 18
          --deadzone <number>   Stick deadzone from 0.0 to 0.95. Default: 0.16
          --invert-x            Reverse horizontal scrolling
          --invert-y            Reverse vertical scrolling
          --invert-mouse-x      Reverse horizontal pointer movement
          --invert-mouse-y      Reverse vertical pointer movement
          --no-horizontal       Disable horizontal scrolling
          --no-mouse            Disable right-stick pointer movement
          --no-clicks           Disable trigger mouse clicks
          --no-fn               Disable dictation shortcut trigger
          --no-dictation        Disable dictation shortcut trigger
          --debug               Print live stick values and scroll deltas
          --diagnose            Print raw HID values for mapping unknown controls
          --test-scroll         Post scroll events without using the controller
          --input <mode>        Input source: auto, gameController, or hid. Default: auto
          --right-stick <pair>  Right stick HID axis pair: auto, xy, rxry, or zrz. Default: auto
          --triggers <pair>     Trigger HID axis pair: none, xy, rxry, or zrz. Default: none
          --fn-button <button>  Alias for --dictation-button
          --dictation-button <button>
                                Gamepad button that holds Control. Default: b
          --tap <session|hid>   Event tap target. Default: session
          --unit <pixel|line>   Scroll units. Default: pixel
          -h, --help            Show this help
        """
    )
    exit(exitCode)
}

setbuf(stdout, nil)

let app = ControllerScrollApp(config: .parse(arguments: CommandLine.arguments))

let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
signalSource.setEventHandler {
    app.stop()
    exit(0)
}
signalSource.resume()

app.start()
RunLoop.main.run()
