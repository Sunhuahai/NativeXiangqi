//! Swift ownership-safe surface for the narrow T010 Rust C ABI.

import Foundation
import XiangqiCoreFFI

public struct XiangqiCoreABIInfo: Equatable, Sendable {
  public let major: UInt32
  public let minor: UInt32
  public let capabilities: UInt64
  public let buildInfoFormat: UInt32
}

public enum XiangqiCoreError: Error, Equatable, Sendable, LocalizedError {
  case abiMajor(found: UInt32, expected: UInt32)
  case abiMinor(found: UInt32, minimum: UInt32)
  case buildInfoFormat(found: UInt32, expected: UInt32)
  case capabilities(found: UInt64, required: UInt64)
  case ffiStatus(UInt32)
  case malformedBuildInfo
  case reservedField(UInt32)
  case releaseStatus(UInt32)

  public var errorDescription: String? {
    switch self {
    case .abiMajor(let found, let expected):
      "Rust core ABI major \(found) is incompatible with expected major \(expected)."
    case .abiMinor(let found, let minimum):
      "Rust core ABI minor \(found) is older than required minor \(minimum)."
    case .buildInfoFormat(let found, let expected):
      "Rust core build-info format \(found) is incompatible with format \(expected)."
    case .capabilities(let found, let required):
      "Rust core capabilities \(found) do not include required capabilities \(required)."
    case .ffiStatus(let status):
      "Rust core returned ABI status \(status)."
    case .malformedBuildInfo:
      "Rust core returned malformed build information."
    case .reservedField(let value):
      "Rust core ABI reserved field must be zero, found \(value)."
    case .releaseStatus(let status):
      "Rust core buffer release returned status \(status)."
    }
  }

  public var diagnosticCode: String {
    switch self {
    case .abiMajor:
      "abi-major"
    case .abiMinor:
      "abi-minor"
    case .buildInfoFormat:
      "build-info-format"
    case .capabilities:
      "capabilities"
    case .ffiStatus:
      "ffi-status"
    case .malformedBuildInfo:
      "malformed-build-info"
    case .reservedField:
      "reserved-field"
    case .releaseStatus:
      "release-status"
    }
  }
}

public enum XiangqiCoreBinary {
  private static let requiredCapabilities =
    GeneratedFFIABI.capabilityAbiInfo
    | GeneratedFFIABI.capabilityBuildInfo
    | GeneratedFFIABI.capabilityOwnedBuffers

  /// Validates the loaded static library before a Debug build starts using core services.
  public static func validateABIForDebug() -> Result<XiangqiCoreABIInfo, XiangqiCoreError> {
    let versionStatus = xq_ffi_validate_abi(
      GeneratedFFIABI.major,
      GeneratedFFIABI.minimumMinor
    )
    guard versionStatus == GeneratedFFIABI.statusOk else {
      return .failure(.ffiStatus(versionStatus))
    }

    var raw = xq_ffi_abi_info_t()
    let infoStatus = xq_ffi_get_abi_info(&raw)
    guard infoStatus == GeneratedFFIABI.statusOk else {
      return .failure(.ffiStatus(infoStatus))
    }

    return evaluateABI(
      major: raw.abi_major,
      minor: raw.abi_minor,
      capabilities: raw.capabilities,
      buildInfoFormat: raw.build_info_format,
      reserved: raw.reserved
    )
  }

  /// Copies bounded build information before releasing the Rust-owned allocation exactly once.
  public static func buildInfo() -> Result<String, XiangqiCoreError> {
    switch validateABIForDebug() {
    case .failure(let error):
      return .failure(error)
    case .success:
      break
    }

    var raw = xq_owned_buffer_t(data: nil, len: 0, capacity: 0, allocation_token: 0)
    let allocationStatus = xq_ffi_get_build_info(&raw)
    guard allocationStatus == GeneratedFFIABI.statusOk else {
      return .failure(.ffiStatus(allocationStatus))
    }

    guard raw.len <= GeneratedFFIABI.maximumBuildInfoBytes,
      raw.capacity >= raw.len,
      let data = raw.data
    else {
      let releaseStatus = xq_ffi_buffer_release(&raw)
      if releaseStatus != GeneratedFFIABI.statusOk {
        return .failure(.releaseStatus(releaseStatus))
      }
      return .failure(.malformedBuildInfo)
    }

    let copied = Data(bytes: data, count: raw.len)
    let releaseStatus = xq_ffi_buffer_release(&raw)
    guard releaseStatus == GeneratedFFIABI.statusOk else {
      return .failure(.releaseStatus(releaseStatus))
    }
    guard let buildInfo = String(data: copied, encoding: .utf8), !buildInfo.isEmpty else {
      return .failure(.malformedBuildInfo)
    }
    return .success(buildInfo)
  }

  static func evaluateABI(
    major: UInt32,
    minor: UInt32,
    capabilities: UInt64,
    buildInfoFormat: UInt32,
    reserved: UInt32,
    expectedMajor: UInt32 = GeneratedFFIABI.major,
    minimumMinor: UInt32 = GeneratedFFIABI.minimumMinor,
    requiredCapabilities: UInt64 = XiangqiCoreBinary.requiredCapabilities,
    expectedBuildInfoFormat: UInt32 = GeneratedFFIABI.buildInfoFormat
  ) -> Result<XiangqiCoreABIInfo, XiangqiCoreError> {
    guard major == expectedMajor else {
      return .failure(.abiMajor(found: major, expected: expectedMajor))
    }
    guard minor >= minimumMinor else {
      return .failure(.abiMinor(found: minor, minimum: minimumMinor))
    }
    guard buildInfoFormat == expectedBuildInfoFormat else {
      return .failure(.buildInfoFormat(found: buildInfoFormat, expected: expectedBuildInfoFormat))
    }
    guard reserved == 0 else {
      return .failure(.reservedField(reserved))
    }
    guard capabilities & requiredCapabilities == requiredCapabilities else {
      return .failure(.capabilities(found: capabilities, required: requiredCapabilities))
    }
    return .success(
      XiangqiCoreABIInfo(
        major: major,
        minor: minor,
        capabilities: capabilities,
        buildInfoFormat: buildInfoFormat
      )
    )
  }
}
