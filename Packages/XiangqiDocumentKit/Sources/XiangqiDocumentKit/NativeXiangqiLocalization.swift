//! Minimal localization infrastructure (T080).
//!
//! zh-Hans is the development language; en.lproj provides English values.
//! Strings are keyed, human-reviewed terms (docs/15-localization-and-terms.md)
//! and resolved through the DocumentKit resource bundle so both the app and
//! the document package resolve the same tables.

import Foundation

/// Keyed, bundle-resolved strings for the Community app.
public enum NativeXiangqiLocalized {
  /// Resolves a key from the DocumentKit resource bundle (zh-Hans default,
  /// en.lproj override). Falls back to the key itself, never crashing.
  public static func text(_ key: String) -> String {
    let resolved = Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    return resolved.isEmpty || resolved == key
      ? String(localized: String.LocalizationValue(key), bundle: .module) : resolved
  }

  public static let startAnalysis = text("analysis.start")
  public static let pauseAnalysis = text("analysis.pause")
  public static let retryAnalysis = text("analysis.retry")
  public static let presetLight = text("analysis.preset.light")
  public static let presetStandard = text("analysis.preset.standard")
  public static let presetDeep = text("analysis.preset.deep")
  public static let perspectiveRed = text("analysis.perspective.red")
  public static let perspectiveSideToMove = text("analysis.perspective.sideToMove")
  public static let aiOff = text("analysis.ai.off")
  public static let aiRed = text("analysis.ai.red")
  public static let aiBlack = text("analysis.ai.black")
  public static let presetLabel = text("analysis.preset.label")
  public static let perspectiveLabel = text("analysis.perspective.label")
  public static let aiLabel = text("analysis.ai.label")
  public static let copyAdjudication = text("analysis.copy.adjudication")
  public static let statusIdle = text("analysis.status.idle")
  public static let statusStarting = text("analysis.status.starting")
  public static let statusSearching = text("analysis.status.searching")
  public static let statusCacheHit = text("analysis.status.cacheHit")
  public static let statusFinished = text("analysis.status.finished")
  public static let statusStopped = text("analysis.status.stopped")
  public static let statusEngineUnavailable = text("analysis.status.engineUnavailable")
}
