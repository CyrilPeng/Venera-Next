// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VeneraDirectoryAccess",
    platforms: [.macOS(.v10_14), .iOS(.v13)],
    products: [.library(name: "VeneraDirectoryAccess", targets: ["VeneraDirectoryAccess"])],
    targets: [
        .target(name: "VeneraDirectoryAccess", path: ".",
                exclude: ["ScopedDirectoryAccessTests.swift"], sources: ["ScopedDirectoryAccess.swift"]),
        .testTarget(name: "VeneraDirectoryAccessTests", dependencies: ["VeneraDirectoryAccess"], path: ".",
                    exclude: ["ScopedDirectoryAccess.swift"], sources: ["ScopedDirectoryAccessTests.swift"])
    ]
)
