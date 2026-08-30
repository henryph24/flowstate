// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MurmurKit"),
        .executableTarget(name: "Murmur", dependencies: ["MurmurKit"]),
        .executableTarget(name: "MurmurTests", dependencies: ["MurmurKit"]),
    ]
)
