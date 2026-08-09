// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "XiangqiDocumentKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "XiangqiDocumentKit", targets: ["XiangqiDocumentKit"])
  ],
  targets: [.target(name: "XiangqiDocumentKit")]
)
