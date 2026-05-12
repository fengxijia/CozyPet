// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PetCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PetCore", targets: ["PetCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "PetCore",
            dependencies: ["Yams"]
        ),
        .testTarget(
            name: "PetCoreTests",
            dependencies: ["PetCore"]
        ),
    ]
)
