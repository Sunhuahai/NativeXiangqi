// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "XiangqiCoreBinary",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "XiangqiCoreBinary", targets: ["XiangqiCoreBinary"])
  ],
  targets: [
    // The root Make commands stage this generated, local-only XCFramework before package resolution.
    .binaryTarget(
      name: "XiangqiCoreFFI",
      path: "Artifacts/XiangqiCoreFFI.xcframework"
    ),
    .target(
      name: "XiangqiCoreBinary",
      dependencies: ["XiangqiCoreFFI"]
    ),
    .testTarget(
      name: "XiangqiCoreBinaryTests",
      dependencies: ["XiangqiCoreBinary"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
