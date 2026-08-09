// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "XiangqiCoreBinary",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "XiangqiCoreBinary", targets: ["XiangqiCoreBinary"])
  ],
  targets: [.target(name: "XiangqiCoreBinary")]
)
