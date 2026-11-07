// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Solune",
    platforms: [.macOS(.v15)],
    targets: [
        // 纯逻辑：规则判断，不碰系统接口，可以单测
        .target(name: "SoluneCore"),
        .executableTarget(
            name: "Solune",
            dependencies: ["SoluneCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "SoluneCoreTests", dependencies: ["SoluneCore"]),
    ]
)
