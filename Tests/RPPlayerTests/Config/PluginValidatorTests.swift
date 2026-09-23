import AudioToolbox
import XCTest
@testable import RPPlayer

final class PluginValidatorTests: XCTestCase {
    private let host = [PluginValidator.hostArchitecture]

    private func validate(_ entries: [[String: Any]]?, architectures: [Int]? = nil,
                          existing: [PluginComponent] = []) -> Result<PluginComponent, PluginStoreError> {
        var plist: [String: Any] = [:]
        if let entries { plist["AudioComponents"] = entries }
        return PluginValidator.validate(infoPlist: plist, architectures: architectures ?? host, existing: existing)
    }

    func testValidEffectParsesNameManufacturerAndVersion() throws {
        let c = try validate([PluginFixtures.componentEntry()]).get()
        XCTAssertEqual(c.name, "Console7Channel")
        XCTAssertEqual(c.manufacturerName, "Airwindows")
        XCTAssertEqual(c.versionString, "1.2.3")
        XCTAssertEqual(c.factoryFunction, "Console7ChannelFactory")
        XCTAssertEqual(c.componentDescription.componentType, kAudioUnitType_Effect)
        XCTAssertEqual(c.componentDescription.componentSubType, 0x436E_3763) // "Cn7c"
        XCTAssertEqual(c.componentDescription.componentManufacturer, 0x4474_6872) // "Dthr"
    }

    func testMusicEffectAcceptedAndFirstValidEntryWins() throws {
        let c = try validate([
            ["type": "aufx"],  // incomplete entry is skipped
            PluginFixtures.componentEntry(type: "aumf", name: "NoPrefixName"),
            PluginFixtures.componentEntry(subtype: "Othr"),
        ]).get()
        XCTAssertEqual(c.componentDescription.componentType, kAudioUnitType_MusicEffect)
        XCTAssertEqual(c.name, "NoPrefixName")
        XCTAssertEqual(c.manufacturerName, "Dthr")
    }

    func testMissingAudioComponentsIsNotAComponent() {
        XCTAssertEqual(validate(nil), .failure(.notAComponent))
        XCTAssertEqual(validate([]), .failure(.notAComponent))
    }

    func testInstrumentIsNotAnEffect() {
        XCTAssertEqual(validate([PluginFixtures.componentEntry(type: "aumu")]), .failure(.notAnEffect))
    }

    func testMissingHostSliceIsWrongArchitecture() {
        let other = PluginValidator.hostArchitecture == NSBundleExecutableArchitectureARM64
            ? NSBundleExecutableArchitectureX86_64 : NSBundleExecutableArchitectureARM64
        XCTAssertEqual(validate([PluginFixtures.componentEntry()], architectures: [other]), .failure(.wrongArchitecture))
    }

    func testSameDescriptionAsImportedPluginIsDuplicate() throws {
        let existing = try validate([PluginFixtures.componentEntry(name: "Airwindows: Old Name")]).get()
        XCTAssertEqual(validate([PluginFixtures.componentEntry()], existing: [existing]),
                       .failure(.duplicate(name: "Old Name")))
    }
}
