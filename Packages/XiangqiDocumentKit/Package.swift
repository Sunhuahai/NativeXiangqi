// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "XiangqiDocumentKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "XiangqiDocumentKit", targets: ["XiangqiDocumentKit"]),
    .executable(name: "XiangqiUIBenchmarks", targets: ["XiangqiUIBenchmarks"]),
  ],
  dependencies: [
    .package(path: "../XiangqiCoreBinary"),
    .package(path: "../XiangqiUI"),
  ],
  targets: [
    .target(
      name: "XiangqiDocumentKit",
      dependencies: [
        .product(name: "XiangqiCoreBinary", package: "XiangqiCoreBinary"),
        .product(name: "XiangqiUI", package: "XiangqiUI"),
      ]
    ),
    .executableTarget(
      name: "XiangqiUIBenchmarks",
      dependencies: [
        "XiangqiDocumentKit",
        .product(name: "XiangqiUI", package: "XiangqiUI"),
      ]
    ),
    .testTarget(
      name: "XiangqiDocumentKitTests",
      dependencies: ["XiangqiDocumentKit"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
