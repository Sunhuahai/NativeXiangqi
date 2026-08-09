//! Immutable, Rust-derived variation snapshots used by the native document layer.
//!
//! The values in this file are transport records only. Rust still validates every
//! replayed move, owns every retained branch and annotation, and reconstructs all
//! hashes and terminal state during restore.

import Foundation
import Synchronization
import XiangqiCoreFFI

/// Stable field identifiers emitted by the Rust FEN diagnostic POD result.
public enum XiangqiCoreFENField: UInt32, Equatable, Sendable {
  case none = 0
  case inputBytes = 1
  case ascii = 2
  case fieldCount = 3
  case placement = 4
  case sideToMove = 5
  case placeholder = 6
  case halfmove = 7
  case fullmove = 8
  case position = 9
  /// A future Rust field value is never silently treated as a known field.
  case unknown = 4_294_967_295

  public var diagnosticCode: String {
    switch self {
    case .none:
      "none"
    case .inputBytes:
      "input-bytes"
    case .ascii:
      "ascii"
    case .fieldCount:
      "field-count"
    case .placement:
      "placement"
    case .sideToMove:
      "side-to-move"
    case .placeholder:
      "placeholder"
    case .halfmove:
      "halfmove"
    case .fullmove:
      "fullmove"
    case .position:
      "position"
    case .unknown:
      "unknown"
    }
  }

}

/// One canonical coordinate move retained in a variation tree.
public struct XiangqiCoreVariationMove: Equatable, Hashable, Sendable {
  public let from: UInt8
  public let to: UInt8

  public init?(from: UInt8, to: UInt8) {
    guard from < 90, to < 90, from != to else {
      return nil
    }
    self.from = from
    self.to = to
  }
}

/// One direct child emitted by Rust in the arena's stable insertion order.
public struct XiangqiCoreVariationChild: Equatable, Sendable {
  public let nodeID: UInt32
  public let move: XiangqiCoreVariationMove
  public let isSelected: Bool
}

/// One flat node in an immutable Rust-derived document snapshot.
public struct XiangqiCoreDocumentNode: Equatable, Sendable {
  public let nodeID: UInt32
  public let parentNodeID: UInt32?
  public let move: XiangqiCoreVariationMove?
  public let childNodeIDs: [UInt32]
  public let selectedChildNodeID: UInt32?
  public let annotation: String

  public init(
    nodeID: UInt32,
    parentNodeID: UInt32?,
    move: XiangqiCoreVariationMove?,
    childNodeIDs: [UInt32],
    selectedChildNodeID: UInt32?,
    annotation: String
  ) {
    self.nodeID = nodeID
    self.parentNodeID = parentNodeID
    self.move = move
    self.childNodeIDs = childNodeIDs
    self.selectedChildNodeID = selectedChildNodeID
    self.annotation = annotation
  }
}

/// A complete immutable core record suitable for a versioned `.xqgame` envelope.
public struct XiangqiCoreDocumentSnapshot: Equatable, Sendable {
  public static let maximumNodes = 4_096
  public static let maximumDepth = 4_096
  public static let maximumAnnotationBytesPerNode = 64 * 1024
  public static let maximumTotalAnnotationBytes = 16 * 1024 * 1024
  public static let maximumFENBytes = 4 * 1024

  public let initialFEN: String
  public let profileID: UInt32
  public let profileVersion: UInt32
  public let currentNodeID: UInt32
  public let nodes: [XiangqiCoreDocumentNode]

  public init(
    initialFEN: String,
    profileID: UInt32,
    profileVersion: UInt32,
    currentNodeID: UInt32,
    nodes: [XiangqiCoreDocumentNode]
  ) {
    self.initialFEN = initialFEN
    self.profileID = profileID
    self.profileVersion = profileVersion
    self.currentNodeID = currentNodeID
    self.nodes = nodes
  }
}

/// A bounded, unpublished Rust reconstruction prepared on NSDocument's permitted
/// background read path.
///
/// This is deliberately a reference type: AppKit's nonisolated read handoff and
/// its capacity-one cache can copy their enclosing transport values. All copies
/// share one mutex-protected opaque token, so exactly one caller can consume or
/// discard it. A later aliased consume/discard observes the cleared token and
/// fails closed instead of creating a second Swift owner for one Rust handle.
///
/// It intentionally exposes no board or rule data to Swift. The eventual live
/// `XiangqiCoreGame` remains the sole canonical owner after consumption.
public final class XiangqiCorePreparedDocument: Sendable {
  private let ownership: Mutex<xq_game_handle_t>
  public let snapshot: XiangqiCoreBoardSnapshot
  public let canonicalInitialFEN: String

  fileprivate init(
    handle: xq_game_handle_t,
    snapshot: XiangqiCoreBoardSnapshot,
    canonicalInitialFEN: String
  ) {
    ownership = Mutex(handle)
    self.snapshot = snapshot
    self.canonicalInitialFEN = canonicalInitialFEN
  }

  fileprivate func takeHandle() -> xq_game_handle_t {
    ownership.withLock { handle in
      defer { handle = 0 }
      return handle
    }
  }

  deinit {
    var handle = takeHandle()
    guard handle != 0 else {
      return
    }
    _ = xq_game_destroy(&handle)
  }
}

/// A field-addressable restore failure. DocumentKit surfaces only this stable field
/// and code, never the user's full FEN, comment, metadata, or file path in logs.
public enum XiangqiCoreDocumentError: Error, Equatable, Sendable, LocalizedError {
  case field(String)
  case core(field: String, error: XiangqiCoreError)

  public var errorDescription: String? {
    switch self {
    case .field(let field):
      "The Xiangqi document field \(field) is invalid."
    case .core(let field, let error):
      "The Xiangqi document field \(field) was rejected by Rust: \(error.diagnosticCode)."
    }
  }

  public var diagnosticCode: String {
    switch self {
    case .field:
      "document-field"
    case .core(_, let error):
      "document-\(error.diagnosticCode)"
    }
  }

  public var field: String {
    switch self {
    case .field(let field), .core(let field, _):
      field
    }
  }
}

extension XiangqiCoreGame {
  /// Rebuilds a complete Rust game synchronously for `NSDocument.read`. AppKit
  /// guarantees that read happens off the main thread when
  /// `canConcurrentlyReadDocuments` is enabled. Unlike a preflight-only check,
  /// this returns a fully reconstructed unpublished game token so opening never
  /// reports success and then attempts a second potentially failing replay while
  /// installing a window.
  public static func prepareDocumentSnapshotForOpen(_ snapshot: XiangqiCoreDocumentSnapshot) throws
    -> XiangqiCorePreparedDocument
  {
    try validateDocumentSnapshot(snapshot)
    var restore: XiangqiCoreDocumentRestoreSession
    do {
      restore = try XiangqiCoreDocumentRestoreSession(initialFEN: snapshot.initialFEN)
    } catch let error as XiangqiCoreError {
      throw XiangqiCoreDocumentError.core(field: "initialFEN", error: error)
    }
    do {
      for (offset, node) in snapshot.nodes.dropFirst().enumerated() {
        if offset.isMultiple(of: 32) {
          try Task.checkCancellation()
        }
        guard let parent = node.parentNodeID, let move = node.move else {
          throw XiangqiCoreDocumentError.field("variationTree.nodes[\(node.nodeID)]")
        }
        do {
          try restore.append(node: node.nodeID, parent: parent, move: move)
        } catch let error as XiangqiCoreError {
          throw XiangqiCoreDocumentError.core(
            field: "variationTree.nodes[\(node.nodeID)]", error: error)
        }
      }
      for (offset, node) in snapshot.nodes.enumerated() {
        if offset.isMultiple(of: 32) {
          try Task.checkCancellation()
        }
        do {
          try restore.setAnnotation(node: node.nodeID, text: node.annotation)
        } catch let error as XiangqiCoreError {
          throw XiangqiCoreDocumentError.core(
            field: "annotations[\(node.nodeID)]", error: error)
        }
      }
      do {
        try restore.navigate(to: snapshot.currentNodeID)
      } catch let error as XiangqiCoreError {
        throw XiangqiCoreDocumentError.core(field: "currentNode", error: error)
      }
      for (offset, node) in snapshot.nodes.enumerated() {
        if offset.isMultiple(of: 32) {
          try Task.checkCancellation()
        }
        guard let child = node.selectedChildNodeID else {
          continue
        }
        do {
          try restore.selectChild(parent: node.nodeID, child: child)
        } catch let error as XiangqiCoreError {
          throw XiangqiCoreDocumentError.core(
            field: "variationTree.nodes[\(node.nodeID)].selectedChild", error: error)
        }
      }
      var handle = try restore.finish()
      do {
        var raw = xq_board_snapshot_v1_t()
        let status = xq_game_get_snapshot(handle, &raw)
        guard status == GeneratedFFIABI.statusOk else {
          throw XiangqiCoreError.ffiStatus(status)
        }
        let canonicalInitialFEN = try canonicalInitialFEN(for: handle)
        return XiangqiCorePreparedDocument(
          handle: handle,
          snapshot: try XiangqiCoreGame.decodeSnapshot(raw),
          canonicalInitialFEN: canonicalInitialFEN
        )
      } catch {
        _ = xq_game_destroy(&handle)
        throw error
      }
    } catch {
      restore.destroy()
      throw error
    }
  }

  /// Transfers the one-owner prepared game into the actor. Transport copies share
  /// the same synchronized claim, so only the first caller can receive an actor.
  public static func consumePreparedDocument(_ prepared: XiangqiCorePreparedDocument) throws
    -> XiangqiCoreGame
  {
    let handle = prepared.takeHandle()
    guard handle != 0 else {
      throw XiangqiCoreError.closed
    }
    return XiangqiCoreGame(validatedHandle: handle)
  }

  /// Releases an unpublished prepared game when an open is superseded or the
  /// document closes before its window controller consumes the candidate.
  public static func discardPreparedDocument(_ prepared: XiangqiCorePreparedDocument) {
    var handle = prepared.takeHandle()
    guard handle != 0 else {
      return
    }
    _ = xq_game_destroy(&handle)
  }

  private static func canonicalInitialFEN(for handle: xq_game_handle_t) throws -> String {
    var rootCopy: xq_game_handle_t = 0
    let cloneStatus = xq_game_clone(handle, &rootCopy)
    guard cloneStatus == GeneratedFFIABI.statusOk, rootCopy != 0 else {
      if rootCopy != 0 {
        _ = xq_game_destroy(&rootCopy)
      }
      throw XiangqiCoreError.ffiStatus(cloneStatus)
    }
    defer {
      _ = xq_game_destroy(&rootCopy)
    }
    let navigateStatus = xq_game_navigate(rootCopy, 0)
    guard navigateStatus == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(navigateStatus)
    }
    switch XiangqiCoreBinary.copyOwnedString(
      allowEmpty: false,
      malformedError: .malformedFENDiagnostic,
      fill: { raw in xq_game_copy_fen(rootCopy, raw) }
    ) {
    case .success(let fen):
      return fen
    case .failure(let error):
      throw error
    }
  }

  /// Enumerates a complete, immutable snapshot from Rust without touching the live
  /// cursor. A clone is navigated to root only to obtain the canonical initial FEN.
  public func documentSnapshot() async throws -> XiangqiCoreDocumentSnapshot {
    let current = try snapshot()
    let copy = try clone()
    do {
      try await copy.navigate(to: 0)
      let initialFEN = try await copy.fen()
      var pending: [(nodeID: UInt32, parentNodeID: UInt32?, move: XiangqiCoreVariationMove?)] = [
        (nodeID: 0, parentNodeID: nil, move: nil)
      ]
      var visited = Set<UInt32>()
      var records: [UInt32: XiangqiCoreDocumentNode] = [:]
      records.reserveCapacity(XiangqiCoreDocumentSnapshot.maximumNodes)

      while let item = pending.popLast() {
        if visited.count.isMultiple(of: 32) {
          try Task.checkCancellation()
          await Task.yield()
        }
        guard visited.insert(item.nodeID).inserted,
          visited.count <= XiangqiCoreDocumentSnapshot.maximumNodes
        else {
          throw XiangqiCoreError.malformedVariationTree
        }
        let annotation = try await copy.annotation(node: item.nodeID)
        let children = try await copy.variationChildren(parentNode: item.nodeID)
        let childNodeIDs = children.map(\.nodeID)
        let selectedChildren = children.filter(\.isSelected)
        guard selectedChildren.count <= 1 else {
          throw XiangqiCoreError.malformedVariationTree
        }
        records[item.nodeID] = XiangqiCoreDocumentNode(
          nodeID: item.nodeID,
          parentNodeID: item.parentNodeID,
          move: item.move,
          childNodeIDs: childNodeIDs,
          selectedChildNodeID: selectedChildren.first?.nodeID,
          annotation: annotation
        )
        for child in children.reversed() {
          pending.append((nodeID: child.nodeID, parentNodeID: item.nodeID, move: child.move))
        }
      }
      let nodes = records.values.sorted { $0.nodeID < $1.nodeID }
      let snapshot = XiangqiCoreDocumentSnapshot(
        initialFEN: initialFEN,
        profileID: current.profileID,
        profileVersion: current.profileVersion,
        currentNodeID: current.currentNode,
        nodes: nodes
      )
      try Self.validateDocumentSnapshot(snapshot)
      try await copy.close()
      return snapshot
    } catch {
      do {
        try await copy.close()
      } catch let closeError as XiangqiCoreError {
        // The clone owns an independent FFI token. A failed release is never
        // silently discarded, because callers must be able to quarantine the
        // operation rather than assume the resource boundary was restored.
        throw XiangqiCoreDocumentError.core(field: "documentSnapshot.close", error: closeError)
      }
      throw error
    }
  }

  /// Creates an isolated Rust-owned candidate and publishes it only after every
  /// flat node, annotation, cursor, and selected child has been replayed. The
  /// FFI restore transaction mutates only unpublished state, so this path avoids
  /// cloning the growing arena for each of up to 4,096 document nodes.
  public static func fromDocumentSnapshot(_ snapshot: XiangqiCoreDocumentSnapshot) async throws
    -> XiangqiCoreGame
  {
    try validateDocumentSnapshot(snapshot)
    var restore: XiangqiCoreDocumentRestoreSession
    do {
      restore = try XiangqiCoreDocumentRestoreSession(initialFEN: snapshot.initialFEN)
    } catch let error as XiangqiCoreError {
      throw XiangqiCoreDocumentError.core(field: "initialFEN", error: error)
    }
    do {
      for (offset, node) in snapshot.nodes.dropFirst().enumerated() {
        if offset.isMultiple(of: 32) {
          try Task.checkCancellation()
          await Task.yield()
        }
        guard let parent = node.parentNodeID, let move = node.move else {
          throw XiangqiCoreDocumentError.field("variationTree.nodes[\(node.nodeID)]")
        }
        do {
          try restore.append(node: node.nodeID, parent: parent, move: move)
        } catch let error as XiangqiCoreError {
          throw XiangqiCoreDocumentError.core(
            field: "variationTree.nodes[\(node.nodeID)]", error: error)
        }
      }
      for (offset, node) in snapshot.nodes.enumerated() {
        if offset.isMultiple(of: 32) {
          try Task.checkCancellation()
          await Task.yield()
        }
        do {
          try restore.setAnnotation(node: node.nodeID, text: node.annotation)
        } catch let error as XiangqiCoreError {
          throw XiangqiCoreDocumentError.core(
            field: "annotations[\(node.nodeID)]", error: error)
        }
      }
      do {
        try restore.navigate(to: snapshot.currentNodeID)
      } catch let error as XiangqiCoreError {
        throw XiangqiCoreDocumentError.core(field: "currentNode", error: error)
      }
      for (offset, node) in snapshot.nodes.enumerated() {
        if offset.isMultiple(of: 32) {
          try Task.checkCancellation()
          await Task.yield()
        }
        guard let child = node.selectedChildNodeID else {
          continue
        }
        do {
          try restore.selectChild(parent: node.nodeID, child: child)
        } catch let error as XiangqiCoreError {
          throw XiangqiCoreDocumentError.core(
            field: "variationTree.nodes[\(node.nodeID)].selectedChild", error: error)
        }
      }
      return XiangqiCoreGame(validatedHandle: try restore.finish())
    } catch {
      restore.destroy()
      throw error
    }
  }

  /// Performs the same bounded Rust candidate transaction used by document
  /// restore, without publishing an actor-visible game. `NSDocument.read` invokes
  /// this only from its permitted background read path so an illegal variation is
  /// an open failure, not a late "opened successfully" UI error.
  public static func preflightDocumentSnapshot(_ snapshot: XiangqiCoreDocumentSnapshot) throws {
    try validateDocumentSnapshot(snapshot)
    var restore: XiangqiCoreDocumentRestoreSession
    do {
      restore = try XiangqiCoreDocumentRestoreSession(initialFEN: snapshot.initialFEN)
    } catch let error as XiangqiCoreError {
      throw XiangqiCoreDocumentError.core(field: "initialFEN", error: error)
    }
    var publishedHandle: xq_game_handle_t = 0
    defer {
      restore.destroy()
      if publishedHandle != 0 {
        _ = xq_game_destroy(&publishedHandle)
      }
    }
    for node in snapshot.nodes.dropFirst() {
      guard let parent = node.parentNodeID, let move = node.move else {
        throw XiangqiCoreDocumentError.field("variationTree.nodes[\(node.nodeID)]")
      }
      do {
        try restore.append(node: node.nodeID, parent: parent, move: move)
      } catch let error as XiangqiCoreError {
        throw XiangqiCoreDocumentError.core(
          field: "variationTree.nodes[\(node.nodeID)]", error: error)
      }
    }
    for node in snapshot.nodes {
      do {
        try restore.setAnnotation(node: node.nodeID, text: node.annotation)
      } catch let error as XiangqiCoreError {
        throw XiangqiCoreDocumentError.core(
          field: "annotations[\(node.nodeID)]", error: error)
      }
    }
    do {
      try restore.navigate(to: snapshot.currentNodeID)
    } catch let error as XiangqiCoreError {
      throw XiangqiCoreDocumentError.core(field: "currentNode", error: error)
    }
    for node in snapshot.nodes {
      guard let child = node.selectedChildNodeID else {
        continue
      }
      do {
        try restore.selectChild(parent: node.nodeID, child: child)
      } catch let error as XiangqiCoreError {
        throw XiangqiCoreDocumentError.core(
          field: "variationTree.nodes[\(node.nodeID)].selectedChild", error: error)
      }
    }
    publishedHandle = try restore.finish()
  }

  public func variationChildren(parentNode: UInt32) throws -> [XiangqiCoreVariationChild] {
    var raw = xq_variation_child_list_v1_t()
    let status = xq_game_get_variation_children(try liveHandle(), parentNode, &raw)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
    guard raw.reserved == 0, raw.count <= 256 else {
      throw XiangqiCoreError.malformedVariationTree
    }
    let rawChildren = withUnsafeBytes(of: raw.children) { bytes in
      Array(bytes.bindMemory(to: xq_variation_child_v1_t.self).prefix(Int(raw.count)))
    }
    var seen = Set<UInt32>()
    var selectedCount = 0
    let decoded = try rawChildren.map { child -> XiangqiCoreVariationChild in
      guard child.reserved0 == 0, child.reserved1 == 0,
        child.node_id != 0,
        seen.insert(child.node_id).inserted,
        child.is_selected == 0 || child.is_selected == 1,
        let move = XiangqiCoreVariationMove(from: child.from, to: child.to)
      else {
        throw XiangqiCoreError.malformedVariationTree
      }
      selectedCount += Int(child.is_selected)
      guard selectedCount <= 1 else {
        throw XiangqiCoreError.malformedVariationTree
      }
      return XiangqiCoreVariationChild(
        nodeID: child.node_id,
        move: move,
        isSelected: child.is_selected == 1
      )
    }
    return decoded
  }

  public func annotation(node: UInt32) throws -> String {
    let currentHandle = try liveHandle()
    let copied = XiangqiCoreBinary.copyOwnedString(
      allowEmpty: true,
      malformedError: .malformedAnnotation,
      fill: { raw in xq_game_copy_annotation(currentHandle, node, raw) }
    )
    switch copied {
    case .success(let value):
      return value
    case .failure(let error):
      throw error
    }
  }

  public func setAnnotation(node: UInt32, text: String) throws {
    let bytes = try Self.boundedUTF8(
      text,
      tooLong: .ffiStatus(GeneratedFFIABI.statusInputTooLarge)
    )
    let currentHandle = try liveHandle()
    let status = bytes.withUnsafeBufferPointer { buffer in
      xq_game_set_annotation(currentHandle, node, buffer.baseAddress, UInt64(buffer.count))
    }
    try requireSuccess(status)
  }

  public func selectChild(parentNode: UInt32, childNode: UInt32) throws {
    try requireSuccess(xq_game_select_child(try liveHandle(), parentNode, childNode))
  }

  public static func validateDocumentSnapshot(_ snapshot: XiangqiCoreDocumentSnapshot) throws {
    guard snapshot.initialFEN.utf8.count <= XiangqiCoreDocumentSnapshot.maximumFENBytes else {
      throw XiangqiCoreDocumentError.field("initialFEN")
    }
    guard snapshot.profileID == 1, snapshot.profileVersion == 1 else {
      throw XiangqiCoreDocumentError.field("ruleProfile")
    }
    guard !snapshot.nodes.isEmpty,
      snapshot.nodes.count <= XiangqiCoreDocumentSnapshot.maximumNodes
    else {
      throw XiangqiCoreDocumentError.field("variationTree.nodes")
    }
    var depths = Array(repeating: 0, count: snapshot.nodes.count)
    var expectedChildren = Array(repeating: [UInt32](), count: snapshot.nodes.count)
    var childMoves = Array(
      repeating: Set<XiangqiCoreVariationMove>(), count: snapshot.nodes.count)
    var totalAnnotationBytes = 0
    for (index, node) in snapshot.nodes.enumerated() {
      let expectedID = UInt32(index)
      guard node.nodeID == expectedID,
        node.annotation.utf8.count <= XiangqiCoreDocumentSnapshot.maximumAnnotationBytesPerNode,
        node.childNodeIDs.count <= 256,
        Set(node.childNodeIDs).count == node.childNodeIDs.count
      else {
        throw XiangqiCoreDocumentError.field("variationTree.nodes[\(index)]")
      }
      let (nextAnnotationBytes, annotationOverflow) = totalAnnotationBytes.addingReportingOverflow(
        node.annotation.utf8.count)
      guard !annotationOverflow,
        nextAnnotationBytes <= XiangqiCoreDocumentSnapshot.maximumTotalAnnotationBytes
      else {
        throw XiangqiCoreDocumentError.field("annotations")
      }
      totalAnnotationBytes = nextAnnotationBytes
      if index == 0 {
        guard node.parentNodeID == nil, node.move == nil, node.nodeID == 0 else {
          throw XiangqiCoreDocumentError.field("variationTree.nodes[0]")
        }
      } else {
        guard let parent = node.parentNodeID,
          Int(parent) < index,
          let move = node.move
        else {
          throw XiangqiCoreDocumentError.field("variationTree.nodes[\(index)].parent")
        }
        let depth = depths[Int(parent)] + 1
        guard depth <= XiangqiCoreDocumentSnapshot.maximumDepth else {
          throw XiangqiCoreDocumentError.field("variationTree.nodes[\(index)].depth")
        }
        depths[index] = depth
        let parentIndex = Int(parent)
        expectedChildren[parentIndex].append(node.nodeID)
        guard expectedChildren[parentIndex].count <= 256,
          childMoves[parentIndex].insert(move).inserted
        else {
          throw XiangqiCoreDocumentError.field("variationTree.nodes[\(parent)].children")
        }
      }
    }
    for (index, node) in snapshot.nodes.enumerated() {
      guard node.childNodeIDs == expectedChildren[index],
        (node.childNodeIDs.isEmpty && node.selectedChildNodeID == nil)
          || (!node.childNodeIDs.isEmpty
            && node.selectedChildNodeID.map({ node.childNodeIDs.contains($0) }) == true)
      else {
        throw XiangqiCoreDocumentError.field("variationTree.nodes[\(node.nodeID)].children")
      }
    }
    guard Int(snapshot.currentNodeID) < snapshot.nodes.count else {
      throw XiangqiCoreDocumentError.field("currentNode")
    }
  }
}

/// A scoped owner for one unpublished Rust document-restore transaction. It is
/// intentionally value-local to the CoreBinary boundary: DocumentKit never sees
/// or manipulates this token, and every error path destroys the candidate before
/// a live `XiangqiCoreGame` can be installed.
private struct XiangqiCoreDocumentRestoreSession {
  private var handle: xq_document_restore_handle_t = 0

  init(initialFEN: String) throws {
    try XiangqiCoreGame.requireCompatibleABI()
    let bytes = try XiangqiCoreGame.boundedUTF8(
      initialFEN,
      tooLong: .fenFailure(
        status: GeneratedFFIABI.statusInputTooLarge,
        field: .inputBytes
      )
    )
    var result = xq_fen_result_v1_t()
    let status = bytes.withUnsafeBufferPointer { buffer in
      xq_document_restore_create_from_fen_diagnostic(
        buffer.baseAddress,
        UInt64(buffer.count),
        &handle,
        &result
      )
    }
    let field = try XiangqiCoreGame.validateFENDiagnostic(status: status, result: result)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.fenFailure(status: status, field: field)
    }
    guard handle != 0 else {
      throw XiangqiCoreError.malformedFENDiagnostic
    }
  }

  mutating func append(node: UInt32, parent: UInt32, move: XiangqiCoreVariationMove) throws {
    let status = xq_document_restore_append_node(
      try liveHandle(),
      node,
      parent,
      xq_move_v1_t(from: move.from, to: move.to, reserved: 0)
    )
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
  }

  mutating func setAnnotation(node: UInt32, text: String) throws {
    let bytes = try XiangqiCoreGame.boundedUTF8(
      text,
      tooLong: .ffiStatus(GeneratedFFIABI.statusInputTooLarge)
    )
    let live = try liveHandle()
    let status = bytes.withUnsafeBufferPointer { buffer in
      xq_document_restore_set_annotation(
        live,
        node,
        buffer.baseAddress,
        UInt64(buffer.count)
      )
    }
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
  }

  mutating func navigate(to node: UInt32) throws {
    let status = xq_document_restore_navigate(try liveHandle(), node)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
  }

  mutating func selectChild(parent: UInt32, child: UInt32) throws {
    let status = xq_document_restore_select_child(try liveHandle(), parent, child)
    guard status == GeneratedFFIABI.statusOk else {
      throw XiangqiCoreError.ffiStatus(status)
    }
  }

  mutating func finish() throws -> xq_game_handle_t {
    var game: xq_game_handle_t = 0
    let status = xq_document_restore_finish(&handle, &game)
    guard status == GeneratedFFIABI.statusOk else {
      if game != 0 {
        _ = xq_game_destroy(&game)
      }
      throw XiangqiCoreError.ffiStatus(status)
    }
    guard handle == 0, game != 0 else {
      if game != 0 {
        _ = xq_game_destroy(&game)
      }
      throw XiangqiCoreError.malformedFENDiagnostic
    }
    return game
  }

  mutating func destroy() {
    guard handle != 0 else {
      return
    }
    _ = xq_document_restore_destroy(&handle)
  }

  private func liveHandle() throws -> xq_document_restore_handle_t {
    guard handle != 0 else {
      throw XiangqiCoreError.closed
    }
    return handle
  }
}
