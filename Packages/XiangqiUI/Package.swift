// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "XiangqiUI",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "XiangqiUI", targets: ["XiangqiUI"])
  ],
  targets: [
    .target(name: "XiangqiUI"),
    .testTarget(name: "XiangqiUITests", dependencies: ["XiangqiUI"]),
  ],
  swiftLanguageModes: [.v6]
)
