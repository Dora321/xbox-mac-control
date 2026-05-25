import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import GameController
import IOKit.hid

struct ScrollConfiguration {
    var speed: Double = 18
    var deadzone: Float = 0.16
    var invertX = false
    var invertY = false
    var disableHorizontal = false
    var debug = false
    var testScroll = false
    var inputMode: InputMode = .auto
    var eventTap: CGEventTapLocation = .cgSessionEventTap
    var unit: CGScrollEventUnit = .pixel

    enum InputMode: String {
        case auto
        case gameController
        case hid
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
            case "--deadzone":
                if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                    config.deadzone = min(max(0, value), 0.95)
                    index += 1
                }
            case "--invert-x":
                config.invertX = true
            case "--invert-y":
                config.invertY = true
            case "--no-horizontal":
                config.disableHorizontal = true
            case "--debug":
                config.debug = true
            case "--test-scroll":
                config.testScroll = true
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
    private var residualX: Double = 0
    private var residualY: Double = 0
    private var lastDebugPrint = Date.distantPast
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
        hidReader.start(debug: config.debug)

        print("Xbox scroll controller is running.")
        print("Move the left stick to scroll. Press Control-C to quit.")
        print("speed=\(Int(config.speed)), deadzone=\(String(format: "%.2f", config.deadzone)), input=\(config.inputMode.rawValue), tap=\(tapName), unit=\(unitName)")

        scanForController()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.scanForController()
        }
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.emitScrollIfNeeded()
        }
    }

    func stop() {
        scanTimer?.invalidate()
        scrollTimer?.invalidate()
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
            return
        }

        activeController = controller
        let name = controller.vendorName ?? controller.productCategory
        print("Connected: \(name)")

        controller.extendedGamepad?.valueChangedHandler = { [weak self] gamepad, _ in
            let xValue = gamepad.leftThumbstick.xAxis.value
            let yValue = gamepad.leftThumbstick.yAxis.value
            DispatchQueue.main.async {
                self?.xAxis = xValue
                self?.yAxis = yValue
            }
        }
    }

    private func emitScrollIfNeeded() {
        if let gamepad = activeController?.extendedGamepad {
            xAxis = gamepad.leftThumbstick.xAxis.value
            yAxis = gamepad.leftThumbstick.yAxis.value
        }

        let hidAxes = hidReader.axes
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

    private func filteredAxis(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude >= config.deadzone else {
            return 0
        }

        let normalized = (magnitude - config.deadzone) / (1 - config.deadzone)
        return copysign(normalized * normalized, value)
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
    private var lastAxisDebugPrint: [UInt32: Date] = [:]
    private var debug = false

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

    func start(debug: Bool) {
        self.debug = debug

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
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_GenericDesktop) else {
            return
        }

        let usage = IOHIDElementGetUsage(element)
        guard Self.axisUsageNames.keys.contains(usage) else {
            return
        }

        let normalized = normalize(value: value, element: element)
        axisValues[usage] = normalized

        printAxisDebugIfNeeded(usage: usage, value: normalized)
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
          --deadzone <number>   Stick deadzone from 0.0 to 0.95. Default: 0.16
          --invert-x            Reverse horizontal scrolling
          --invert-y            Reverse vertical scrolling
          --no-horizontal       Disable horizontal scrolling
          --debug               Print live stick values and scroll deltas
          --test-scroll         Post scroll events without using the controller
          --input <mode>        Input source: auto, gameController, or hid. Default: auto
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
