// swift-tools-version: 6.2

import PackageDescription

let libmpvLib = "Vendor/libmpv/lib"

// Linker flags shared by every target that links libmpv. The two `@loader_path`
// rpaths cover both layouts SwiftPM uses for build products on macOS:
//   - Executable: `.build/<arch>/<config>/<exec>`     → 3 levels up to package root.
//   - xctest:     `.build/<arch>/<config>/<bundle>.xctest/Contents/MacOS/<bin>`
//                                                     → 6 levels up to package root.
// Baking both means the same flag set works for executables and tests, and
// removes the need for `DYLD_LIBRARY_PATH` (which macOS hardened runtime strips
// before launching the Apple-signed swiftpm-testing-helper).
let mpvLinker: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(libmpvLib)",
        "-lmpv",
        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../\(libmpvLib)",
        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../\(libmpvLib)",
    ]),
]

let package = Package(
    name: "RPPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CMpv",
            path: "Sources/CMpv"
        ),
        .executableTarget(
            name: "RPPlayer",
            path: "Sources/RPPlayer"
        ),
        .executableTarget(
            name: "RPSmoke",
            dependencies: ["CMpv"],
            path: "Sources/RPSmoke",
            linkerSettings: mpvLinker
        ),
        .testTarget(
            name: "RPPlayerTests",
            dependencies: ["RPPlayer", "CMpv"],
            path: "Tests/RPPlayerTests",
            resources: [.copy("Fixtures")],
            linkerSettings: mpvLinker
        ),
    ]
)
