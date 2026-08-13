// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "PikafishKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "PikafishKit", targets: ["PikafishKit"]),
    .executable(name: "PikafishKitBenchmarks", targets: ["PikafishKitBenchmarks"]),
  ],
  targets: [
    .target(
      name: "PikafishKit",
      dependencies: ["CSQLite3"]
    ),
    .systemLibrary(name: "CSQLite3"),
    .executableTarget(
      name: "PikafishKitBenchmarks",
      dependencies: ["PikafishKit"]
    ),
    .testTarget(
      name: "PikafishKitTests",
      dependencies: ["PikafishKit"]
    ),
  ]
)
