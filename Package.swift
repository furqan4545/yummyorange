// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DropWheel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DropWheel",
            path: "Sources/DropWheel",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Quartz"),
                .linkedFramework("WebKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
