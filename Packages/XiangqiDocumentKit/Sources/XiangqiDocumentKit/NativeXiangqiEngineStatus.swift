//! Minimal, offline engine-asset status for the T050 shell.
//!
//! The app never executes an arbitrary binary and never downloads assets. This
//! status only verifies that the bundled helper and NNUE match the embedded
//! locked manifest, so UI can say "analysis unavailable" precisely when the
//! assets are missing or corrupted. Full analysis UI is T060.

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

/// Offline verification of the embedded engine assets.
public enum NativeXiangqiEngineAssets {
  /// Bounded status text for the analysis placeholder pane.
  public static func engineStatusText(in bundle: Bundle = .main) -> String {
    switch status(in: bundle) {
    case .available:
      return "引擎资源已就绪（Pikafish 2026-01-02）。分析面板将于后续版本启用。"
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
