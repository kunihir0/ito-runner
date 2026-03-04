// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ito-runner",
    platforms: [
        .macOS(.v14), .iOS(.v15),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ito-runner",
            targets: ["ito-runner"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftwasm/WasmKit", "0.2.0"..<"0.3.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "ito-runner",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .testTarget(
            name: "ito-runnerTests",
            dependencies: [
                "ito-runner",
                .product(name: "WAT", package: "WasmKit"),
            ]
        ),
    ]
)
