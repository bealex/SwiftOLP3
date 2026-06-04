// swift-tools-version: 6.0
import PackageDescription

// SwiftOPL3 — pure-Swift, LGPL-2.1 OPL3 chip + Westwood ADL driver.
//
// Two products:
//   • SwiftOPL3   — the OPL3 (YMF262) chip core. Foundation-only, platform-agnostic.
//   • WestwoodADL — the Westwood ADL music driver; drives a SwiftOPL3 chip. Foundation-only.
//
// Logging note (see Documentation/Architecture/Logging.md):
//   All tracing goes through `OPLLog`, whose bodies compile to nothing unless the
//   `OPL_TRACE` define is set. The Memoirs dependency is only *used* under that flag.
//   To get a true zero-cost release build, build without `OPL_TRACE` (the default).
//   The `traced` trait below turns it on for local debugging.

let package = Package(
    name: "SwiftOPL3",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftOPL3", targets: ["SwiftOPL3"]),
        .library(name: "WestwoodADL", targets: ["WestwoodADL"]),
        .executable(name: "adlrender", targets: ["adlrender"]),
    ],
    dependencies: [
        // Memoirs — Alex Babaev's structured logging library (memoirs-ios).
        // Package identity is `memoirs-ios` (last URL path component); the
        // library product it vends is `Memoirs`.
        // Pinned to 2.0.x: it supports macOS 13 / iOS 14, matching this
        // package's deployment floor. 2.1+ raised the floor to macOS 15.
        .package(url: "https://github.com/bealex/memoirs-ios.git", "2.0.0" ..< "2.1.0"),
    ],
    targets: [
        .target(
            name: "SwiftOPL3",
            dependencies: [.product(name: "Memoirs", package: "memoirs-ios")],
            swiftSettings: [
                // Uncomment for a debug-traced build, or pass `-Xswiftc -DOPL_TRACE`:
                // .define("OPL_TRACE", .when(configuration: .debug)),

                // EXPERIMENTAL float-DSP fork (OPL3FloatDSP.swift). OFF by default —
                // the integer build is the faithful, bit-exact one. Define OPL_FLOAT
                // to swap per-sample synthesis to 32-bit float (non-bit-exact) for
                // performance evaluation. Uncomment, or build with
                // `-Xswiftc -DOPL_FLOAT`:
                // .define("OPL_FLOAT"),

                // EXPERIMENTAL SIMD fork (OPL3SimdDSP.swift): a Struct-of-Arrays
                // chip that processes melodic channels as SIMD lanes (rhythm stays
                // scalar). Also float, also non-bit-exact. Mutually exclusive with
                // OPL_FLOAT. Build with `-Xswiftc -DOPL_SIMD`:
                // .define("OPL_SIMD"),
            ]
        ),
        .target(
            name: "WestwoodADL",
            dependencies: [
                "SwiftOPL3",
                .product(name: "Memoirs", package: "memoirs-ios"),
            ]
        ),
        // Example tool (out of the Foundation-only core): renders a .ADL track to
        // a WAV by driving WestwoodADL → SwiftOPL3. See Plan.md §Phase 5.
        .executableTarget(
            name: "adlrender",
            dependencies: ["WestwoodADL", "SwiftOPL3"]
        ),
        // CPU benchmark / Instruments Time Profiler target (no file I/O in the
        // hot loop). `swift build -c release` then profile .build/release/oplbench.
        .executableTarget(
            name: "oplbench",
            dependencies: ["WestwoodADL", "SwiftOPL3"]
        ),
        .testTarget(
            name: "SwiftOPL3Tests",
            dependencies: ["SwiftOPL3"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WestwoodADLTests",
            dependencies: ["WestwoodADL", "SwiftOPL3"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
