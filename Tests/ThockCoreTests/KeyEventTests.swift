import Testing
@testable import ThockCore

@Suite("Key classification")
struct KeyClassificationTests {
    @Test func specialKeysGetOwnCategories() {
        #expect(KeyClassifier.category(forKeyCode: 49) == .space)
        #expect(KeyClassifier.category(forKeyCode: 36) == .enter)
        #expect(KeyClassifier.category(forKeyCode: 76) == .enter)
        #expect(KeyClassifier.category(forKeyCode: 51) == .backspace)
        #expect(KeyClassifier.category(forKeyCode: 117) == .backspace)
        #expect(KeyClassifier.category(forKeyCode: 56) == .modifier)   // left shift
        #expect(KeyClassifier.category(forKeyCode: 55) == .modifier)   // command
        #expect(KeyClassifier.category(forKeyCode: 0) == .alpha)       // A
        #expect(KeyClassifier.category(forKeyCode: 46) == .alpha)      // M
        #expect(KeyClassifier.category(forKeyCode: 53) == .other)      // escape
        #expect(KeyClassifier.category(forKeyCode: 123) == .other)     // left arrow
    }

    @Test func horizontalPositionIsOrdered() {
        let q = KeyClassifier.horizontalPosition(forKeyCode: 12)  // Q
        let p = KeyClassifier.horizontalPosition(forKeyCode: 35)  // P
        #expect(q < 0.3 && p > 0.6)
        for code in UInt16(0)...127 {
            let x = KeyClassifier.horizontalPosition(forKeyCode: code)
            #expect(x >= 0 && x <= 1)
        }
    }
}

@Suite("Key event processing")
struct KeyEventProcessorTests {
    func ev(_ k: RawKeyEvent.Kind, _ code: UInt16, t: Double, repeatFlag: Bool = false, flags: UInt64 = 0) -> RawKeyEvent {
        RawKeyEvent(kind: k, keyCode: code, isAutorepeat: repeatFlag, flags: flags, time: t)
    }

    @Test func downThenUp() {
        let p = KeyEventProcessor()
        let d = p.process(ev(.keyDown, 0, t: 1.0))
        #expect(d?.direction == .down && d?.category == .alpha)
        let u = p.process(ev(.keyUp, 0, t: 1.08))
        #expect(u?.direction == .up)
    }

    @Test func autorepeatIsIgnored() {
        let p = KeyEventProcessor()
        #expect(p.process(ev(.keyDown, 0, t: 1.0)) != nil)
        #expect(p.process(ev(.keyDown, 0, t: 1.5, repeatFlag: true)) == nil)
        #expect(p.process(ev(.keyDown, 0, t: 1.55, repeatFlag: true)) == nil)
    }

    @Test func duplicateEventsWithinWindowAreDropped() {
        let p = KeyEventProcessor()
        #expect(p.process(ev(.keyDown, 6, t: 2.000)) != nil)
        #expect(p.process(ev(.keyDown, 6, t: 2.004)) == nil)    // same press seen twice
        #expect(p.process(ev(.keyUp, 6, t: 2.050)) != nil)
        #expect(p.process(ev(.keyUp, 6, t: 2.051)) == nil)      // duplicate release
    }

    @Test func lostKeyUpDoesNotSwallowNextPress() {
        let p = KeyEventProcessor()
        #expect(p.process(ev(.keyDown, 6, t: 1.0)) != nil)
        // key-up was lost (secure input began); a later genuine press must still sound
        #expect(p.process(ev(.keyDown, 6, t: 9.0)) != nil)
    }

    @Test func releaseWithoutPressIsIgnored() {
        let p = KeyEventProcessor()
        #expect(p.process(ev(.keyUp, 12, t: 1.0)) == nil)
    }

    @Test func rapidRollOverKeepsAllKeys() {
        let p = KeyEventProcessor()
        var downs = 0
        for (i, code) in [UInt16(12), 13, 14, 15, 17, 16].enumerated() {
            if p.process(ev(.keyDown, code, t: 1.0 + Double(i) * 0.012)) != nil { downs += 1 }
        }
        #expect(downs == 6)
    }

    @Test func shiftPressAndRelease() {
        let p = KeyEventProcessor()
        let down = p.process(ev(.flagsChanged, 56, t: 1, flags: 0x20000 | 0x2))
        #expect(down?.direction == .down && down?.category == .modifier)
        let up = p.process(ev(.flagsChanged, 56, t: 1.2, flags: 0))
        #expect(up?.direction == .up)
    }

    @Test func secondShiftWhileFirstHeldIsDistinct() {
        let p = KeyEventProcessor()
        #expect(p.process(ev(.flagsChanged, 56, t: 1.0, flags: 0x20000 | 0x2)) != nil)
        #expect(p.process(ev(.flagsChanged, 60, t: 1.1, flags: 0x20000 | 0x2 | 0x4)) != nil)
        // release left shift, right still held: generic flag remains, device bit for left cleared
        let up = p.process(ev(.flagsChanged, 56, t: 1.2, flags: 0x20000 | 0x4))
        #expect(up?.direction == .up && up?.keyCode == 56)
    }

    @Test func capsLockTogglesAreSoundEvents() {
        let p = KeyEventProcessor()
        #expect(p.process(ev(.flagsChanged, 57, t: 1, flags: 0x10000))?.direction == .down)
        #expect(p.process(ev(.flagsChanged, 57, t: 2, flags: 0))?.direction == .up)
    }

    @Test func nonModifierFlagsChangedIsIgnored() {
        let p = KeyEventProcessor()
        #expect(p.process(ev(.flagsChanged, 0, t: 1, flags: 0x20000)) == nil)
    }

    @Test func resetClearsState() {
        let p = KeyEventProcessor()
        _ = p.process(ev(.keyDown, 0, t: 1))
        p.reset()
        #expect(p.process(ev(.keyUp, 0, t: 1.1)) == nil)
    }
}
