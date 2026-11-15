// SPDX-License-Identifier: GPL-2.0-or-later
import Metal
import QuartzCore
import SwiftUI
import UIKit

final class MetalCanvasUIView: UIView, UIKeyInput {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var trackpadMode: Bool = false
    var rightClickArmed: Bool = false
    var onRightClickConsumed: (() -> Void)?
    var onThreeFingerTap: (() -> Void)?

    private var activeDragButtons: UInt8 = 0
    private var panLastPoint: CGPoint = .zero
    var inputEnabled = true
    var viewportControlsActive = false
    var viewportZoomed = false
    private weak var fingerScrollRecognizer: UIPanGestureRecognizer?
    var softwareKeyboardVisible = false
    private let hiddenKeyboardView = UIView(frame: .zero)
    private var physicalButtons: UInt8 = 0
    private var pencilButton: UInt8 = 0
    private var pressedUsages: Set<UInt8> = []
    private var physicalKeyMap: [UInt8: UInt8] = [:]
    private var softwareKeys: [(UInt8, Bool)] = []
    private var softwareTyping = false
    private var inputGeneration: UInt = 0
    private var scrollAccum = CGPoint.zero
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        accessibilityLabel = "Windows guest display"
        accessibilityHint = "Tap to click, long press to right-click, or use a hardware keyboard and pointer."

        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resizeAspect
        updateDrawableScale()

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTouchesRequired = 1
        singleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        singleTap.require(toFail: twoFingerTap)
        addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerTap.require(toFail: threeFingerTap)
        addGestureRecognizer(threeFingerTap)

        let dragPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        dragPan.minimumNumberOfTouches = 1
        dragPan.maximumNumberOfTouches = 1
        dragPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(dragPan)

        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        if #available(iOS 13.4, *) {
            scrollPan.allowedScrollTypesMask = .all
        }
        scrollPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerScrollRecognizer = scrollPan
        addGestureRecognizer(scrollPan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowableMovement = 12
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        singleTap.require(toFail: longPress)
        addGestureRecognizer(longPress)

        if #available(iOS 13.4, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(hover)
            let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll(_:)))
            wheel.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            wheel.allowedScrollTypesMask = .all
            wheel.cancelsTouchesInView = false
            addGestureRecognizer(wheel)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(releaseInput),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableScale()
        if window != nil {
            WinIOSBridge.shared.bindMetalLayer(metalLayer)
            if inputEnabled { becomeFirstResponder() }
        } else {
            releaseInput()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableScale()
    }

    private func updateDrawableScale() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let w = max(1.0, bounds.width * scale)
        let h = max(1.0, bounds.height * scale)
        metalLayer.drawableSize = CGSize(width: w, height: h)
        if let winBounds = window?.bounds.size, winBounds.width > 0 {
            WinIOSBridge.shared.updateScreenSize(winBounds, scale: scale)
        }
    }

    private func normalizedPoint(for pt: CGPoint) -> (Double, Double) {
        let bw = max(1.0, bounds.width)
        let bh = max(1.0, bounds.height)
        let fbW = Double(WinIOSBridge.shared.framebufferWidth)
        let fbH = Double(WinIOSBridge.shared.framebufferHeight)

        var rect = bounds
        if fbW > 0 && fbH > 0 {
            let viewAspect = Double(bw / bh)
            let fbAspect = fbW / fbH
            if viewAspect > fbAspect {
                let fittedW = CGFloat(Double(bh) * fbAspect)
                rect = CGRect(x: (bw - fittedW) * 0.5, y: 0, width: fittedW, height: bh)
            } else {
                let fittedH = CGFloat(Double(bw) / fbAspect)
                rect = CGRect(x: 0, y: (bh - fittedH) * 0.5, width: bw, height: fittedH)
            }
        }
        let nx = min(1.0, max(0.0, Double((pt.x - rect.minX) / max(1.0, rect.width))))
        let ny = min(1.0, max(0.0, Double((pt.y - rect.minY) / max(1.0, rect.height))))
        return (nx, ny)
    }

    @objc private func handleSingleTap(_ gr: UITapGestureRecognizer) {
        guard inputEnabled, gr.state == .ended else { return }
        tapHaptic.impactOccurred(intensity: 0.45)
        let mask: UInt8
        if rightClickArmed {
            rightClickArmed = false
            onRightClickConsumed?()
            mask = 2
        } else {
            mask = 1
        }
        if trackpadMode {
            PointerController.shared.clickAtCurrent(buttonMask: mask)
        } else {
            let (nx, ny) = normalizedPoint(for: gr.location(in: self))
            PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: mask)
        }
    }

    @objc private func handleTwoFingerTap(_ gr: UITapGestureRecognizer) {
        guard inputEnabled, gr.state == .ended else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.6)
        PointerController.shared.clickAtCurrent(buttonMask: 2)
    }

    @objc private func handleThreeFingerTap(_ gr: UITapGestureRecognizer) {
        guard inputEnabled, gr.state == .ended else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onThreeFingerTap?()
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard inputEnabled, gr.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if trackpadMode {
            PointerController.shared.clickAtCurrent(buttonMask: 2)
        } else {
            let (nx, ny) = normalizedPoint(for: gr.location(in: self))
            PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: 2)
        }
    }

    @objc private func handleOneFingerPan(_ gr: UIPanGestureRecognizer) {
        guard inputEnabled else { return }
        let loc = gr.location(in: self)
        switch gr.state {
        case .began:
            panLastPoint = loc
            if !trackpadMode {
                let (nx, ny) = normalizedPoint(for: loc)
                activeDragButtons = rightClickArmed ? 2 : 1
                if rightClickArmed {
                    rightClickArmed = false
                    onRightClickConsumed?()
                }
                PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: activeDragButtons)
            }
        case .changed:
            if trackpadMode {
                let dx = loc.x - panLastPoint.x
                let dy = loc.y - panLastPoint.y
                panLastPoint = loc
                PointerController.shared.moveRelative(
                    dxPoints: dx,
                    dyPoints: dy,
                    padWidth: bounds.width,
                    padHeight: bounds.height,
                    extraButtons: activeDragButtons
                )
            } else {
                let (nx, ny) = normalizedPoint(for: loc)
                PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: activeDragButtons)
            }
        case .ended, .cancelled, .failed:
            if activeDragButtons != 0 {
                activeDragButtons = 0
                PointerController.shared.moveAbsolute(
                    x: PointerController.shared.cursorX,
                    y: PointerController.shared.cursorY,
                    extraButtons: 0
                )
            }
        default:
            break
        }
    }

    @objc private func handleTwoFingerScroll(_ gr: UIPanGestureRecognizer) {
        guard inputEnabled else { return }
        if gr === fingerScrollRecognizer && (viewportControlsActive || viewportZoomed) { return }
        let trans = gr.translation(in: self)
        if gr.state == .began { scrollAccum = .zero }
        if gr.state == .began || gr.state == .changed {
            let vertical = Int((trans.y - scrollAccum.y) / 12)
            let horizontal = Int((trans.x - scrollAccum.x) / 12)
            if vertical != 0 || horizontal != 0 {
                scrollAccum.x += CGFloat(horizontal) * 12
                scrollAccum.y += CGFloat(vertical) * 12
                PointerController.shared.scroll(steps: Int8(clamping: vertical),
                                                 horizontalSteps: Int8(clamping: -horizontal))
            }
        }
    }

    @objc private func handleHover(_ gr: UIHoverGestureRecognizer) {
        guard inputEnabled, gr.state == .began || gr.state == .changed else { return }
        let (nx, ny) = normalizedPoint(for: gr.location(in: self))
        PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: physicalButtons | pencilButton)
    }

    // Mouse/Pencil contacts use raw touches; finger gestures above remain separate.
    // Pencil is an absolute USB pointer: tip contact draws/drags in Windows with
    // its inbox mouse driver. Pressure, tilt and eraser digitizer reports are not exposed.
    private func handlePointerTouches(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool = false) -> Bool {
        guard let touch = touches.first(where: { $0.type == .indirectPointer || $0.type == .pencil }) else { return false }
        guard inputEnabled else { return true }
        if !isFirstResponder { becomeFirstResponder() }
        if touch.type == .pencil {
            if touch.phase == .began {
                pencilButton = rightClickArmed ? 2 : 1
                if rightClickArmed {
                    rightClickArmed = false
                    onRightClickConsumed?()
                }
            }
            let contact = !cancelled && touch.phase != .ended && touch.phase != .cancelled
            if !contact { pencilButton = 0 }
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            for sample in samples {
                let (nx, ny) = normalizedPoint(for: sample.preciseLocation(in: self))
                PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: physicalButtons | pencilButton)
            }
        } else {
            physicalButtons = cancelled ? 0 : UInt8((event?.buttonMask.rawValue ?? 0) & 7)
            let (nx, ny) = normalizedPoint(for: touch.location(in: self))
            PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: physicalButtons | pencilButton)
        }
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !handlePointerTouches(touches, event: event) { super.touchesBegan(touches, with: event) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !handlePointerTouches(touches, event: event) { super.touchesMoved(touches, with: event) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !handlePointerTouches(touches, event: event) { super.touchesEnded(touches, with: event) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !handlePointerTouches(touches, event: event, cancelled: true) { super.touchesCancelled(touches, with: event) }
    }

    // MARK: - Software & Hardware Keyboard (USB HID Page 0x07)

    override var canBecomeFirstResponder: Bool { inputEnabled }
    // Receive a physical keyboard without forcing the software keyboard onscreen.
    override var inputView: UIView? { softwareKeyboardVisible ? nil : hiddenKeyboardView }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }

    func insertText(_ text: String) {
        guard inputEnabled, physicalKeyMap.isEmpty else { return }
        // Serialize software keystrokes so mixed uppercase/lowercase paste cannot
        // release Shift before an earlier character's key-up.
        softwareKeys.append(contentsOf: text.compactMap(Self.asciiToHID))
        typeNextSoftwareKey()
    }

    func deleteBackward() {
        guard inputEnabled, physicalKeyMap.isEmpty else { return }
        softwareKeys.append((0x2a, false))
        typeNextSoftwareKey()
    }

    private func setUsage(_ usage: UInt8, down: Bool) {
        if down {
            if pressedUsages.insert(usage).inserted { WinIOSBridge.shared.sendKeyHid(usage, down: true) }
        } else if pressedUsages.remove(usage) != nil {
            WinIOSBridge.shared.sendKeyHid(usage, down: false)
        }
    }

    private func mappedUsage(_ usage: UInt8) -> UInt8 {
        if UserDefaults.standard.bool(forKey: "mapCommandToControl") {
            if usage == 0xe3 { return 0xe0 }
            if usage == 0xe7 { return 0xe4 }
        }
        return usage
    }

    private func reconcileModifiers(_ flags: UIKeyModifierFlags) {
        let groups: [(UIKeyModifierFlags, UInt8, UInt8)] = [
            (.control, 0xe0, 0xe4), (.shift, 0xe1, 0xe5),
            (.alternate, 0xe2, 0xe6), (.command, 0xe3, 0xe7)
        ]
        var desired: Set<UInt8> = []
        for (flag, left, right) in groups where flags.contains(flag) {
            // Preserve side-specific modifiers when UIKit reports their physical key.
            let heldSides = [left, right].filter { physicalKeyMap[$0] != nil }
            if heldSides.isEmpty { desired.insert(mappedUsage(left)) }
            for side in heldSides { desired.insert(mappedUsage(side)) }
        }
        for usage in pressedUsages.filter({ $0 >= 0xe0 && !desired.contains($0) }) { setUsage(usage, down: false) }
        for usage in desired { setUsage(usage, down: true) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard inputEnabled else { super.pressesBegan(presses, with: event); return }
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, (0x04...0xe7).contains(key.keyCode.rawValue) else {
                unhandled.insert(press); continue
            }
            let physical = UInt8(key.keyCode.rawValue)
            let usage = physicalKeyMap[physical] ?? mappedUsage(physical)
            physicalKeyMap[physical] = usage
            reconcileModifiers(key.modifierFlags)
            setUsage(usage, down: true)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, (0x04...0xe7).contains(key.keyCode.rawValue) else {
                unhandled.insert(press); continue
            }
            let physical = UInt8(key.keyCode.rawValue)
            let usage = physicalKeyMap.removeValue(forKey: physical) ?? mappedUsage(physical)
            setUsage(usage, down: false)
            reconcileModifiers(key.modifierFlags)
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { releaseInput() }

    override func resignFirstResponder() -> Bool {
        releaseInput()
        return super.resignFirstResponder()
    }

    @objc func releaseInput() {
        viewportControlsActive = false
        inputGeneration &+= 1
        softwareKeys.removeAll()
        softwareTyping = false
        physicalKeyMap.removeAll()
        for usage in pressedUsages.sorted() { WinIOSBridge.shared.sendKeyHid(usage, down: false) }
        pressedUsages.removeAll()
        physicalButtons = 0
        pencilButton = 0
        activeDragButtons = 0
        PointerController.shared.releaseAllButtons()
    }

    private func typeNextSoftwareKey() {
        guard !softwareTyping, !softwareKeys.isEmpty, inputEnabled else { return }
        softwareTyping = true
        let (usage, shift) = softwareKeys.removeFirst()
        let generation = inputGeneration
        if shift { setUsage(0xe1, down: true) }
        setUsage(usage, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, generation == self.inputGeneration else { return }
            self.setUsage(usage, down: false)
            if shift { self.setUsage(0xe1, down: false) }
            self.softwareTyping = false
            self.typeNextSoftwareKey()
        }
    }

    static func asciiToHID(_ ch: Character) -> (UInt8, Bool)? {
        if let ascii = ch.asciiValue {
            switch ascii {
            case 97...122: return (UInt8(0x04 + Int(ascii - 97)), false) // a-z
            case 65...90:  return (UInt8(0x04 + Int(ascii - 65)), true)  // A-Z
            case 49...57:  return (UInt8(0x1e + Int(ascii - 49)), false) // 1-9
            case 48:       return (0x27, false) // 0
            case 10, 13:   return (0x28, false) // Enter
            case 9:        return (0x2b, false) // Tab
            case 32:       return (0x2c, false) // Space
            default: break
            }
        }
        let symbols: [Character: (UInt8, Bool)] = [
            "!": (0x1e, true), "@": (0x1f, true), "#": (0x20, true), "$": (0x21, true),
            "%": (0x22, true), "^": (0x23, true), "&": (0x24, true), "*": (0x25, true),
            "(": (0x26, true), ")": (0x27, true), "-": (0x2d, false), "_": (0x2d, true),
            "=": (0x2e, false), "+": (0x2e, true), "[": (0x2f, false), "{": (0x2f, true),
            "]": (0x30, false), "}": (0x30, true), "\\": (0x31, false), "|": (0x31, true),
            ";": (0x33, false), ":": (0x33, true), "'": (0x34, false), "\"": (0x34, true),
            "`": (0x35, false), "~": (0x35, true), ",": (0x36, false), "<": (0x36, true),
            ".": (0x37, false), ">": (0x37, true), "/": (0x38, false), "?": (0x38, true),
        ]
        return symbols[ch]
    }
}

// The canvas keeps its unscaled bounds and aspect-fit renderer. A clipped host
// transforms it for zoom; UIKit converts mouse/Pencil/touch positions back into
// canvas coordinates before normalizedPoint maps them to guest HID coordinates.
final class MetalViewportUIView: UIView, UIGestureRecognizerDelegate {
    let canvas = MetalCanvasUIView(frame: .zero)
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var startZoom: CGFloat = 1
    private var startOffset = CGPoint.zero
    private var pinchCenter = CGPoint.zero
    private var panOffset = CGPoint.zero
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(zoomViewport(_:)))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panViewport(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }
    private func configure() {
        clipsToBounds = true
        backgroundColor = .black
        addSubview(canvas)
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.delegate = self
        addGestureRecognizer(pinch)
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        addGestureRecognizer(pan)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.transform = .identity
        canvas.frame = bounds
        applyViewport()
    }
    private func applyViewport() {
        let maxX = bounds.width * (zoom - 1) * 0.5
        let maxY = bounds.height * (zoom - 1) * 0.5
        offset.x = min(maxX, max(-maxX, offset.x))
        offset.y = min(maxY, max(-maxY, offset.y))
        canvas.transform = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: offset.x, ty: offset.y)
        canvas.viewportZoomed = zoom > 1.01
    }
    @objc private func zoomViewport(_ gr: UIPinchGestureRecognizer) {
        guard canvas.inputEnabled else { return }
        if gr.state == .began {
            canvas.releaseInput()
            canvas.viewportControlsActive = true
            startZoom = zoom
            startOffset = offset
            pinchCenter = gr.location(in: self)
        }
        if gr.state == .began || gr.state == .changed {
            guard gr.scale.isFinite else { return }
            zoom = min(3, max(1, startZoom * gr.scale))
            let ratio = zoom / startZoom
            let current = gr.location(in: self)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            offset.x = current.x - center.x - (pinchCenter.x - center.x - startOffset.x) * ratio
            offset.y = current.y - center.y - (pinchCenter.y - center.y - startOffset.y) * ratio
            applyViewport()
        }
        if gr.state == .ended || gr.state == .cancelled || gr.state == .failed {
            canvas.viewportControlsActive = false
        }
    }
    @objc private func panViewport(_ gr: UIPanGestureRecognizer) {
        guard canvas.inputEnabled, zoom > 1.01 else { return }
        if gr.state == .began { panOffset = offset }
        guard pinch.state != .began && pinch.state != .changed else { return }
        if gr.state == .began || gr.state == .changed {
            let translation = gr.translation(in: self)
            offset = CGPoint(x: panOffset.x + translation.x, y: panOffset.y + translation.y)
            applyViewport()
        }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        canvas.inputEnabled && (gestureRecognizer !== pan || zoom > 1.01)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A zoomed two-finger drag pans the host; the canvas suppresses guest
        // touch-scroll in that state. Hardware scroll still goes to Windows.
        otherGestureRecognizer === pinch || otherGestureRecognizer === pan || otherGestureRecognizer.view === canvas
    }
}

struct MetalDisplayView: UIViewRepresentable {
    @Binding var trackpadMode: Bool
    @Binding var rightClickArmed: Bool
    @Binding var keyboardVisible: Bool
    var onThreeFingerTap: () -> Void
    var inputEnabled: Bool = true

    func makeUIView(context: Context) -> MetalViewportUIView {
        let viewport = MetalViewportUIView(frame: .zero)
        let view = viewport.canvas
        view.inputEnabled = inputEnabled
        view.onThreeFingerTap = onThreeFingerTap
        view.onRightClickConsumed = {
            DispatchQueue.main.async { self.rightClickArmed = false }
        }
        return viewport
    }

    func updateUIView(_ viewport: MetalViewportUIView, context: Context) {
        let uiView = viewport.canvas
        uiView.trackpadMode = trackpadMode
        uiView.rightClickArmed = rightClickArmed
        uiView.onThreeFingerTap = onThreeFingerTap
        uiView.inputEnabled = inputEnabled
        if uiView.softwareKeyboardVisible != keyboardVisible {
            uiView.softwareKeyboardVisible = keyboardVisible
            uiView.reloadInputViews()
        }
        if inputEnabled && !uiView.isFirstResponder && uiView.window != nil {
            DispatchQueue.main.async {
                if uiView.inputEnabled { _ = uiView.becomeFirstResponder() }
            }
        } else if !inputEnabled {
            uiView.releaseInput()
            if uiView.isFirstResponder { _ = uiView.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ viewport: MetalViewportUIView, coordinator: ()) {
        let uiView = viewport.canvas
        uiView.inputEnabled = false
        uiView.releaseInput()
        _ = uiView.resignFirstResponder()
        WinIOSBridge.shared.bindMetalLayer(nil)
    }
}
