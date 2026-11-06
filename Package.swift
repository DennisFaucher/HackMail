// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HackMail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HackMail", targets: ["HackMail"])
    ],
    targets: [
        .executableTarget(name: "HackMail"),
        .testTarget(name: "HackMailTests", dependencies: ["HackMail"])
    ]
)
