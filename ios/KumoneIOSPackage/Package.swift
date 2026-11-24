// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KumoneIOSFeature",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "KumoneIOSFeature",
            targets: ["KumoneIOSFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "KumoneIOSFeature",
            dependencies: [
                // 本地 path 依赖的 identity 取目录名。本定制版目录为 Kumone-LX，
                // 原项目为 kumone，故这里引用 "Kumone-LX"。
                .product(name: "KumoneCore", package: "Kumone-LX"),
            ],
            path: "Sources/KumoneIOSFeature"
        ),
        .testTarget(
            name: "KumoneIOSFeatureTests",
            dependencies: [
                "KumoneIOSFeature"
            ]
        ),
    ]
)
