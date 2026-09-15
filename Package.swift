// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MathPeek",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MathPeek", targets: ["MathPeek"])],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath.git",
                 revision: "1d2c90827e9c3908269d810d055fb03b7da5fd53")
    ],
    targets: [
        .executableTarget(
            name: "MathPeek",
            dependencies: [.product(name: "SwiftMath", package: "SwiftMath")],
            path: "native",
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("CoreText"),
                .linkedFramework("WebKit"), .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ])
    ]
)
