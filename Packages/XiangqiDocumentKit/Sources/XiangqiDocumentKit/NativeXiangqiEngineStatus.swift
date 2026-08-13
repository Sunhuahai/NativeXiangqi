//! Offline engine-asset verification for T050's shell and T060's launch path.
//!
//! The app never executes an arbitrary binary and never downloads assets. The
//! helper and NNUE are verified against the embedded locked manifest before any
//! process is launched; hashing and manifest parsing happen on an actor, never
//! on the main actor.

import CommonCrypto
import Foundation

/// The verified state of the bundled engine assets.
public enum NativeXiangqiEngineStatus: Sendable, Equatable {
  /// The helper and NNUE are present and hash-verified against the manifest.
  case available
  /// The helper or NNUE is absent from the bundle.
  case missing
  /// An asset hash does not match the locked manifest.
  case invalid
}

/// Typed, verified launch material. Only these URLs may be handed to the
/// Pikafish session; no user-selected path is ever accepted.
public struct NativeXiangqiVerifiedEngineDescriptor: Sendable, Equatable {
  public let helperURL: URL
  public let resourcesURL: URL
  public let engineCommit: String
  public let helperSHA256: String
  public let networkSHA256: String
  public let networkBytes: Int64

  public init(
    helperURL: URL,
    resourcesURL: URL,
    engineCommit: String,
    helperSHA256: String,
    networkSHA256: String,
    networkBytes: Int64
  ) {
    self.helperURL = helperURL
    self.resourcesURL = resourcesURL
    self.engineCommit = engineCommit
    self.helperSHA256 = helperSHA256
    self.networkSHA256 = networkSHA256
    self.networkBytes = networkBytes
  }
}

/// Actor-owned, off-main verification of the embedded engine assets.
public actor NativeXiangqiEngineAssetVerifier {
  private let bundle: Bundle

  public init(bundle: Bundle = .main) {
    self.bundle = bundle
  }

  /// Verifies helper/NNUE hashes against the embedded manifest and returns a
  /// typed descriptor, or nil when assets are missing or invalid.
  public func verify() async -> NativeXiangqiVerifiedEngineDescriptor? {
    guard let engineURL = bundle.url(forResource: "Engine", withExtension: nil),
      let manifestURL = bundle.url(
        forResource: "engine-manifest", withExtension: "toml", subdirectory: "Engine")
    else {
      return nil
    }
    guard let manifest = try? lockedManifest(in: manifestURL),
      let helperHash = manifest.helper.sha256, let networkHash = manifest.network.sha256
    else {
      return nil
    }
    let helperURL = engineURL.appendingPathComponent("pikafish")
    let networkURL = engineURL.appendingPathComponent("pikafish.nnue")
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: helperURL.path),
      fileManager.fileExists(atPath: networkURL.path)
    else {
      return nil
    }
    guard let actualHelper = Self.sha256(of: helperURL), actualHelper == helperHash,
      let actualNetwork = Self.sha256(of: networkURL), actualNetwork == networkHash
    else {
      return nil
    }
    guard let attributes = try? fileManager.attributesOfItem(atPath: networkURL.path),
      let bytes = (attributes[.size] as? NSNumber)?.int64Value
    else {
      return nil
    }
    return NativeXiangqiVerifiedEngineDescriptor(
      helperURL: helperURL,
      resourcesURL: engineURL,
      engineCommit: manifest.engine.commit,
      helperSHA256: helperHash,
      networkSHA256: networkHash,
      networkBytes: bytes
    )
  }

  private struct LockedManifest {
    struct Engine {
      var commit = ""
    }

    struct Helper {
      var sha256: String?
    }

    struct Network {
      var sha256: String?
    }

    var engine = Engine()
    var helper = Helper()
    var network = Network()
  }

  private func lockedManifest(in manifestURL: URL) throws -> LockedManifest {
    let text = try String(contentsOf: manifestURL, encoding: .utf8)
    guard text.utf8.count <= 64 * 1024 else {
      throw CocoaError(.fileReadTooLarge)
    }
    var manifest = LockedManifest()
    func section(_ name: String) -> Substring? {
      guard let start = text.range(of: "[\(name)]") else {
        return nil
      }
      let remainder = text[start.upperBound...]
      let end = remainder.range(of: "\n[")?.lowerBound ?? remainder.endIndex
      guard end >= remainder.startIndex else {
        return nil
      }
      return remainder[..<end]
    }
    func value(_ key: String, in section: Substring?) -> String? {
      guard let section, let range = section.range(of: "\(key) = \"") else {
        return nil
      }
      let remainder = section[range.upperBound...]
      guard let end = remainder.firstIndex(of: "\"") else {
        return nil
      }
      return String(remainder[..<end])
    }
    if let commit = value("commit", in: section("engine")) {
      manifest.engine.commit = commit
    }
    manifest.helper.sha256 = value("sha256", in: section("helper")).flatMap {
      $0.utf8.count == 64 ? $0 : nil
    }
    manifest.network.sha256 = value("sha256", in: section("network")).flatMap {
      $0.utf8.count == 64 ? $0 : nil
    }
    return manifest
  }

  private static func sha256(of url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      data.count <= 256 * 1024 * 1024
    else {
      return nil
    }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { raw in
      _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// Offline verification of the embedded engine assets.
public enum NativeXiangqiEngineAssets {
  /// Bounded status text for the analysis placeholder pane.
  public static func engineStatusText(in bundle: Bundle = .main) -> String {
    switch status(in: bundle) {
    case .available:
      return "引擎资源已就绪（Pikafish 2026-01-02）。"
    case .missing:
      return "引擎资源缺失，分析不可用；本地对弈与棋谱编辑不受影响。"
    case .invalid:
      return "引擎资源校验失败，分析不可用；本地对弈与棋谱编辑不受影响。"
    }
  }

  /// Reads the embedded development manifest's locked hashes.
  static func lockedHashes(in manifestURL: URL) throws -> (helper: String, network: String) {
    let text = try String(contentsOf: manifestURL, encoding: .utf8)
    guard text.utf8.count <= 64 * 1024 else {
      throw CocoaError(.fileReadTooLarge)
    }
    func section(_ name: String) -> Substring? {
      guard let start = text.range(of: "[\(name)]") else {
        return nil
      }
      let remainder = text[start.upperBound...]
      let end = remainder.range(of: "\n[")?.lowerBound ?? remainder.endIndex
      guard end >= remainder.startIndex else {
        return nil
      }
      return remainder[..<end]
    }
    func sha256Value(in section: Substring?) -> String? {
      guard let section, let range = section.range(of: "sha256 = \"") else {
        return nil
      }
      let remainder = section[range.upperBound...]
      guard let end = remainder.firstIndex(of: "\"") else {
        return nil
      }
      let value = String(remainder[..<end])
      return value.utf8.count == 64 ? value : nil
    }
    guard let helper = sha256Value(in: section("helper")),
      let network = sha256Value(in: section("network"))
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return (helper, network)
  }

  /// Verifies the bundled assets against the embedded manifest. Reads only
  /// the bundle's own Engine directory; never touches the network or user
  /// paths.
  public static func status(in bundle: Bundle = .main) -> NativeXiangqiEngineStatus {
    guard let engineURL = bundle.url(forResource: "Engine", withExtension: nil),
      let manifestURL = bundle.url(
        forResource: "engine-manifest", withExtension: "toml", subdirectory: "Engine")
    else {
      return .missing
    }
    return status(engineDirectory: engineURL, manifestURL: manifestURL)
  }

  /// URL-based verification used by the bundle entry point and the tests.
  static func status(
    engineDirectory: URL,
    manifestURL: URL
  ) -> NativeXiangqiEngineStatus {
    let helperURL = engineDirectory.appendingPathComponent("pikafish")
    let networkURL = engineDirectory.appendingPathComponent("pikafish.nnue")
    let helperExists = FileManager.default.fileExists(atPath: helperURL.path)
    let networkExists = FileManager.default.fileExists(atPath: networkURL.path)
    guard helperExists, networkExists else {
      return .missing
    }
    let hashes: (helper: String, network: String)
    do {
      hashes = try lockedHashes(in: manifestURL)
    } catch {
      return .invalid
    }
    func sha256(of url: URL) -> String? {
      guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
        data.count <= 256 * 1024 * 1024
      else {
        return nil
      }
      var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
      data.withUnsafeBytes { raw in
        _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &digest)
      }
      return digest.map { String(format: "%02x", $0) }.joined()
    }
    guard let helperHash = sha256(of: helperURL), let networkHash = sha256(of: networkURL) else {
      return .invalid
    }
    guard helperHash == hashes.helper, networkHash == hashes.network else {
      return .invalid
    }
    return .available
  }
}
