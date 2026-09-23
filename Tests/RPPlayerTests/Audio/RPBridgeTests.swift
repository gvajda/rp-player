import AudioToolbox
import RPBridge
import XCTest

final class RPBridgeTests: XCTestCase {
    private var bridge: RPBridgeTestSupport.Bridge!

    override func setUpWithError() throws {
        bridge = try RPBridgeTestSupport.open()
        bridge.setUnit(nil)
    }

    override func tearDown() {
        bridge.setUnit(nil)
    }

    func testDescriptorShape() {
        let d = bridge.descriptor.pointee
        XCTAssertEqual(String(cString: d.Label), "rpbridge")
        XCTAssertEqual(d.PortCount, 4)
        XCTAssertNotEqual(d.Properties & LADSPA_PROPERTY_INPLACE_BROKEN, 0)
        let audioIn = LADSPA_PORT_INPUT | LADSPA_PORT_AUDIO
        let audioOut = LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO
        XCTAssertEqual((0..<4).map { d.PortDescriptors[$0] }, [audioIn, audioIn, audioOut, audioOut])
        XCTAssertNil(bridge.descriptorAt(1))
    }

    func testPassthroughWithoutUnitCopiesInputAndCountsFrames() {
        let left = (0..<1000).map { Float($0) / 1000 }
        let right = left.map { -$0 }
        let before = bridge.framesProcessed()
        let out = RPBridgeTestSupport.run(bridge, rate: 44100, left: left, right: right)
        XCTAssertEqual(out.left, left)
        XCTAssertEqual(out.right, right)
        XCTAssertEqual(bridge.framesProcessed() - before, 1000)
    }

    func testHighPassRemovesDCAcrossChunkedRun() throws {
        let unit = try RPBridgeTestSupport.makeAppleEffect(subType: kAudioUnitSubType_HighPassFilter)
        defer { bridge.setUnit(nil); AudioComponentInstanceDispose(unit) }
        bridge.setUnit(unit)
        let n = 10_000
        let dc = [Float](repeating: 0.5, count: n)
        let out = RPBridgeTestSupport.run(bridge, rate: 44100, left: dc, right: dc)
        XCTAssertFalse(out.left.contains(where: \.isNaN) || out.right.contains(where: \.isNaN), "a chunk was never written")
        XCTAssertLessThan(out.left.suffix(1000).map(abs).max()!, 1e-3, "DC passed through — AU not rendering")
        XCTAssertLessThan(out.right.suffix(1000).map(abs).max()!, 1e-3)
    }

    func testRateChangeReconfiguresUnit() throws {
        let unit = try RPBridgeTestSupport.makeAppleEffect(subType: kAudioUnitSubType_HighPassFilter)
        defer { bridge.setUnit(nil); AudioComponentInstanceDispose(unit) }
        bridge.setUnit(unit)
        let tone = [Float](repeating: 0.1, count: 512)
        _ = RPBridgeTestSupport.run(bridge, rate: 44100, left: tone, right: tone)
        _ = RPBridgeTestSupport.run(bridge, rate: 48000, left: tone, right: tone)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        XCTAssertEqual(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size), noErr)
        XCTAssertEqual(format.mSampleRate, 48000)
        XCTAssertEqual(format.mChannelsPerFrame, 2)
    }
}
