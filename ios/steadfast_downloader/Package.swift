// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "steadfast_downloader",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "steadfast-downloader", targets: ["steadfast_downloader"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "steadfast_downloader",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Apple's privacy manifest: no tracking, no data collected, no
                // required-reason APIs.
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
