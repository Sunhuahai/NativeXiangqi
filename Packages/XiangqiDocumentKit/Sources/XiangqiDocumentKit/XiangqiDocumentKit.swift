//! Native AppKit document shell for the T030 in-memory Xiangqi experience.

import AppKit
import Foundation
import XiangqiCoreBinary
import XiangqiUI
import os

private let documentLogger = Logger(subsystem: "org.nativexiangqi.app", category: "document")
private let nativeXiangqiTemporaryAutosaveSmokeEnvelope = Data("NXQ-T030-autosave-smoke-v1".utf8)
private let nativeXiangqiTemporaryAutosaveSmokeType = "org.nativexiangqi.t030-autosave-smoke"

/// A deliberately temporary NSDocument shell.
///
/// T030 has no lossless record serialization. Save/Open are therefore fail-closed;
/// this class only owns a local in-memory Rust session. T040 replaces that boundary
/// with the versioned `.xqgame` document format.
@MainActor
public final class NativeXiangqiDocument: NSDocument {
  public static let baseRuleModeTitle = "基础规则模式"
  public static let temporaryAutosaveSmokeEnvelope = nativeXiangqiTemporaryAutosaveSmokeEnvelope
  public static let maximumVariationDisplayNodes = 4_096

  private var coreGame: XiangqiCoreGame?
  private var currentSnapshot: XiangqiCoreBoardSnapshot?
  private var selectedSquare: UInt8?
  private var legalDestinations = Set<UInt8>()
  private var lastMove: XiangqiBoardDisplayedMove?
  private var perspective: XiangqiBoardPerspective = .redAtBottom
  private var statusText = "正在准备本地棋局…"
  private var interactionTask: Task<Void, Never>?
  private var operationGeneration: UInt64 = 0
  private var isClosing = false
  private var isOperationPending = false
  private var readinessWaiter: (identifier: UUID, continuation: CheckedContinuation<Void, Error>)?
  private var readinessTimeoutTask: Task<Void, Never>?
  #if DEBUG
    private var readinessTimeoutFixtureCancelledForTesting = false
  #endif
  private var shouldFailNextPostMutationSnapshotForTesting = false
  private var variationLedger: [UInt32: XiangqiVariationDisplayEntry] = [:]
  private weak var documentWindowController: NativeXiangqiDocumentWindowController?

  public override class var autosavesInPlace: Bool {
    false
  }

  public override init() {
    super.init()
    hasUndoManager = true
  }

  public override func makeWindowControllers() {
    let controller = NativeXiangqiDocumentWindowController(document: self)
    addWindowController(controller)
    documentWindowController = controller
    renderPresentation()
    beginInMemoryGameIfNeeded()
  }

  public override func close() {
    closeCoreSession()
    super.close()
  }

  /// User saves are intentionally unavailable until T040 can preserve branches and
  /// history without loss. This method is nonisolated because AppKit may ask for
  /// data outside the main actor.
  public nonisolated override func data(ofType typeName: String) throws -> Data {
    throw NativeXiangqiTemporaryPersistenceError.unavailable
  }

  /// T030 never opens a marker, FEN, or partial record as if it were a full game.
  public nonisolated override func read(from data: Data, ofType typeName: String) throws {
    try Self.validateTemporaryAutosaveSmokeEnvelope(data)
    throw NativeXiangqiTemporaryPersistenceError.unavailable
  }

  /// A bounded wire-format smoke check for the T030 document lifecycle. It does
  /// not serialize a game and is deliberately never exposed as Save/Open data.
  /// T040 replaces it with lossless, versioned document persistence.
  public nonisolated static func validateTemporaryAutosaveSmokeEnvelope(_ data: Data) throws {
    guard data.count <= nativeXiangqiTemporaryAutosaveSmokeEnvelope.count,
      data == nativeXiangqiTemporaryAutosaveSmokeEnvelope
    else {
      throw NativeXiangqiTemporaryPersistenceError.invalidSmokeEnvelope
    }
  }

  public func beginInMemoryGameIfNeeded() {
    guard coreGame == nil, !isOperationPending, !isClosing else {
      return
    }
    let token = beginOperation(status: "正在准备本地棋局…")
    interactionTask = Task { @MainActor [weak self] in
      var createdGame: XiangqiCoreGame?
      do {
        let game = try await XiangqiCoreGame.createInitial()
        createdGame = game
        let snapshot = try await game.snapshot()
        guard let self else {
          await closeAbandonedCoreGame(game, context: "document deallocated during initialization")
          return
        }
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.coreGame = game
        self.install(snapshot: snapshot, selectedSquare: nil, legalDestinations: [], lastMove: nil)
        self.statusText =
          "轮到\(snapshot.sideToMove == .red ? "红方" : "黑方")走。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.completeReadinessWaiter()
        self.renderPresentation()
      } catch {
        if let self {
          await self.finishFailure(token: token, error: error, game: createdGame)
        } else if let createdGame {
          await closeAbandonedCoreGame(
            createdGame, context: "document deallocated after initialization failure")
        }
      }
    }
  }

  /// Wait for the bounded local Rust session to become usable. The caller installs
  /// at most one continuation and one one-shot deadline task; no loop polls the
  /// main actor. If Rust initialization is stuck, the waiter is resumed at the
  /// deadline and the in-flight operation is cancelled rather than being awaited
  /// indefinitely.
  public func waitUntilLocalSessionReady(timeout: Duration = .seconds(2)) async throws {
    if coreGame != nil, currentSnapshot != nil {
      return
    }
    guard !isClosing, isOperationPending, interactionTask != nil, readinessWaiter == nil else {
      throw NativeXiangqiDocumentReadinessError.unavailable
    }
    let identifier = UUID()
    try await withCheckedThrowingContinuation { continuation in
      readinessWaiter = (identifier, continuation)
      readinessTimeoutTask = Task { @MainActor [weak self] in
        do {
          try await ContinuousClock().sleep(for: timeout)
        } catch {
          return
        }
        guard !Task.isCancelled else {
          return
        }
        self?.timeoutReadinessWaiter(identifier: identifier)
      }
    }
    guard !isClosing, coreGame != nil, currentSnapshot != nil else {
      throw NativeXiangqiDocumentReadinessError.unavailable
    }
  }

  public func requestSquare(_ square: UInt8) {
    guard square < 90, !isOperationPending, !isClosing,
      let snapshot = currentSnapshot
    else {
      return
    }
    guard case .ongoing = snapshot.terminal else {
      statusText = "\(terminalText(snapshot.terminal))；不能再走棋。"
      renderPresentation()
      return
    }
    if let selectedSquare, legalDestinations.contains(square) {
      applyMove(from: selectedSquare, to: square)
    } else {
      requestSelection(square)
    }
  }

  public func cancelSelection() {
    guard !isOperationPending else {
      return
    }
    selectedSquare = nil
    legalDestinations.removeAll(keepingCapacity: true)
    statusText =
      currentSnapshot.map { "轮到\($0.sideToMove == .red ? "红方" : "黑方")走。\(Self.baseRuleModeTitle)" }
      ?? "本地棋局不可用。"
    renderPresentation()
  }

  /// Browse history without changing the native UndoManager stack.
  public func requestHistoryPrevious() {
    guard !isOperationPending, let game = coreGame,
      currentSnapshot?.currentNode != 0
    else {
      return
    }
    let token = beginOperation(status: "正在浏览上一步…")
    interactionTask = Task { @MainActor [weak self, game] in
      guard let self else {
        await closeAbandonedCoreGame(game, context: "document deallocated during history previous")
        return
      }
      var didMutate = false
      do {
        try await game.undo()
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        self.undoManager?.removeAllActions()
        self.statusText = "已浏览到上一步。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if didMutate {
          await self.quarantineAfterMutation(token: token, game: game, error: error)
        } else {
          await self.finishFailure(token: token, error: error, game: game)
        }
      }
    }
  }

  /// Browse the currently selected child without changing the native UndoManager stack.
  public func requestHistoryNext() {
    guard !isOperationPending, let game = coreGame,
      canNavigateNext
    else {
      return
    }
    let token = beginOperation(status: "正在浏览下一步…")
    interactionTask = Task { @MainActor [weak self, game] in
      guard let self else {
        await closeAbandonedCoreGame(game, context: "document deallocated during history next")
        return
      }
      var didMutate = false
      do {
        try await game.redo()
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        self.undoManager?.removeAllActions()
        self.statusText = "已浏览到下一步。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if didMutate {
          await self.quarantineAfterMutation(token: token, game: game, error: error)
        } else {
          await self.finishFailure(token: token, error: error, game: game)
        }
      }
    }
  }

  /// Native UndoManager entry point, used only for document-level move undo.
  public func performNativeUndo() {
    guard !isOperationPending, undoManager?.canUndo == true else {
      return
    }
    undoManager?.undo()
  }

  /// Native UndoManager entry point, used only for document-level move redo.
  public func performNativeRedo() {
    guard !isOperationPending, undoManager?.canRedo == true else {
      return
    }
    undoManager?.redo()
  }

  public func requestNavigate(to nodeID: UInt32) {
    guard !isOperationPending, let game = coreGame,
      variationLedger[nodeID] != nil
    else {
      return
    }
    let token = beginOperation(status: "正在导航变例…")
    interactionTask = Task { @MainActor [weak self, game] in
      guard let self else {
        await closeAbandonedCoreGame(game, context: "document deallocated during navigation")
        return
      }
      var didMutate = false
      do {
        try await game.navigate(to: nodeID)
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        self.undoManager?.removeAllActions()
        self.statusText = "已导航到展示变例节点。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if didMutate {
          await self.quarantineAfterMutation(token: token, game: game, error: error)
        } else {
          await self.finishFailure(token: token, error: error, game: game)
        }
      }
    }
  }

  public func requestNavigateToStart() {
    requestNavigate(to: 0)
  }

  public func requestNavigateToLastDisplayedNode() {
    guard let startNode = currentSnapshot?.currentNode else {
      return
    }
    var node = startNode
    var visited: Set<UInt32> = [node]
    while let children = variationLedger[node]?.childNodeIDs, !children.isEmpty {
      guard let child = children.last,
        variationLedger[child] != nil,
        visited.insert(child).inserted,
        visited.count <= Self.maximumVariationDisplayNodes
      else {
        // A corrupted disposable display ledger is not authoritative; leave Rust
        // untouched rather than guessing a terminal navigation target.
        return
      }
      node = child
    }
    guard node != startNode else {
      return
    }
    requestNavigate(to: node)
  }

  public func flipBoard() {
    guard !isOperationPending else {
      return
    }
    perspective = perspective == .redAtBottom ? .blackAtBottom : .redAtBottom
    statusText =
      perspective == .redAtBottom
      ? "红方在下。\(Self.baseRuleModeTitle)" : "黑方在下。\(Self.baseRuleModeTitle)"
    renderPresentation()
  }

  public var canUndoMove: Bool {
    !isOperationPending && undoManager?.canUndo == true
  }

  public var canRedoMove: Bool {
    !isOperationPending && undoManager?.canRedo == true
  }

  public var canNavigatePrevious: Bool {
    guard !isOperationPending, let currentNode = currentSnapshot?.currentNode else {
      return false
    }
    return currentNode != 0
  }

  public var canNavigateNext: Bool {
    guard !isOperationPending, let currentNode = currentSnapshot?.currentNode else {
      return false
    }
    return !(variationLedger[currentNode]?.childNodeIDs.isEmpty ?? true)
  }

  public var canSaveTemporaryDocument: Bool {
    false
  }

  var outlineRoot: XiangqiVariationDisplayEntry? {
    variationLedger[0]
  }

  func outlineEntry(for nodeID: UInt32) -> XiangqiVariationDisplayEntry? {
    variationLedger[nodeID]
  }

  var displayedCurrentNodeID: UInt32? {
    currentSnapshot?.currentNode
  }

  var boardPresentation: XiangqiBoardPresentation {
    guard let snapshot = currentSnapshot else {
      return XiangqiBoardPresentation.empty.withPerspective(perspective)
    }
    let fakeCandidates = makeFakeCandidates(
      selectedSquare: selectedSquare, destinations: legalDestinations)
    return XiangqiBoardPresentation(
      cells: snapshot.cells,
      sideToMove: boardSide(snapshot.sideToMove),
      checkedSide: snapshot.checkedSide.map(boardSide),
      terminal: boardTerminal(snapshot.terminal),
      selectedSquare: selectedSquare,
      legalDestinations: legalDestinations,
      lastMove: lastMove,
      perspective: perspective,
      fakeCandidates: fakeCandidates
    ) ?? XiangqiBoardPresentation.empty.withPerspective(perspective)
  }

  var visibleStatusText: String {
    statusText
  }

  var isInteractionActive: Bool {
    isOperationPending
  }

  func presentRecoverableError(_ error: Error) {
    guard !isClosing else {
      return
    }
    let code = diagnosticCode(error)
    documentLogger.error("Recoverable document error: \(code, privacy: .public)")
    statusText = "操作不可用（\(code)）。棋局保持不变。"
    renderPresentation()
  }

  private func requestSelection(_ square: UInt8) {
    guard let game = coreGame else {
      return
    }
    let token = beginOperation(status: "正在查询合法目标…")
    interactionTask = Task { @MainActor [weak self, game] in
      do {
        let destinations = try await game.legalDestinations(from: square)
        guard let self else {
          await closeAbandonedCoreGame(game, context: "document deallocated during selection")
          return
        }
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.selectedSquare = destinations.isEmpty ? nil : square
        self.legalDestinations = Set(destinations)
        self.statusText =
          destinations.isEmpty
          ? "该位置没有当前可走目标。\(Self.baseRuleModeTitle)"
          : "已选择\(self.coordinate(square))；显示 Rust 验证的合法目标。"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if let self {
          await self.finishFailure(token: token, error: error, game: game)
        } else {
          await closeAbandonedCoreGame(
            game, context: "document deallocated after selection failure")
        }
      }
    }
  }

  private func applyMove(from: UInt8, to: UInt8) {
    guard let game = coreGame, let beforeSnapshot = currentSnapshot else {
      return
    }
    guard canRecordDisplayedMove(parentNodeID: beforeSnapshot.currentNode, from: from, to: to)
    else {
      statusText = "变例展示达到安全上限；没有提交走棋。"
      renderPresentation()
      return
    }
    let token = beginOperation(status: "正在提交走棋…")
    interactionTask = Task { @MainActor [weak self, game] in
      guard let self else {
        await closeAbandonedCoreGame(game, context: "document deallocated during move application")
        return
      }
      var didMutate = false
      do {
        try await game.apply(from: from, to: to)
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        let recorded = self.recordDisplayedMove(
          parentNodeID: beforeSnapshot.currentNode,
          childNodeID: snapshot.currentNode,
          from: from,
          to: to
        )
        guard recorded else {
          await self.quarantineAfterMutation(
            token: token,
            game: game,
            error: NativeXiangqiDocumentInternalError.displayLedgerUnavailable
          )
          return
        }
        self.install(
          snapshot: snapshot,
          selectedSquare: nil,
          legalDestinations: [],
          lastMove: XiangqiBoardDisplayedMove(from: from, to: to)
        )
        self.statusText =
          "已走\(self.coordinate(from))→\(self.coordinate(to))。\(self.terminalText(snapshot.terminal))"
        self.registerUndoForCurrentMove()
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if didMutate {
          await self.quarantineAfterMutation(token: token, game: game, error: error)
        } else {
          await self.finishFailure(token: token, error: error, game: game)
        }
      }
    }
  }

  private func beginOperation(status: String) -> UInt64 {
    operationGeneration &+= 1
    isOperationPending = true
    statusText = status
    renderPresentation()
    return operationGeneration
  }

  private func continueOperation(token: UInt64, game: XiangqiCoreGame) async -> Bool {
    guard token == operationGeneration, !isClosing, !Task.isCancelled else {
      do {
        try await game.close()
      } catch {
        documentLogger.error(
          "Rust game close after canceled operation failed: \(diagnosticCode(error), privacy: .public)"
        )
      }
      coreGame = nil
      interactionTask = nil
      isOperationPending = false
      failReadinessWaiter(NativeXiangqiDocumentReadinessError.unavailable)
      return false
    }
    return true
  }

  private func completeOperation() {
    interactionTask = nil
    isOperationPending = false
  }

  private func completeReadinessWaiter() {
    guard let waiter = readinessWaiter else {
      return
    }
    readinessWaiter = nil
    readinessTimeoutTask?.cancel()
    readinessTimeoutTask = nil
    waiter.continuation.resume()
  }

  private func failReadinessWaiter(_ error: Error) {
    guard let waiter = readinessWaiter else {
      return
    }
    readinessWaiter = nil
    readinessTimeoutTask?.cancel()
    readinessTimeoutTask = nil
    waiter.continuation.resume(throwing: error)
  }

  private func timeoutReadinessWaiter(identifier: UUID) {
    guard readinessWaiter?.identifier == identifier else {
      return
    }
    interactionTask?.cancel()
    failReadinessWaiter(NativeXiangqiDocumentReadinessError.timedOut)
  }

  private func finishFailure(token: UInt64, error: Error, game: XiangqiCoreGame?) async {
    guard token == operationGeneration, !isClosing, !Task.isCancelled else {
      if let game {
        do {
          try await game.close()
        } catch {
          documentLogger.error(
            "Rust game close after failed canceled operation: \(diagnosticCode(error), privacy: .public)"
          )
        }
      }
      coreGame = nil
      interactionTask = nil
      isOperationPending = false
      failReadinessWaiter(NativeXiangqiDocumentReadinessError.unavailable)
      return
    }
    interactionTask = nil
    isOperationPending = false
    failReadinessWaiter(NativeXiangqiDocumentReadinessError.unavailable)
    if isClosing || Task.isCancelled {
      return
    }
    let code = diagnosticCode(error)
    documentLogger.error("Rust core operation failed: \(code, privacy: .public)")
    statusText = "操作未完成（\(code)）。棋局保持不变，可继续浏览或重试。"
    renderPresentation()
  }

  private func snapshotAfterMutation(_ game: XiangqiCoreGame) async throws
    -> XiangqiCoreBoardSnapshot
  {
    if shouldFailNextPostMutationSnapshotForTesting {
      shouldFailNextPostMutationSnapshotForTesting = false
      throw NativeXiangqiDocumentInternalError.postMutationSnapshotUnavailable
    }
    return try await game.snapshot()
  }

  private func quarantineAfterMutation(token: UInt64, game: XiangqiCoreGame, error: Error) async {
    do {
      try await game.close()
    } catch {
      documentLogger.error(
        "Rust game close during post-mutation quarantine failed: \(diagnosticCode(error), privacy: .public)"
      )
    }
    coreGame = nil
    currentSnapshot = nil
    selectedSquare = nil
    legalDestinations.removeAll(keepingCapacity: false)
    lastMove = nil
    variationLedger.removeAll(keepingCapacity: false)
    undoManager?.removeAllActions()
    interactionTask = nil
    isOperationPending = false
    failReadinessWaiter(NativeXiangqiDocumentReadinessError.unavailable)
    guard token == operationGeneration, !isClosing else {
      return
    }
    let code = diagnosticCode(error)
    documentLogger.error(
      "Post-mutation snapshot failed; core session quarantined: \(code, privacy: .public)")
    statusText = "走棋状态已改变但无法读取可信快照（\(code)）；本地会话已关闭以避免状态分叉。请新建棋局。"
    renderPresentation()
  }

  private func closeCoreSession() {
    guard !isClosing else {
      return
    }
    isClosing = true
    operationGeneration &+= 1
    interactionTask?.cancel()
    failReadinessWaiter(NativeXiangqiDocumentReadinessError.unavailable)
    guard let game = coreGame else {
      return
    }
    if isOperationPending {
      return
    }
    isOperationPending = true
    interactionTask = Task { @MainActor [weak self, game] in
      do {
        try await game.close()
      } catch {
        documentLogger.error("Rust game close failed: \(diagnosticCode(error), privacy: .public)")
      }
      guard let self else {
        return
      }
      self.coreGame = nil
      self.interactionTask = nil
      self.isOperationPending = false
    }
  }

  private func install(
    snapshot: XiangqiCoreBoardSnapshot,
    selectedSquare: UInt8?,
    legalDestinations: Set<UInt8>,
    lastMove: XiangqiBoardDisplayedMove?
  ) {
    currentSnapshot = snapshot
    self.selectedSquare = selectedSquare
    self.legalDestinations = legalDestinations
    self.lastMove = lastMove
    if variationLedger[0] == nil {
      variationLedger[0] = XiangqiVariationDisplayEntry.root()
    }
  }

  private func recordDisplayedMove(
    parentNodeID: UInt32,
    childNodeID: UInt32,
    from: UInt8,
    to: UInt8
  ) -> Bool {
    guard childNodeID != parentNodeID,
      variationLedger.count < Self.maximumVariationDisplayNodes
        || variationLedger[childNodeID] != nil,
      let move = XiangqiBoardDisplayedMove(from: from, to: to)
    else {
      return false
    }
    if variationLedger[parentNodeID] == nil {
      variationLedger[parentNodeID] =
        parentNodeID == 0
        ? XiangqiVariationDisplayEntry.root()
        : XiangqiVariationDisplayEntry.placeholder(nodeID: parentNodeID)
    }
    variationLedger[childNodeID] = XiangqiVariationDisplayEntry(
      nodeID: childNodeID,
      parentNodeID: parentNodeID,
      move: move,
      childNodeIDs: variationLedger[childNodeID]?.childNodeIDs ?? []
    )
    guard let parent = variationLedger[parentNodeID] else {
      return false
    }
    if !parent.childNodeIDs.contains(childNodeID) {
      parent.childNodeIDs.append(childNodeID)
    }
    return true
  }

  private func canRecordDisplayedMove(parentNodeID: UInt32, from: UInt8, to: UInt8) -> Bool {
    guard variationLedger.count >= Self.maximumVariationDisplayNodes else {
      return true
    }
    guard let requestedMove = XiangqiBoardDisplayedMove(from: from, to: to),
      let childIDs = variationLedger[parentNodeID]?.childNodeIDs
    else {
      return false
    }
    return childIDs.contains { variationLedger[$0]?.move == requestedMove }
  }

  private func moveForNode(_ nodeID: UInt32) -> XiangqiBoardDisplayedMove? {
    variationLedger[nodeID]?.move
  }

  private func registerUndoForCurrentMove() {
    guard let nodeID = currentSnapshot?.currentNode, nodeID != 0 else {
      return
    }
    undoManager?.registerUndo(withTarget: self) { target in
      target.performRegisteredUndo(redoNodeID: nodeID)
    }
    undoManager?.setActionName("走棋")
  }

  private func performRegisteredUndo(redoNodeID: UInt32) {
    guard !isOperationPending else {
      return
    }
    // Register while UndoManager is actively undoing so it places the inverse on
    // its redo stack before the asynchronous Rust hop begins.
    undoManager?.registerUndo(withTarget: self) { target in
      target.performRegisteredRedo(childNodeID: redoNodeID)
    }
    undoManager?.setActionName("重做")
    requestNativeUndoOperation()
  }

  private func performRegisteredRedo(childNodeID: UInt32) {
    guard !isOperationPending else {
      return
    }
    undoManager?.registerUndo(withTarget: self) { target in
      target.performRegisteredUndo(redoNodeID: childNodeID)
    }
    undoManager?.setActionName("走棋")
    requestNativeRedoOperation(childNode: childNodeID)
  }

  private func requestNativeUndoOperation() {
    guard !isOperationPending, let game = coreGame else {
      return
    }
    let token = beginOperation(status: "正在撤销…")
    interactionTask = Task { @MainActor [weak self, game] in
      guard let self else {
        await closeAbandonedCoreGame(game, context: "document deallocated during native undo")
        return
      }
      var didMutate = false
      do {
        try await game.undo()
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        self.statusText = "已撤销。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if didMutate {
          await self.quarantineAfterMutation(token: token, game: game, error: error)
        } else {
          self.undoManager?.removeAllActions()
          await self.finishFailure(token: token, error: error, game: game)
        }
      }
    }
  }

  private func requestNativeRedoOperation(childNode: UInt32) {
    guard !isOperationPending, let game = coreGame else {
      return
    }
    let token = beginOperation(status: "正在重做…")
    interactionTask = Task { @MainActor [weak self, game] in
      guard let self else {
        await closeAbandonedCoreGame(game, context: "document deallocated during native redo")
        return
      }
      var didMutate = false
      do {
        try await game.redo(childNode: childNode)
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        self.statusText = "已重做。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if didMutate {
          await self.quarantineAfterMutation(token: token, game: game, error: error)
        } else {
          self.undoManager?.removeAllActions()
          await self.finishFailure(token: token, error: error, game: game)
        }
      }
    }
  }

  private func renderPresentation() {
    documentWindowController?.render(
      boardPresentation: boardPresentation,
      statusText: statusText,
      outlineRoot: outlineRoot,
      currentNodeID: displayedCurrentNodeID,
      isInteractionActive: isOperationPending
    )
  }

  private func makeFakeCandidates(
    selectedSquare: UInt8?,
    destinations: Set<UInt8>
  ) -> [XiangqiBoardCandidate] {
    guard let selectedSquare else {
      return []
    }
    return destinations.sorted().prefix(XiangqiBoardPresentation.maximumCandidates).map {
      destination in
      XiangqiBoardCandidate(
        title: "界面提示 \(coordinate(selectedSquare))→\(coordinate(destination))",
        detail: "Rust 已验证的合法目标；这不是引擎分析。"
      )
    }
  }

  private func coordinate(_ square: UInt8) -> String {
    guard let coordinates = XiangqiBoardGeometry.coordinates(for: square) else {
      return "?"
    }
    let labels: [Character] = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
    return "\(labels[coordinates.file])\(coordinates.rank)"
  }

  private func boardSide(_ side: XiangqiCoreSide) -> XiangqiBoardSide {
    side == .red ? .red : .black
  }

  private func boardTerminal(_ terminal: XiangqiCoreTerminal) -> XiangqiBoardTerminal {
    switch terminal {
    case .ongoing:
      .ongoing
    case .checkmate(let winner):
      .checkmate(winner: boardSide(winner))
    case .stalemate(let winner):
      .stalemate(winner: boardSide(winner))
    }
  }

  private func terminalText(_ terminal: XiangqiCoreTerminal) -> String {
    boardTerminal(terminal).accessibilityDescription
  }
}

private enum NativeXiangqiDocumentInternalError: Error {
  case postMutationSnapshotUnavailable
  case displayLedgerUnavailable
}

/// Typed readiness result for the local in-memory session. It lets benchmark and
/// test callers fail visibly rather than report a pre-initialization shell as a
/// usable document.
public enum NativeXiangqiDocumentReadinessError: Error, Equatable, LocalizedError, Sendable {
  case timedOut
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .timedOut:
      "本地棋局未在有界时间内初始化完成。"
    case .unavailable:
      "本地棋局不可用或已关闭。"
    }
  }
}

/// T030's in-memory-only persistence failure is typed and recoverable.
public enum NativeXiangqiTemporaryPersistenceError: Error, Equatable, LocalizedError, Sendable {
  case unavailable
  case invalidSmokeEnvelope

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "T030 的本地棋局尚不能安全保存；请在 T040 文档格式完成前保持会话打开。"
    case .invalidSmokeEnvelope:
      "临时 autosave smoke 数据无效，未替换当前棋局。"
    }
  }
}

/// Test-only, bounded NSDocument autosave lifecycle probe. It serializes exactly
/// one constant marker and no player/game state, so it cannot be mistaken for a
/// recoverable `.xqgame`. The real document remains fail-closed until T040 can
/// preserve the full variation tree and metadata losslessly.
@MainActor
final class NativeXiangqiTemporaryAutosaveSmokeDocument: NSDocument {
  static let typeName = nativeXiangqiTemporaryAutosaveSmokeType

  override class var autosavesInPlace: Bool {
    true
  }

  nonisolated override func data(ofType typeName: String) throws -> Data {
    guard typeName == nativeXiangqiTemporaryAutosaveSmokeType else {
      throw NativeXiangqiTemporaryPersistenceError.invalidSmokeEnvelope
    }
    return nativeXiangqiTemporaryAutosaveSmokeEnvelope
  }

  nonisolated override func read(from data: Data, ofType typeName: String) throws {
    guard typeName == nativeXiangqiTemporaryAutosaveSmokeType else {
      throw NativeXiangqiTemporaryPersistenceError.invalidSmokeEnvelope
    }
    try NativeXiangqiDocument.validateTemporaryAutosaveSmokeEnvelope(data)
  }
}

@MainActor
final class XiangqiVariationDisplayEntry: NSObject {
  let nodeID: UInt32
  let parentNodeID: UInt32?
  let move: XiangqiBoardDisplayedMove?
  var childNodeIDs: [UInt32]

  init(
    nodeID: UInt32,
    parentNodeID: UInt32?,
    move: XiangqiBoardDisplayedMove?,
    childNodeIDs: [UInt32]
  ) {
    self.nodeID = nodeID
    self.parentNodeID = parentNodeID
    self.move = move
    self.childNodeIDs = childNodeIDs
    super.init()
  }

  static func root() -> XiangqiVariationDisplayEntry {
    XiangqiVariationDisplayEntry(nodeID: 0, parentNodeID: nil, move: nil, childNodeIDs: [])
  }

  static func placeholder(nodeID: UInt32) -> XiangqiVariationDisplayEntry {
    XiangqiVariationDisplayEntry(nodeID: nodeID, parentNodeID: nil, move: nil, childNodeIDs: [])
  }

  var title: String {
    guard let move else {
      return "起始局面"
    }
    return "节点 \(nodeID)：\(coordinate(move.from)) → \(coordinate(move.to))"
  }

  private func coordinate(_ square: UInt8) -> String {
    guard let coordinates = XiangqiBoardGeometry.coordinates(for: square) else {
      return "?"
    }
    let labels: [Character] = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
    return "\(labels[coordinates.file])\(coordinates.rank)"
  }
}

private func diagnosticCode(_ error: Error) -> String {
  if let coreError = error as? XiangqiCoreError {
    return coreError.diagnosticCode
  }
  if error is NativeXiangqiTemporaryPersistenceError {
    return "temporary-persistence"
  }
  return "core-operation"
}

private func closeAbandonedCoreGame(_ game: XiangqiCoreGame, context: String) async {
  do {
    try await game.close()
  } catch {
    documentLogger.error(
      "Rust game close after \(context, privacy: .public) failed: \(diagnosticCode(error), privacy: .public)"
    )
  }
}

// MARK: - Internal T030 integration-test hooks

@MainActor
extension NativeXiangqiDocument {
  enum TestingError: Error, Equatable {
    case idleTimeout
    case unavailableCore
  }

  func waitUntilIdleForTesting() async throws {
    guard let task = interactionTask else {
      return
    }
    await task.value
    guard !isOperationPending else {
      throw TestingError.idleTimeout
    }
  }

  var snapshotForTesting: XiangqiCoreBoardSnapshot? {
    currentSnapshot
  }

  var variationNodeIDsForTesting: [UInt32] {
    variationLedger.keys.sorted()
  }

  func fenForTesting() async throws -> String {
    guard let coreGame else {
      throw TestingError.unavailableCore
    }
    return try await coreGame.fen()
  }

  /// Test-only fixture injection. There is intentionally no user-facing FEN panel
  /// or partial-record importer in T030.
  func replaceWithFixtureForTesting(_ fen: String) async throws {
    guard !isOperationPending, !isClosing else {
      throw TestingError.unavailableCore
    }
    let replacement = try await XiangqiCoreGame.fromFEN(fen)
    do {
      let snapshot = try await replacement.snapshot()
      if let current = coreGame {
        try await current.close()
      }
      coreGame = replacement
      currentSnapshot = nil
      selectedSquare = nil
      legalDestinations.removeAll(keepingCapacity: true)
      lastMove = nil
      variationLedger = [0: XiangqiVariationDisplayEntry.root()]
      undoManager?.removeAllActions()
      install(snapshot: snapshot, selectedSquare: nil, legalDestinations: [], lastMove: nil)
      statusText = "测试夹具已装载；\(Self.baseRuleModeTitle)"
      renderPresentation()
    } catch {
      do {
        try await replacement.close()
      } catch {
        documentLogger.error(
          "Fixture game close failed: \(diagnosticCode(error), privacy: .public)")
      }
      throw error
    }
  }

  func closeForTesting() async throws {
    closeCoreSession()
    try await waitUntilIdleForTesting()
  }

  func failNextPostMutationSnapshotForTesting() {
    shouldFailNextPostMutationSnapshotForTesting = true
  }

  var hasLiveCoreForTesting: Bool {
    coreGame != nil
  }

  #if DEBUG
    func beginReadinessTimeoutFixtureForTesting() {
      guard coreGame == nil, !isOperationPending, !isClosing else {
        return
      }
      _ = beginOperation(status: "正在测试初始化超时…")
      interactionTask = Task { @MainActor [weak self] in
        let cancelled: Bool
        do {
          try await ContinuousClock().sleep(for: .seconds(60))
          cancelled = false
        } catch {
          cancelled = Task.isCancelled
        }
        guard let self else {
          return
        }
        self.readinessTimeoutFixtureCancelledForTesting = cancelled
        self.interactionTask = nil
        self.isOperationPending = false
      }
    }

    var readinessTimeoutFixtureCancelledForTestingResult: Bool {
      readinessTimeoutFixtureCancelledForTesting
    }

    var hasReadinessWaiterForTesting: Bool {
      readinessWaiter != nil
    }

    var hasReadinessTimeoutTaskForTesting: Bool {
      readinessTimeoutTask != nil
    }

    func configureVariationLedgerAtCapacityForTesting() {
      var entries: [UInt32: XiangqiVariationDisplayEntry] = [:]
      let existingMove = XiangqiBoardDisplayedMove(from: 19, to: 28)
      entries[0] = XiangqiVariationDisplayEntry(
        nodeID: 0,
        parentNodeID: nil,
        move: nil,
        childNodeIDs: [1]
      )
      entries[1] = XiangqiVariationDisplayEntry(
        nodeID: 1,
        parentNodeID: 0,
        move: existingMove,
        childNodeIDs: []
      )
      for nodeID in 2..<Self.maximumVariationDisplayNodes {
        entries[UInt32(nodeID)] = XiangqiVariationDisplayEntry.placeholder(nodeID: UInt32(nodeID))
      }
      variationLedger = entries
    }

    func canRecordDisplayedMoveForTesting(parentNodeID: UInt32, from: UInt8, to: UInt8) -> Bool {
      canRecordDisplayedMove(parentNodeID: parentNodeID, from: from, to: to)
    }
  #endif
}
