import XCTest

@testable import XiangqiCoreBinary

final class XiangqiCoreBinaryTests: XCTestCase {
  func testLinkedABIAndBuildInfoRoundTrip() {
    let validation = XiangqiCoreBinary.validateABIForDebug()
    guard case .success(let info) = validation else {
      return XCTFail("expected linked ABI validation to pass, got \(validation)")
    }
    XCTAssertEqual(info.major, GeneratedFFIABI.major)
    XCTAssertGreaterThanOrEqual(info.minor, GeneratedFFIABI.minimumMinor)

    let buildInfo = XiangqiCoreBinary.buildInfo()
    guard case .success(let value) = buildInfo else {
      return XCTFail("expected owned build-info buffer to round trip, got \(buildInfo)")
    }
    XCTAssertTrue(value.contains("product=NativeXiangqi"))
    XCTAssertTrue(value.contains(GeneratedFFIABI.sourceSHA256))
  }

  func testCompatibilityRejectsMajorMinorCapabilitiesAndReservedField() {
    XCTAssertEqual(
      XiangqiCoreBinary.evaluateABI(
        major: GeneratedFFIABI.major &+ 1,
        minor: GeneratedFFIABI.minimumMinor,
        capabilities: GeneratedFFIABI.capabilityAbiInfo,
        buildInfoFormat: GeneratedFFIABI.buildInfoFormat,
        reserved: 0
      ),
      .failure(.abiMajor(found: GeneratedFFIABI.major &+ 1, expected: GeneratedFFIABI.major))
    )
    XCTAssertEqual(
      XiangqiCoreBinary.evaluateABI(
        major: GeneratedFFIABI.major,
        minor: 0,
        capabilities: GeneratedFFIABI.capabilityAbiInfo,
        buildInfoFormat: GeneratedFFIABI.buildInfoFormat,
        reserved: 0,
        minimumMinor: 1
      ),
      .failure(.abiMinor(found: 0, minimum: 1))
    )
    XCTAssertEqual(
      XiangqiCoreBinary.evaluateABI(
        major: GeneratedFFIABI.major,
        minor: GeneratedFFIABI.minimumMinor,
        capabilities: 0,
        buildInfoFormat: GeneratedFFIABI.buildInfoFormat,
        reserved: 0
      ),
      .failure(
        .capabilities(
          found: 0,
          required: GeneratedFFIABI.capabilityAbiInfo
            | GeneratedFFIABI.capabilityBuildInfo
            | GeneratedFFIABI.capabilityOwnedBuffers
        )
      )
    )
    XCTAssertEqual(
      XiangqiCoreBinary.evaluateABI(
        major: GeneratedFFIABI.major,
        minor: GeneratedFFIABI.minimumMinor,
        capabilities: GeneratedFFIABI.capabilityAbiInfo
          | GeneratedFFIABI.capabilityBuildInfo
          | GeneratedFFIABI.capabilityOwnedBuffers,
        buildInfoFormat: GeneratedFFIABI.buildInfoFormat,
        reserved: 1
      ),
      .failure(.reservedField(1))
    )
  }
}
