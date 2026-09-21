// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingCurtain",
    platforms: [.macOS("14.4")],
    targets: [
        // Pure scheduling and parsing logic, kept free of AppKit/EventKit so it can be unit tested.
        .target(name: "MeetingCurtainCore"),
        .executableTarget(
            name: "MeetingCurtain",
            dependencies: ["MeetingCurtainCore"]
        ),
        .testTarget(
            name: "MeetingCurtainCoreTests",
            dependencies: ["MeetingCurtainCore"]
        ),
    ]
)
