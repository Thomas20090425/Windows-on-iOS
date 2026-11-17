import Foundation

@main
struct HengeInputValidation {
    static func main() {
        var motion = PhysicalMouseMotion()
        let packets = motion.move(dx: 640, dy: -511, speed: 1)
        precondition(packets.reduce(0) { $0 + $1.0 } == 640)
        precondition(packets.reduce(0) { $0 + $1.1 } == 511)
        precondition(packets.allSatisfy { abs($0.0) <= 127 && abs($0.1) <= 127 })
        precondition(motion.move(dx: .nan, dy: 0, speed: 1).isEmpty)
        precondition(motion.move(dx: .infinity, dy: 0, speed: 1).isEmpty)
        precondition(motion.move(dx: 1e20, dy: 0, speed: 1).isEmpty)

        // A smooth Magic Keyboard gesture must preserve small samples without
        // turning each one into several whole mouse-wheel detents.
        var trackpad = PhysicalMouseMotion()
        let raw: [Float] = [0.0977, 1.4288, 2.7335, 3.6792, 4.2652, 6.2175,
                            7.1983, 7.2560, 6.9339, 5.8212, 5.3326, 5.1870, 4.7034]
        let ticks = raw.reduce(Int32(0)) {
            $0 + trackpad.scroll($1, horizontal: false, trackpad: true, scale: 0.3)
        }
        precondition(ticks == 2, "Device-log gesture should produce two detents rather than dozens")
        precondition(trackpad.scroll(0, horizontal: true, trackpad: true, scale: 0.3) == 0)

        var wheel = PhysicalMouseMotion()
        precondition(wheel.scroll(1, horizontal: false, trackpad: false, scale: 0.3) == 1)
        precondition(wheel.scroll(-1, horizontal: false, trackpad: false, scale: 0.3) == -1)
        precondition(wheel.scroll(.nan, horizontal: false, trackpad: false, scale: 0.3) == 0)
        precondition(wheel.scroll(10000, horizontal: false, trackpad: false, scale: 0.3) == 4)
        print("Henge input validation passed: signed movement, finite bounds, trackpad scroll, mouse wheel")
    }
}
