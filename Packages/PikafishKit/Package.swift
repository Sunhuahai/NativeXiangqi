// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "PikafishKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "PikafishKit", targets: ["PikafishKit"])
  ],
  targets: [
    .target(name: "PikafishKit"),
    .testTarget(
      name: "PikafishKitTests",
      dependencies: ["PikafishKit"]
    ),
  ]
)
