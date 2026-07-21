// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Easyshop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Easyshop", targets: ["EasyshopApp"])
    ],
    targets: [
        .executableTarget(
            name: "EasyshopApp",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
