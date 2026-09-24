import AudioToolbox
import Foundation
import RPBridge
import XCTest

// `import RPBridge` is for C types only: the test bundle links its own static copy, so every function must come from the dylib via dlsym.
enum RPBridgeTestSupport {
    private final class Marker {}

    static var dylibPath: String {
        Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("libRPBridge.dylib").path
    }

    struct Bridge {
        let handle: UnsafeMutableRawPointer
        let descriptorAt: @convention(c) (UInt) -> UnsafePointer<LADSPA_Descriptor>?
        let setUnit: @convention(c) (AudioUnit?) -> Void
        let framesProcessed: @convention(c) () -> UInt64

        var descriptor: UnsafePointer<LADSPA_Descriptor> { descriptorAt(0)! }
    }

    static func open(_ path: String = dylibPath) throws -> Bridge {
        let handle = try XCTUnwrap(dlopen(path, RTLD_NOW | RTLD_LOCAL),
                                   dlerror().map { String(cString: $0) } ?? "dlopen failed")
        func sym<T>(_ name: String, _: T.Type) throws -> T {
            unsafeBitCast(try XCTUnwrap(dlsym(handle, name), "missing \(name)"), to: T.self)
        }
        return Bridge(
            handle: handle,
            descriptorAt: try sym("ladspa_descriptor", (@convention(c) (UInt) -> UnsafePointer<LADSPA_Descriptor>?).self),
            setUnit: try sym("rpbridge_set_unit", (@convention(c) (AudioUnit?) -> Void).self),
            framesProcessed: try sym("rpbridge_frames_processed", (@convention(c) () -> UInt64).self)
        )
    }

    // Drives the descriptor the way af_ladspa does: instantiate, connect 4 ports, activate, one run, cleanup.
    static func run(_ bridge: Bridge, rate: UInt, left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        let d = bridge.descriptor.pointee
        let n = left.count
        let handle = d.instantiate(bridge.descriptor, rate)!
        defer { d.cleanup(handle) }
        let ports = (0..<4).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { ports.forEach { $0.deallocate() } }
        ports[0].initialize(from: left, count: n)
        ports[1].initialize(from: right, count: n)
        ports[2].initialize(repeating: .nan, count: n)
        ports[3].initialize(repeating: .nan, count: n)
        for (i, p) in ports.enumerated() { d.connect_port(handle, UInt(i), p) }
        d.activate?(handle)
        d.run(handle, UInt(n))
        return (Array(UnsafeBufferPointer(start: ports[2], count: n)),
                Array(UnsafeBufferPointer(start: ports[3], count: n)))
    }

    static func makeAppleEffect(subType: OSType) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let component = try XCTUnwrap(AudioComponentFindNext(nil, &desc))
        var unit: AudioUnit?
        XCTAssertEqual(AudioComponentInstanceNew(component, &unit), noErr)
        return try XCTUnwrap(unit)
    }

    static func writeStereoWav(to url: URL, frames: Int, rate: Int) throws {
        var d = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(frames * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)
        u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for i in 0..<frames {
            let s = Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 8000)
            u16(UInt16(bitPattern: s)); u16(UInt16(bitPattern: s))
        }
        try d.write(to: url)
    }
}
