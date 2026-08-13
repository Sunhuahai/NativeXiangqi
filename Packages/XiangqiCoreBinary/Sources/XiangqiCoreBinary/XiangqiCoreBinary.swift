//! Ownership-safe Swift surface for the canonical Rust Xiangqi C ABI.

import Foundation
import XiangqiCoreFFI

public struct XiangqiCoreABIInfo: Equatable, Sendable {
  public let major: UInt32
  public let minor: UInt32
  public let capabilities: UInt64
  public let buildInfoFormat: UInt32
}

public enum XiangqiCoreSide: UInt8, Equatable, Sendable {
  case red = 0
  case black = 1
}

public enum XiangqiCoreTerminal: Equatable, Sendable {
  case ongoing
  case checkmate(winner: XiangqiCoreSide)
  case stalemate(winner: XiangqiCoreSide)
}

/// Disposable immutable data copied from Rust; this is never an authoritative Swift board.
public struct XiangqiCoreBoardSnapshot: Equatable, Sendable {
  public let cells: [UInt8]
  public let sideToMove: XiangqiCoreSide
  public let terminal: XiangqiCoreTerminal
  public let checkedSide: XiangqiCoreSide?
  public let halfmoveClock: UInt32
  public let fullmoveNumber: UInt32
  public let currentNode: UInt32
  public let historyLength: UInt32
  public let profileID: UInt32
  public let profileVersion: UInt32
  public let positionHash: UInt64
  public let repetitionHash: UInt64
}

/// Base evidence only. `wxfResponsibilitySupported` is intentionally false before T070.
public struct XiangqiCoreHistorySummary: Equatable, Sendable {
  public let schemaVersion: UInt16
  public let profileID: UInt32
  public let profileVersion: UInt32
  public let positionCount: UInt32
  public let eventCount: UInt32
  public let repetitionHash: UInt64
  public let hasRepetitionCandidate: Bool
  public let wxfResponsibilitySupported: Bool

  public init(
    schemaVersion: UInt16,
    profileID: UInt32,
    profileVersion: UInt32,
    positionCount: UInt32,
    eventCount: UInt32,
    repetitionHash: UInt64,
    hasRepetitionCandidate: Bool,
    wxfResponsibilitySupported: Bool
  ) {
    self.schemaVersion = schemaVersion
    self.profileID = profileID
    self.profileVersion = profileVersion
    self.positionCount = positionCount
    self.eventCount = eventCount
    self.repetitionHash = repetitionHash
    self.hasRepetitionCandidate = hasRepetitionCandidate
    self.wxfResponsibilitySupported = wxfResponsibilitySupported
  }
}

/// Typed WXF-style adjudication outcomes (T070). `unsupported` and `ambiguous`
/// never declare a winner.
public enum XiangqiCoreAdjudicationVerdict: UInt32, Equatable, Sendable {
  case noAction = 0
  case draw = 1
  case mustChangeRed = 2
  case mustChangeBlack = 3
  case unsupported = 4
  case ambiguous = 5
}

/// The detected repetition cycle in root-to-cursor ply indexes.
public struct XiangqiCoreAdjudicationCycle: Equatable, Sendable {
  public let startPly: UInt32
  public let endPly: UInt32
  public let plyCount: UInt32
  public let repeatCount: UInt32

  public init(startPly: UInt32, endPly: UInt32, plyCount: UInt32, repeatCount: UInt32) {
    self.startPly = startPly
    self.endPly = endPly
    self.plyCount = plyCount
    self.repeatCount = repeatCount
  }
}

/// One versioned per-ply WXF label (raw evidence; Rust owns the verdict).
public struct XiangqiCoreAdjudicationLabel: Equatable, Sendable {
  public let mover: XiangqiCoreSide
  /// 0 check, 1 chase, 2 exchange, 3 idle, 4 unsupported.
  public let classCode: UInt8
  public let chaseTargetID: UInt8
  public let chaseTargetKind: UInt8
  public let chaseProtected: Bool
  public let chaseTradeFavorable: Bool
  public let wasEvading: Bool
  public let resolvedCheck: Bool
  public let from: UInt8
  public let to: UInt8

  public init(
    mover: XiangqiCoreSide,
    classCode: UInt8,
    chaseTargetID: UInt8,
    chaseTargetKind: UInt8,
    chaseProtected: Bool,
    chaseTradeFavorable: Bool,
    wasEvading: Bool,
    resolvedCheck: Bool,
    from: UInt8,
    to: UInt8
  ) {
    self.mover = mover
    self.classCode = classCode
    self.chaseTargetID = chaseTargetID
    self.chaseTargetKind = chaseTargetKind
    self.chaseProtected = chaseProtected
    self.chaseTradeFavorable = chaseTradeFavorable
    self.wasEvading = wasEvading
    self.resolvedCheck = resolvedCheck
    self.from = from
    self.to = to
  }
}

/// The structured adjudication for the current position.
public struct XiangqiCoreAdjudicationResult: Equatable, Sendable {
  public static let maximumPlyCount = 256

  public let schemaVersion: UInt16
  public let profileID: UInt32
  public let profileVersion: UInt32
  public let verdict: XiangqiCoreAdjudicationVerdict
  public let cycle: XiangqiCoreAdjudicationCycle?
  public let labels: [XiangqiCoreAdjudicationLabel]
  public let explanation: String
  public let explanationTruncated: Bool

  public init(
    schemaVersion: UInt16,
    profileID: UInt32,
    profileVersion: UInt32,
    verdict: XiangqiCoreAdjudicationVerdict,
    cycle: XiangqiCoreAdjudicationCycle?,
    labels: [XiangqiCoreAdjudicationLabel],
    explanation: String,
    explanationTruncated: Bool
  ) {
    self.schemaVersion = schemaVersion
    self.profileID = profileID
    self.profileVersion = profileVersion
    self.verdict = verdict
    self.cycle = cycle
    self.labels = labels
    self.explanation = explanation
    self.explanationTruncated = explanationTruncated
  }
}

public enum XiangqiCoreError: Error, Equatable, Sendable, LocalizedError {
  case abiMajor(found: UInt32, expected: UInt32)
  case abiMinor(found: UInt32, minimum: UInt32)
  case buildInfoFormat(found: UInt32, expected: UInt32)
  case capabilities(found: UInt64, required: UInt64)
  case ffiStatus(UInt32)
  case malformedBatch
  case malformedBuildInfo
  case malformedSnapshot
  case reservedField(UInt32)
  case releaseStatus(UInt32)
  case closed
  case invalidSquare(UInt8)
  case mainlineFailure(status: UInt32, ply: UInt32?)
  case fenFailure(status: UInt32, field: XiangqiCoreFENField)
  case malformedFENDiagnostic
  case malformedVariationTree
  case malformedAnnotation

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
    case .malformedBatch:
      "Rust core returned a malformed bounded square batch."
    case .malformedBuildInfo:
      "Rust core returned malformed build information."
    case .malformedSnapshot:
      "Rust core returned a malformed board snapshot."
    case .reservedField(let value):
      "Rust core ABI reserved field must be zero, found \(value)."
    case .releaseStatus(let status):
      "Rust core buffer release returned status \(status)."
    case .closed:
      "The Rust Xiangqi game handle has already been closed."
    case .invalidSquare(let square):
      "Square \(square) is outside the canonical 90-square board."
    case .mainlineFailure(let status, let ply):
      if let ply {
        "Rust core rejected the UCCI mainline at ply \(ply) with status \(status)."
      } else {
        "Rust core rejected the UCCI mainline with status \(status)."
      }
    case .fenFailure(let status, let field):
      "Rust core rejected FEN field \(field.diagnosticCode) with status \(status)."
    case .malformedFENDiagnostic:
      "Rust core returned an inconsistent FEN diagnostic result."
    case .malformedVariationTree:
      "Rust core returned a malformed bounded variation-tree batch."
    case .malformedAnnotation:
      "Rust core returned a malformed bounded node annotation."
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
    case .malformedBatch:
      "malformed-batch"
    case .malformedBuildInfo:
      "malformed-build-info"
    case .malformedSnapshot:
      "malformed-snapshot"
    case .reservedField:
      "reserved-field"
    case .releaseStatus:
      "release-status"
    case .closed:
      "closed"
    case .invalidSquare:
      "invalid-square"
    case .mainlineFailure:
      "mainline-failure"
    case .fenFailure:
      "fen-failure"
    case .malformedFENDiagnostic:
      "malformed-fen-diagnostic"
    case .malformedVariationTree:
      "malformed-variation-tree"
    case .malformedAnnotation:
      "malformed-annotation"
    }
  }
}

public enum XiangqiCoreBinary {
  public static let maximumInputBytes = GeneratedFFIABI.maximumInputBytes
  public static let inputTooLargeStatus = GeneratedFFIABI.statusInputTooLarge

  private static let requiredCapabilities =
    GeneratedFFIABI.capabilityAbiInfo
    | GeneratedFFIABI.capabilityBuildInfo
    | GeneratedFFIABI.capabilityOwnedBuffers
    | GeneratedFFIABI.capabilityGameHandles
    | GeneratedFFIABI.capabilityBatchRules
    | GeneratedFFIABI.capabilityFenUcci
    | GeneratedFFIABI.capabilityBaseHistory
    | GeneratedFFIABI.capabilityDocumentTree
    | GeneratedFFIABI.capabilityDocumentRestore
    | GeneratedFFIABI.capabilityAdjudication

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
    return copyOwnedString(allowEmpty: false) { raw in
      xq_ffi_get_build_info(raw)
    }
  }

  static func copyOwnedString(
    allowEmpty: Bool,
    malformedError: XiangqiCoreError = .malformedBuildInfo,
    fill: (UnsafeMutablePointer<xq_owned_buffer_t>) -> UInt32
  ) -> Result<String, XiangqiCoreError> {
    var raw = xq_owned_buffer_t(data: nil, len: 0, capacity: 0, allocation_token: 0)
    let allocationStatus = fill(&raw)
    guard allocationStatus == GeneratedFFIABI.statusOk else {
      return .failure(.ffiStatus(allocationStatus))
    }
    guard raw.len <= GeneratedFFIABI.maximumOwnedBufferBytes,
      raw.capacity >= raw.len,
      raw.capacity <= GeneratedFFIABI.maximumOwnedBufferBytes,
      raw.allocation_token != 0,
      let data = raw.data
    else {
      let releaseStatus = xq_ffi_buffer_release(&raw)
      if releaseStatus != GeneratedFFIABI.statusOk {
        return .failure(.releaseStatus(releaseStatus))
      }
      return .failure(malformedError)
    }
    let copied = Data(bytes: data, count: raw.len)
    let releaseStatus = xq_ffi_buffer_release(&raw)
    guard releaseStatus == GeneratedFFIABI.statusOk else {
      return .failure(.releaseStatus(releaseStatus))
    }
    guard let value = String(data: copied, encoding: .utf8), allowEmpty || !value.isEmpty else {
      return .failure(malformedError)
    }
    return .success(value)
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

/// Explicitly owned actor around one non-reusable Rust handle.
///
/// All mutable FFI work, including bounded UCCI import, executes away from AppKit's main actor.
public actor XiangqiCoreGame {
  fileprivate var handle: xq_game_handle_t

  private init() {
    handle = 0
  }

  init(validatedHandle: xq_game_handle_t) {
    handle = validatedHandle
  }

  public static func createInitial() async throws -> XiangqiCoreGame {
    let game = XiangqiCoreGame()
    try await game.initializeInitial()
    return game
  }

  public static func fromFEN(_ fen: String) async throws -> XiangqiCoreGame {
    let game = XiangqiCoreGame()
    try await game.initializeFromFEN(fen)
    return game
  }

  private func initializeInitial() throws {
    try XiangqiCoreGame.requireCompatibleABI()
    var created: xq_game_handle_t = 0
    let status = xq_game_create_initial(&created)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
    guard created != 0 else {
      throw XiangqiCoreError.malformedFENDiagnostic
    }
    handle = created
  }

  deinit {
    if handle != 0 {
      _ = xq_game_destroy(&handle)
    }
  }

  private func initializeFromFEN(_ fen: String) throws {
    try XiangqiCoreGame.requireCompatibleABI()
    let bytes = try Self.boundedUTF8(
      fen,
      tooLong: .fenFailure(
        status: GeneratedFFIABI.statusInputTooLarge,
        field: .inputBytes
      )
    )
    var created: xq_game_handle_t = 0
    var result = xq_fen_result_v1_t()
    let status = bytes.withUnsafeBufferPointer { buffer in
      xq_game_create_from_fen_diagnostic(
        buffer.baseAddress,
        UInt64(buffer.count),
        &created,
        &result
      )
    }
    let field = try Self.validateFENDiagnostic(status: status, result: result)
    guard status == GeneratedFFIABI.statusOk else {
      if created != 0 {
        _ = xq_game_destroy(&created)
        throw XiangqiCoreError.malformedFENDiagnostic
      }
      throw XiangqiCoreError.fenFailure(status: status, field: field)
    }
    guard created != 0 else {
      throw XiangqiCoreError.malformedFENDiagnostic
    }
    handle = created
  }

  public func clone() throws -> XiangqiCoreGame {
    var copied: xq_game_handle_t = 0
    let status = xq_game_clone(try liveHandle(), &copied)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
    guard copied != 0 else {
      throw XiangqiCoreError.malformedFENDiagnostic
    }
    return XiangqiCoreGame(validatedHandle: copied)
  }

  public func close() throws {
    guard handle != 0 else {
      throw XiangqiCoreError.closed
    }
    let status = xq_game_destroy(&handle)
    guard status == GeneratedFFIABI.statusOk, handle == 0 else {
      throw XiangqiCoreError.ffiStatus(status)
    }
  }

  public func snapshot() throws -> XiangqiCoreBoardSnapshot {
    var raw = xq_board_snapshot_v1_t()
    let status = xq_game_get_snapshot(try liveHandle(), &raw)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
    return try Self.decodeSnapshot(raw)
  }

  public func selectableSquares() throws -> [UInt8] {
    var raw = xq_square_list_v1_t()
    let status = xq_game_get_selectable_squares(try liveHandle(), &raw)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
    return try Self.decodeSquares(raw)
  }

  public func legalDestinations(from: UInt8) throws -> [UInt8] {
    guard from < 90 else {
      throw XiangqiCoreError.invalidSquare(from)
    }
    var raw = xq_square_list_v1_t()
    let status = xq_game_get_legal_destinations(try liveHandle(), from, &raw)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
    return try Self.decodeSquares(raw)
  }

  public func apply(from: UInt8, to: UInt8) throws {
    guard from < 90 else {
      throw XiangqiCoreError.invalidSquare(from)
    }
    guard to < 90 else {
      throw XiangqiCoreError.invalidSquare(to)
    }
    let move = xq_move_v1_t(from: from, to: to, reserved: 0)
    let status = xq_game_apply_move(try liveHandle(), move)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
  }

  public func undo() throws {
    try requireSuccess(xq_game_undo(try liveHandle()))
  }

  public func redo() throws {
    try requireSuccess(xq_game_redo(try liveHandle()))
  }

  public func redo(childNode: UInt32) throws {
    try requireSuccess(xq_game_redo_child(try liveHandle(), childNode))
  }

  public func navigate(to node: UInt32) throws {
    try requireSuccess(xq_game_navigate(try liveHandle(), node))
  }

  public func fen() throws -> String {
    let currentHandle = try liveHandle()
    let copied = XiangqiCoreBinary.copyOwnedString(
      allowEmpty: false,
      fill: { raw in xq_game_copy_fen(currentHandle, raw) }
    )
    switch copied {
    case .success(let value):
      return value
    case .failure(let error):
      throw error
    }
  }

  public func replace(fromFEN fen: String) throws {
    let bytes = try Self.boundedUTF8(
      fen,
      tooLong: .fenFailure(
        status: GeneratedFFIABI.statusInputTooLarge,
        field: .inputBytes
      )
    )
    let currentHandle = try liveHandle()
    var result = xq_fen_result_v1_t()
    let status = bytes.withUnsafeBufferPointer { buffer in
      xq_game_replace_from_fen_diagnostic(
        currentHandle,
        buffer.baseAddress,
        UInt64(buffer.count),
        &result
      )
    }
    let field = try Self.validateFENDiagnostic(status: status, result: result)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.fenFailure(status: status, field: field)
    }
  }

  public func ucciMainline() throws -> String {
    let currentHandle = try liveHandle()
    let copied = XiangqiCoreBinary.copyOwnedString(
      allowEmpty: true,
      fill: { raw in xq_game_copy_ucci_mainline(currentHandle, raw) }
    )
    switch copied {
    case .success(let value):
      return value
    case .failure(let error):
      throw error
    }
  }

  @discardableResult
  public func applyUCCIMainline(_ mainline: String) throws -> UInt32 {
    let bytes = try Self.boundedUTF8(
      mainline,
      tooLong: .mainlineFailure(status: GeneratedFFIABI.statusInputTooLarge, ply: nil)
    )
    let currentHandle = try liveHandle()
    var result = xq_mainline_result_v1_t()
    let status = bytes.withUnsafeBufferPointer { buffer in
      xq_game_apply_ucci_mainline(currentHandle, buffer.baseAddress, UInt64(buffer.count), &result)
    }
    guard status == GeneratedFFIABI.statusOk, result.status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.mainlineFailure(
        status: status == GeneratedFFIABI.statusOk ? result.status : status,
        ply: result.failed_ply == 0 ? nil : result.failed_ply
      )
    }
    guard result.reserved == 0 else {
      throw XiangqiCoreError.reservedField(result.reserved)
    }
    return result.accepted_plies
  }

  public func historySummary() throws -> XiangqiCoreHistorySummary {
    var raw = xq_history_summary_v1_t()
    let status = xq_game_get_history_summary(try liveHandle(), &raw)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
    return XiangqiCoreHistorySummary(
      schemaVersion: raw.schema_version,
      profileID: raw.profile_id,
      profileVersion: raw.profile_version,
      positionCount: raw.position_count,
      eventCount: raw.event_count,
      repetitionHash: raw.current_repetition_hash,
      hasRepetitionCandidate: raw.has_repetition_candidate != 0,
      wxfResponsibilitySupported: raw.wxf_responsibility_supported != 0
    )
  }

  /// Switches the rule profile transactionally at the root of an empty
  /// history. Repetition identity is re-seeded, so a profile change is visible
  /// in every later hash and cache key.
  public func setProfile(id: UInt32, version: UInt32) throws {
    let status = xq_game_set_profile(try liveHandle(), id, version)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
  }

  /// Queries the versioned WXF-style adjudication for the current position.
  /// Unsupported patterns are explicit; the explanation is deterministic.
  public func adjudication() throws -> XiangqiCoreAdjudicationResult {
    var raw = xq_adjudication_result_v1_t()
    var explanation = xq_owned_buffer_t(
      data: nil, len: 0, capacity: 0, allocation_token: 0)
    let status = xq_game_get_adjudication(try liveHandle(), &raw, &explanation)
    guard status == GeneratedFFIABI.statusOk else {
      if explanation.allocation_token != 0 {
        _ = xq_ffi_buffer_release(&explanation)
      }
      throw XiangqiCoreError.ffiStatus(status)
    }
    defer {
      if explanation.allocation_token != 0 {
        _ = xq_ffi_buffer_release(&explanation)
      }
    }
    guard explanation.len <= GeneratedFFIABI.maximumOwnedBufferBytes,
      let data = explanation.data
    else {
      throw XiangqiCoreError.malformedBuildInfo
    }
    let copied = Data(bytes: data, count: Int(explanation.len))
    guard let text = String(data: copied, encoding: .utf8) else {
      throw XiangqiCoreError.malformedBuildInfo
    }
    guard raw.reserved0 == 0 else {
      throw XiangqiCoreError.reservedField(UInt32(raw.reserved0))
    }
    var labels: [XiangqiCoreAdjudicationLabel] = []
    let labelCount = Int(
      min(raw.label_count, UInt32(XiangqiCoreAdjudicationResult.maximumPlyCount)))
    labels.reserveCapacity(labelCount)
    withUnsafeBytes(of: &raw.labels) { buffer in
      for index in 0..<labelCount {
        let label = buffer.load(
          fromByteOffset: index * MemoryLayout<xq_adjudication_label_v1_t>.stride,
          as: xq_adjudication_label_v1_t.self)
        labels.append(
          XiangqiCoreAdjudicationLabel(
            mover: label.mover == 0 ? .red : .black,
            classCode: label.class,
            chaseTargetID: label.chase_target_id,
            chaseTargetKind: label.chase_target_kind,
            chaseProtected: label.chase_protected != 0,
            chaseTradeFavorable: label.chase_trade_favorable != 0,
            wasEvading: label.was_evading != 0,
            resolvedCheck: label.resolved_check != 0,
            from: label.from,
            to: label.to
          ))
      }
    }
    return XiangqiCoreAdjudicationResult(
      schemaVersion: raw.schema_version,
      profileID: raw.profile_id,
      profileVersion: raw.profile_version,
      verdict: XiangqiCoreAdjudicationVerdict(rawValue: raw.verdict) ?? .ambiguous,
      cycle: raw.has_cycle != 0
        ? XiangqiCoreAdjudicationCycle(
          startPly: raw.cycle.start_ply,
          endPly: raw.cycle.end_ply,
          plyCount: raw.cycle.ply_count,
          repeatCount: raw.cycle.repeat_count
        ) : nil,
      labels: labels,
      explanation: text,
      explanationTruncated: raw.explanation_truncated != 0
    )
  }

  static func requireCompatibleABI() throws {
    switch XiangqiCoreBinary.validateABIForDebug() {
    case .success:
      return
    case .failure(let error):
      throw error
    }
  }

  static func boundedUTF8(_ text: String, tooLong: XiangqiCoreError) throws -> [UInt8] {
    guard text.utf8.count <= GeneratedFFIABI.maximumInputBytes else {
      throw tooLong
    }
    return Array(text.utf8)
  }

  static func validateFENDiagnostic(
    status: UInt32,
    result: xq_fen_result_v1_t
  ) throws -> XiangqiCoreFENField {
    guard result.reserved0 == 0, result.reserved1 == 0 else {
      throw XiangqiCoreError.reservedField(
        result.reserved0 != 0 ? result.reserved0 : result.reserved1)
    }
    guard status == result.status else {
      throw XiangqiCoreError.malformedFENDiagnostic
    }
    let field = XiangqiCoreFENField(rawValue: result.field) ?? .unknown
    guard status != GeneratedFFIABI.statusOk || field == .none else {
      throw XiangqiCoreError.malformedFENDiagnostic
    }
    return field
  }

  func liveHandle() throws -> xq_game_handle_t {
    guard handle != 0 else {
      throw XiangqiCoreError.closed
    }
    return handle
  }

  func requireSuccess(_ status: UInt32) throws {
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
  }

  private static func decodeSquares(_ raw: xq_square_list_v1_t) throws -> [UInt8] {
    guard raw.reserved == 0, raw.reserved_tail.0 == 0, raw.reserved_tail.1 == 0,
      raw.count <= 90
    else {
      throw XiangqiCoreError.malformedBatch
    }
    let values = withUnsafeBytes(of: raw.squares) { bytes in
      Array(bytes.prefix(Int(raw.count)))
    }
    guard values.allSatisfy({ $0 < 90 }), Set(values).count == values.count else {
      throw XiangqiCoreError.malformedBatch
    }
    return values
  }

  static func decodeSnapshot(_ raw: xq_board_snapshot_v1_t) throws
    -> XiangqiCoreBoardSnapshot
  {
    guard raw.reserved0.0 == 0, raw.reserved0.1 == 0, raw.reserved0.2 == 0,
      let side = XiangqiCoreSide(rawValue: raw.side_to_move)
    else {
      throw XiangqiCoreError.malformedSnapshot
    }
    let checkedSide: XiangqiCoreSide?
    if raw.checked_side == 2 {
      checkedSide = nil
    } else if let value = XiangqiCoreSide(rawValue: raw.checked_side) {
      checkedSide = value
    } else {
      throw XiangqiCoreError.malformedSnapshot
    }
    let winner: XiangqiCoreSide?
    if raw.terminal_winner == 2 {
      winner = nil
    } else if let value = XiangqiCoreSide(rawValue: raw.terminal_winner) {
      winner = value
    } else {
      throw XiangqiCoreError.malformedSnapshot
    }
    let terminal: XiangqiCoreTerminal
    switch raw.terminal_kind {
    case 0 where winner == nil:
      terminal = .ongoing
    case 1:
      guard let winner else {
        throw XiangqiCoreError.malformedSnapshot
      }
      terminal = .checkmate(winner: winner)
    case 2:
      guard let winner else {
        throw XiangqiCoreError.malformedSnapshot
      }
      terminal = .stalemate(winner: winner)
    default:
      throw XiangqiCoreError.malformedSnapshot
    }
    let cells = withUnsafeBytes(of: raw.cells) { Array($0) }
    guard cells.count == 90, cells.allSatisfy({ $0 <= 14 }) else {
      throw XiangqiCoreError.malformedSnapshot
    }
    return XiangqiCoreBoardSnapshot(
      cells: cells,
      sideToMove: side,
      terminal: terminal,
      checkedSide: checkedSide,
      halfmoveClock: raw.halfmove_clock,
      fullmoveNumber: raw.fullmove_number,
      currentNode: raw.current_node_id,
      historyLength: raw.history_length,
      profileID: raw.profile_id,
      profileVersion: raw.profile_version,
      positionHash: raw.position_hash,
      repetitionHash: raw.repetition_hash
    )
  }
}
