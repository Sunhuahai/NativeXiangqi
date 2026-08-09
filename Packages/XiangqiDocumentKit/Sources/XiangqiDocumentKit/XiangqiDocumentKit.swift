//! Native AppKit `.xqgame` document lifecycle for T040.

import AppKit
import Foundation
import XiangqiCoreBinary
import XiangqiUI
import os

private let documentLogger = Logger(subsystem: "org.nativexiangqi.app", category: "document")

public enum NativeXiangqiFENExportScope: Sendable {
  case initial
  case current
}

/// Result of asking a document to replace its live state from a saved or local
/// historical version. The AppKit command must obtain explicit user approval
/// before it passes `discardingUnsavedChanges: true`; a bare menu action can
/// never silently discard an editable record.
public enum NativeXiangqiDocumentRestoreRequest: Equatable, Sendable {
  case started
  case requiresExplicitConfirmation
  case unavailable
}

/// An immutable, locally safe historical-version menu entry. It intentionally
/// contains no `NSFileVersion` object: AppKit menu updates consume this bounded
/// value only, while the version object is re-resolved and checked for local
/// contents on the dedicated file worker immediately before restoration.
public struct NativeXiangqiLocalVersionDescriptor: Equatable, Sendable {
  public let documentURL: URL
  public let versionURL: URL
  public let title: String
}

/// Performs version-store enumeration away from the main actor. It never asks
/// the system for nonlocal versions and returns only a fixed-size immutable list.
public actor NativeXiangqiLocalVersionCatalog {
  public static let maximumEntries = 32

  public init() {}

  public func descriptors(for documentURL: URL) -> [NativeXiangqiLocalVersionDescriptor] {
    var entries: [NativeXiangqiLocalVersionDescriptor] = []
    entries.reserveCapacity(Self.maximumEntries)
    for version in NSFileVersion.otherVersionsOfItem(at: documentURL) ?? [] {
      guard version.hasLocalContents else {
        continue
      }
      entries.append(
        NativeXiangqiLocalVersionDescriptor(
          documentURL: documentURL,
          versionURL: version.url,
          title: version.localizedName ?? "本地历史版本"
        )
      )
      if entries.count == Self.maximumEntries {
        break
      }
    }
    return entries
  }
}

/// Native `.xqgame` document coordination. Rust owns the canonical position and
/// variation tree; this class owns only AppKit lifecycle, immutable persistence
/// snapshots, metadata, extensions, and disposable presentation state.
@MainActor
@objc(NativeXiangqiDocument)
public final class NativeXiangqiDocument: NSDocument {
  public static let baseRuleModeTitle = "基础规则模式"
  public nonisolated static let documentTypeName = "org.nativexiangqi.xqgame"
  public static let maximumVariationDisplayNodes = 4_096
  public static let maximumDocumentFENBytes = XiangqiCoreDocumentSnapshot.maximumFENBytes

  private nonisolated let serializationCache = NativeXiangqiDocumentSerializationCache()
  private let documentCodec = NativeXiangqiDocumentCodec()
  private let documentFileReader = NativeXiangqiDocumentFileReader()
  private var coreGame: XiangqiCoreGame?
  private var persistenceRecord: NativeXiangqiDocumentRecord?
  private var pendingInitialFEN: String?
  /// A user-entered FEN is document content, even before its first move. Keep
  /// the new untitled document dirty once Rust has accepted and installed it so
  /// the normal NSDocument close/save flow cannot silently discard it.
  private var marksInitialPositionDirty = false
  private var currentSnapshot: XiangqiCoreBoardSnapshot?
  private var selectedSquare: UInt8?
  private var legalDestinations = Set<UInt8>()
  private var lastMove: XiangqiBoardDisplayedMove?
  private var perspective: XiangqiBoardPerspective = .redAtBottom
  private var statusText = "正在准备本地棋局…"
  private var interactionTask: Task<Void, Never>?
  private var operationGeneration: UInt64 = 0
  private var operationCancellation: NativeXiangqiDocumentCancellation?
  private var isClosing = false
  private var isOperationPending = false
  private var readinessWaiter: (identifier: UUID, continuation: CheckedContinuation<Void, Error>)?
  private var readinessTimeoutTask: Task<Void, Never>?
  #if DEBUG
    private var readinessTimeoutFixtureCancelledForTesting = false
    private var persistenceByteCountOverrideForTesting: Int?
    private var shouldFailNextPostMutationSnapshotForTesting = false
  #endif
  private var variationLedger: [UInt32: XiangqiVariationDisplayEntry] = [:]
  private weak var documentWindowController: NativeXiangqiDocumentWindowController?

  private enum LocalRestoreSource: Sendable {
    case currentDocument
    case localVersion(NativeXiangqiLocalVersionDescriptor)

    var isHistorical: Bool {
      if case .localVersion = self {
        return true
      }
      return false
    }
  }

  public override class var autosavesInPlace: Bool {
    true
  }

  public override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
    typeName == Self.documentTypeName
  }

  /// The default NSDocument safe writer receives an immutable `Data` value from
  /// the mutex-protected cache above, so it can perform its normal temporary-file
  /// replacement and version bookkeeping without touching Rust or AppKit state.
  public nonisolated override func canAsynchronouslyWrite(
    to url: URL,
    ofType typeName: String,
    for saveOperation: NSDocument.SaveOperationType
  ) -> Bool {
    typeName == Self.documentTypeName
  }

  public override init() {
    super.init()
    hasUndoManager = true
    fileType = Self.documentTypeName
  }

  /// Constructs a new unsaved document that will validate the supplied FEN in a
  /// Rust candidate before any AppKit state is installed. `nil` creates the
  /// canonical standard initial position.
  public static func newDocument(initialFEN: String? = nil) -> NativeXiangqiDocument {
    let document = NativeXiangqiDocument()
    document.pendingInitialFEN = initialFEN
    document.marksInitialPositionDirty = initialFEN != nil
    return document
  }

  /// Validates an initial FEN in a disposable Rust session before an AppKit
  /// document is added or shown. The caller can therefore keep a malformed FEN
  /// on a recoverable input path rather than briefly creating an unusable dirty
  /// document window.
  public static func validateInitialFEN(_ fen: String) async throws {
    try requireDocumentFENBytes(fen)
    let candidate = try await XiangqiCoreGame.fromFEN(fen)
    do {
      try await candidate.close()
    } catch {
      // The FFI token was successfully created, so a close failure means the
      // caller cannot safely assume the candidate has been released.
      throw error
    }
  }

  private static func requireDocumentFENBytes(_ fen: String) throws {
    guard fen.utf8.count <= maximumDocumentFENBytes else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("initialFEN")
    }
  }

  public override func makeWindowControllers() {
    let controller = NativeXiangqiDocumentWindowController(document: self)
    addWindowController(controller)
    documentWindowController = controller
    renderPresentation()
    if let prepared = serializationCache.consumePendingOpen() {
      installPreparedOpen(prepared)
    } else if let initialFEN = pendingInitialFEN {
      pendingInitialFEN = nil
      beginInMemoryGameIfNeeded(initialFEN: initialFEN)
    } else {
      beginInMemoryGameIfNeeded()
    }
  }

  public override func close() {
    closeCoreSession()
    super.close()
  }

  /// Restores the current on-disk version through the bounded asynchronous
  /// candidate path. The caller must explicitly authorize discarding current
  /// presentation/document content before this starts; the source URL itself is
  /// acquired later under NSDocument's file-access serialization.
  @discardableResult
  public func restoreSavedDocument(
    discardingUnsavedChanges: Bool = false
  ) -> NativeXiangqiDocumentRestoreRequest {
    requestLocalRestore(
      source: .currentDocument,
      discardingUnsavedChanges: discardingUnsavedChanges,
      status: "正在还原已保存版本…"
    )
  }

  /// Restores an entry returned by `NativeXiangqiLocalVersionCatalog`. The
  /// descriptor is re-resolved against the current file under file coordination,
  /// and only `hasLocalContents` versions are ever read.
  @discardableResult
  public func restoreLocalVersion(
    _ descriptor: NativeXiangqiLocalVersionDescriptor,
    discardingUnsavedChanges: Bool = false
  ) -> NativeXiangqiDocumentRestoreRequest {
    requestLocalRestore(
      source: .localVersion(descriptor),
      discardingUnsavedChanges: discardingUnsavedChanges,
      status: "正在还原本地历史版本…"
    )
  }

  /// Do not claim success from AppKit's synchronous Version Browser callback and
  /// install a candidate later. The application exposes the local-version command
  /// above, which holds a document activity until its background read/replay has
  /// either atomically installed or failed without changing live state.
  public nonisolated override func revert(toContentsOf url: URL, ofType typeName: String) throws {
    _ = url
    guard typeName == Self.documentTypeName else {
      throw NativeXiangqiDocumentFormatError.field("documentType")
    }
    throw NativeXiangqiDocumentFormatError.field("localVersionRecovery")
  }

  private func requestLocalRestore(
    source: LocalRestoreSource,
    discardingUnsavedChanges: Bool,
    status: String
  ) -> NativeXiangqiDocumentRestoreRequest {
    guard !isOperationPending, !isClosing else {
      return .unavailable
    }
    guard discardingUnsavedChanges else {
      statusText = "还原会替换当前棋谱；请先明确确认丢弃当前未保存更改。"
      renderPresentation()
      return .requiresExplicitConfirmation
    }
    let token = beginOperation(status: status)
    interactionTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      do {
        try await self.restoreLocalContentsUnderFileAccess(source: source, token: token)
        if source.isHistorical {
          try await self.autosaveConfirmedHistoricalRestore(token: token)
        }
        guard token == self.operationGeneration, !self.isClosing else {
          return
        }
        self.completeOperation()
        self.renderPresentation()
      } catch {
        guard token == self.operationGeneration, self.isOperationPending, !self.isClosing else {
          return
        }
        await self.finishFailure(token: token, error: error, game: nil)
      }
    }
    return .started
  }

  /// Performs the whole candidate read/replay and final MainActor replacement
  /// under one AppKit activity + asynchronous file-access lease. Releasing that
  /// lease before installing the immutable persistence cache would allow an
  /// overlapping Save/Save As to write old bytes in between preparation and the
  /// recovery commit, so the lease ends only after the new state is installed.
  private func restoreLocalContentsUnderFileAccess(
    source: LocalRestoreSource,
    token: UInt64
  ) async throws {
    let cancellation = operationCancellation
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      performActivity(withSynchronousWaiting: false) { [weak self] activityCompletion in
        guard let self else {
          activityCompletion()
          continuation.resume(throwing: NativeXiangqiDocumentReadinessError.unavailable)
          return
        }
        self.performAsynchronousFileAccess { [weak self] fileAccessCompletion in
          Task { @MainActor [weak self] in
            var prepared: NativeXiangqiPreparedOpen?
            var candidate: XiangqiCoreGame?
            var leaseReleased = false
            func releaseLease() {
              guard !leaseReleased else {
                return
              }
              leaseReleased = true
              fileAccessCompletion()
              activityCompletion()
            }
            defer {
              if let prepared {
                XiangqiCoreGame.discardPreparedDocument(prepared.core)
              }
              releaseLease()
            }
            guard let self else {
              releaseLease()
              continuation.resume(throwing: NativeXiangqiDocumentReadinessError.unavailable)
              return
            }
            do {
              let contents: NativeXiangqiDocumentFileContents
              switch source {
              case .currentDocument:
                guard let url = self.fileURL else {
                  throw NativeXiangqiDocumentReadinessError.unavailable
                }
                contents = try await self.documentFileReader.readCurrentLocalDocument(
                  url,
                  maximumBytes: NativeXiangqiDocumentFormatLimits.maximumFileBytes,
                  cancellation: cancellation
                )
              case .localVersion(let descriptor):
                guard self.fileURL == descriptor.documentURL else {
                  throw NativeXiangqiDocumentFormatError.field("localVersionRecovery")
                }
                contents = try await self.documentFileReader.readLocalVersion(
                  documentURL: descriptor.documentURL,
                  versionURL: descriptor.versionURL,
                  maximumBytes: NativeXiangqiDocumentFormatLimits.maximumFileBytes,
                  cancellation: cancellation
                )
              }
              prepared = try await self.documentCodec.prepareOpen(
                contents.data,
                cancellation: cancellation
              )
              guard let prepared else {
                throw NativeXiangqiDocumentReadinessError.unavailable
              }
              let ledger = try self.makeVariationLedger(from: prepared.record.core)
              let game = try XiangqiCoreGame.consumePreparedDocument(prepared.core)
              candidate = game
              guard await self.continueOperation(token: token, game: game) else {
                candidate = nil
                throw NativeXiangqiDocumentFormatError.cancelled
              }
              if let previous = self.coreGame {
                do {
                  try await previous.close()
                } catch {
                  await self.quarantineAfterReplacementCloseFailure(
                    token: token,
                    liveGame: previous,
                    candidate: game,
                    error: error
                  )
                  candidate = nil
                  throw error
                }
              }
              self.coreGame = game
              candidate = nil
              self.persistenceRecord = prepared.record
              self.variationLedger = ledger
              self.serializationCache.install(data: prepared.data)
              self.install(
                snapshot: prepared.core.snapshot,
                selectedSquare: nil,
                legalDestinations: [],
                lastMove: self.moveForNode(prepared.core.snapshot.currentNode)
              )
              self.undoManager?.removeAllActions()
              switch source {
              case .currentDocument:
                self.fileModificationDate = contents.modificationDate
                self.updateChangeCount(.changeCleared)
                self.statusText = "已还原已保存棋谱。\(Self.baseRuleModeTitle)"
              case .localVersion:
                // The historical bytes are now the authoritative in-memory
                // record, but the current file still contains a newer version.
                // Keep this document dirty until normal NSDocument autosave
                // safely replaces that file after the lease is released.
                self.updateChangeCount(.changeDone)
                self.statusText = "已载入本地历史版本，正在以标准保存流程写回…"
              }
              releaseLease()
              continuation.resume()
            } catch {
              if let candidate, self.coreGame !== candidate {
                await closeAbandonedCoreGame(candidate, context: "document recovery failure")
              }
              releaseLease()
              continuation.resume(throwing: error)
            }
          }
        }
      }
    }
  }

  /// Historical versions are deliberately installed as dirty content first.
  /// Once the recovery file-access lease has ended, use NSDocument's normal
  /// asynchronous safe writer so the current file is atomically replaced and
  /// version bookkeeping remains AppKit-owned. A write failure leaves the
  /// recovered state available and conservatively dirty for a retry.
  private func autosaveConfirmedHistoricalRestore(token: UInt64) async throws {
    guard token == operationGeneration, !isClosing else {
      throw NativeXiangqiDocumentFormatError.cancelled
    }
    let saveError: Error? = await withCheckedContinuation { continuation in
      autosave(withImplicitCancellability: false) { error in
        continuation.resume(returning: error)
      }
    }
    guard token == operationGeneration, !isClosing else {
      throw NativeXiangqiDocumentFormatError.cancelled
    }
    if let saveError {
      updateChangeCount(.changeDone)
      documentLogger.error(
        "Historical version autosave failed: \(diagnosticCode(saveError), privacy: .public)"
      )
      statusText = "本地历史版本已载入，但未能保存到当前文件；请使用“保存”重试。"
      return
    }
    statusText = "已还原并保存本地历史版本。\(Self.baseRuleModeTitle)"
  }

  /// AppKit can call this from its asynchronous write thread. It only returns the
  /// already encoded immutable snapshot; it never waits on the MainActor, Rust, UI,
  /// engine, or cache.
  public nonisolated override func data(ofType typeName: String) throws -> Data {
    guard typeName == Self.documentTypeName else {
      throw NativeXiangqiDocumentFormatError.field("documentType")
    }
    return try serializationCache.data()
  }

  /// The bounded parser and the full Rust replay execute in AppKit's documented
  /// concurrent-read path. A successful open therefore stages an already-owned
  /// game plus immutable JSON bytes; `makeWindowControllers` only transfers that
  /// prepared owner and renders it, so a malformed late variation cannot produce
  /// a window that first appears open and then becomes unavailable.
  public nonisolated override func read(from data: Data, ofType typeName: String) throws {
    guard typeName == Self.documentTypeName else {
      throw NativeXiangqiDocumentFormatError.field("documentType")
    }
    serializationCache.stagePreparedOpen(try makeNativeXiangqiPreparedOpen(data))
  }

  /// AppKit invokes this URL entry point on its documented concurrent-read path
  /// because `canConcurrentlyReadDocuments` returns true above. Check the file
  /// size under NSFileCoordinator *before* materializing Data, then use exactly
  /// the same bounded JSON/Rust preparation as the in-memory data callback.
  public nonisolated override func read(from url: URL, ofType typeName: String) throws {
    guard typeName == Self.documentTypeName else {
      throw NativeXiangqiDocumentFormatError.field("documentType")
    }
    let contents = try readNativeXiangqiDocumentFile(
      url,
      maximumBytes: NativeXiangqiDocumentFormatLimits.maximumFileBytes
    )
    serializationCache.stagePreparedOpen(
      try makeNativeXiangqiPreparedOpen(
        contents.data,
        modificationDate: contents.modificationDate
      )
    )
  }

  private func installPreparedOpen(_ prepared: NativeXiangqiPreparedOpen) {
    do {
      let ledger = try makeVariationLedger(from: prepared.record.core)
      let game = try XiangqiCoreGame.consumePreparedDocument(prepared.core)
      coreGame = game
      persistenceRecord = prepared.record
      variationLedger = ledger
      serializationCache.install(data: prepared.data)
      // AppKit's external-change detection compares the saved file's
      // modification date against this value, so a URL open must carry the
      // date over from the coordinated read rather than leaving it unknown.
      fileModificationDate = prepared.modificationDate
      install(
        snapshot: prepared.core.snapshot,
        selectedSquare: nil,
        legalDestinations: [],
        lastMove: moveForNode(prepared.core.snapshot.currentNode)
      )
      statusText = "已打开本地棋谱。\(Self.baseRuleModeTitle)"
      completeReadinessWaiter()
      renderPresentation()
    } catch {
      XiangqiCoreGame.discardPreparedDocument(prepared.core)
      currentSnapshot = nil
      selectedSquare = nil
      legalDestinations.removeAll(keepingCapacity: false)
      // A readiness waiter must never hang past a failed install; resolve it
      // with the same unavailable result the other failure paths use.
      failReadinessWaiter(NativeXiangqiDocumentReadinessError.unavailable)
      statusText = "\(recoverableDescription(error)) 棋谱未打开。"
      documentLogger.error(
        "Prepared document install failed: \(diagnosticCode(error), privacy: .public)")
      renderPresentation()
    }
  }

  public func beginInMemoryGameIfNeeded(initialFEN: String? = nil) {
    guard coreGame == nil, !isOperationPending, !isClosing else {
      return
    }
    marksInitialPositionDirty = marksInitialPositionDirty || initialFEN != nil
    let token = beginOperation(status: "正在准备本地棋局…")
    interactionTask = Task { @MainActor [weak self] in
      var createdGame: XiangqiCoreGame?
      do {
        let game: XiangqiCoreGame
        if let initialFEN {
          try Self.requireDocumentFENBytes(initialFEN)
          game = try await XiangqiCoreGame.fromFEN(initialFEN)
        } else {
          game = try await XiangqiCoreGame.createInitial()
        }
        createdGame = game
        let snapshot = try await game.snapshot()
        let coreRecord = try await game.documentSnapshot()
        guard let self else {
          await closeAbandonedCoreGame(game, context: "document deallocated during initialization")
          return
        }
        let record = NativeXiangqiDocumentRecord.newDocument(core: coreRecord)
        let persistence = try await self.preparedPersistence(
          record: record,
          core: coreRecord,
          touchesModifiedDate: false
        )
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.coreGame = game
        self.installPersistence(persistence)
        self.install(snapshot: snapshot, selectedSquare: nil, legalDestinations: [], lastMove: nil)
        if self.marksInitialPositionDirty {
          self.marksInitialPositionDirty = false
          self.updateChangeCount(.changeDone)
        }
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
        try self.requireCoreMutationPersistenceHeadroom()
        try await game.undo()
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        let persistence = try await self.preparedPersistence(for: game, touchesModifiedDate: false)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.installPersistence(persistence)
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        self.undoManager?.removeAllActions()
        // The cursor is persisted document content (current node and selected
        // child), so browsing history changes the record the next save would
        // write. Mark the document edited; otherwise closing a clean saved game
        // after browsing would silently drop the cursor change, the same
        // rationale as the retained-variation undo path below.
        self.updateChangeCount(.changeDone)
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
        try self.requireCoreMutationPersistenceHeadroom()
        try await game.redo()
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        let persistence = try await self.preparedPersistence(for: game, touchesModifiedDate: false)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.installPersistence(persistence)
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        self.undoManager?.removeAllActions()
        self.updateChangeCount(.changeDone)
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
      variationLedger[nodeID] != nil, currentSnapshot?.currentNode != nodeID
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
        try self.requireCoreMutationPersistenceHeadroom(
          reservationBytes: NativeXiangqiDocumentPersistenceAdmission
            .reservedNavigationMutationBytes
        )
        try await game.navigate(to: nodeID)
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        let persistence = try await self.preparedPersistence(for: game, touchesModifiedDate: false)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.installPersistence(persistence)
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        self.undoManager?.removeAllActions()
        self.updateChangeCount(.changeDone)
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

  public func presentRecoverableError(_ error: Error) {
    guard !isClosing else {
      return
    }
    let code = diagnosticCode(error)
    documentLogger.error("Recoverable document error: \(code, privacy: .public)")
    statusText = "\(recoverableDescription(error)) 棋局保持不变。"
    renderPresentation()
  }

  /// Exports either the canonical root FEN stored in the document record or the
  /// Rust-authoritative cursor FEN. Export never navigates, changes selection, or
  /// affects the document change count.
  public func exportFEN(_ scope: NativeXiangqiFENExportScope) async throws -> String {
    switch scope {
    case .initial:
      guard let record = persistenceRecord else {
        throw NativeXiangqiDocumentInternalError.missingPersistenceRecord
      }
      return record.core.initialFEN
    case .current:
      guard let game = coreGame else {
        throw NativeXiangqiDocumentReadinessError.unavailable
      }
      return try await game.fen()
    }
  }

  /// Exports the selected Rust root-to-cursor UCCI path without changing the
  /// live cursor or the document's edited state.
  public func exportUCCIMainline() async throws -> String {
    guard let game = coreGame else {
      throw NativeXiangqiDocumentReadinessError.unavailable
    }
    return try await game.ucciMainline()
  }

  /// Replaces the document's initial position after the caller has obtained an
  /// explicit user confirmation. The FEN is validated by a new Rust candidate;
  /// existing branches and annotations stay intact until that candidate, its
  /// persistence snapshot, and its byte-bounded encoding all succeed.
  public func replaceInitialPosition(withFEN fen: String) {
    guard !isOperationPending, !isClosing, persistenceRecord != nil else {
      return
    }
    do {
      try Self.requireDocumentFENBytes(fen)
    } catch {
      statusText = "\(recoverableDescription(error)) 棋局保持不变，可继续浏览或重试。"
      renderPresentation()
      return
    }
    let token = beginOperation(status: "正在验证新的初始局面…")
    interactionTask = Task { @MainActor [weak self] in
      var candidate: XiangqiCoreGame?
      do {
        let game = try await XiangqiCoreGame.fromFEN(fen)
        candidate = game
        let snapshot = try await game.snapshot()
        let core = try await game.documentSnapshot()
        guard let self, var record = self.persistenceRecord else {
          await closeAbandonedCoreGame(game, context: "document deallocated during FEN replacement")
          return
        }
        record.result = nil
        let persistence = try await self.preparedPersistence(
          record: record,
          core: core,
          touchesModifiedDate: true
        )
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        if let previous = self.coreGame {
          do {
            try await previous.close()
          } catch {
            await self.quarantineAfterReplacementCloseFailure(
              token: token,
              liveGame: previous,
              candidate: game,
              error: error
            )
            return
          }
        }
        self.coreGame = game
        self.installPersistence(persistence)
        self.install(snapshot: snapshot, selectedSquare: nil, legalDestinations: [], lastMove: nil)
        self.undoManager?.removeAllActions()
        self.updateChangeCount(.changeDone)
        self.statusText = "已替换初始局面并重置变例。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if let self {
          await self.finishFailure(token: token, error: error, game: candidate)
        } else if let candidate {
          await closeAbandonedCoreGame(
            candidate, context: "document deallocated after FEN replacement")
        }
      }
    }
  }

  /// Replaces the full variation record with a UCCI path from the current root
  /// FEN after caller confirmation. UCCI parsing and legality execute only in a
  /// disposable Rust candidate, so a bad later ply retains the current document
  /// and reports the Rust-provided one-based ply diagnostic.
  public func replaceRecord(withUCCIMainline mainline: String) {
    guard !isOperationPending, !isClosing, let baseRecord = persistenceRecord else {
      return
    }
    let token = beginOperation(status: "正在验证 UCCI 主线…")
    interactionTask = Task { @MainActor [weak self, baseRecord] in
      var candidate: XiangqiCoreGame?
      do {
        let game = try await XiangqiCoreGame.fromFEN(baseRecord.core.initialFEN)
        candidate = game
        _ = try await game.applyUCCIMainline(mainline)
        let snapshot = try await game.snapshot()
        let core = try await game.documentSnapshot()
        guard let self else {
          await closeAbandonedCoreGame(
            game, context: "document deallocated during UCCI replacement")
          return
        }
        var record = baseRecord
        record.result = nil
        let persistence = try await self.preparedPersistence(
          record: record,
          core: core,
          touchesModifiedDate: true
        )
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        if let previous = self.coreGame {
          do {
            try await previous.close()
          } catch {
            await self.quarantineAfterReplacementCloseFailure(
              token: token,
              liveGame: previous,
              candidate: game,
              error: error
            )
            return
          }
        }
        self.coreGame = game
        self.installPersistence(persistence)
        self.install(
          snapshot: snapshot,
          selectedSquare: nil,
          legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode)
        )
        self.undoManager?.removeAllActions()
        self.updateChangeCount(.changeDone)
        self.statusText = "已导入并替换 UCCI 主线。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if let self {
          await self.finishFailure(token: token, error: error, game: candidate)
        } else if let candidate {
          await closeAbandonedCoreGame(
            candidate, context: "document deallocated after UCCI replacement")
        }
      }
    }
  }

  /// Returns the bounded Rust-owned annotation for the current variation node.
  /// This is presentation text only; it never changes the document state.
  public func currentAnnotation() async throws -> String {
    guard let game = coreGame, let nodeID = currentSnapshot?.currentNode else {
      throw NativeXiangqiDocumentReadinessError.unavailable
    }
    return try await game.annotation(node: nodeID)
  }

  /// Applies a bounded current-node comment. The new value is first committed by
  /// Rust, then captured into the immutable document snapshot before AppKit marks
  /// the document dirty or publishes it to the board/outline.
  public func setCurrentAnnotation(_ annotation: String) {
    guard let nodeID = currentSnapshot?.currentNode else {
      return
    }
    requestAnnotationChange(nodeID: nodeID, text: annotation, origin: .user)
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
    guard let game = coreGame, currentSnapshot != nil else {
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
        try self.requireCoreMutationPersistenceHeadroom()
        try await game.apply(from: from, to: to)
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        let persistence = try await self.preparedPersistence(for: game, touchesModifiedDate: true)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.installPersistence(persistence)
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

  private func requestAnnotationChange(
    nodeID: UInt32,
    text: String,
    origin: NativeXiangqiAnnotationChangeOrigin
  ) {
    guard !isOperationPending, !isClosing, let game = coreGame,
      currentSnapshot?.currentNode == nodeID
    else {
      return
    }
    let priorSelection = selectedSquare
    let priorDestinations = legalDestinations
    let priorLastMove = lastMove
    let token = beginOperation(status: "正在保存节点注释…")
    interactionTask = Task { @MainActor [weak self, game] in
      guard let self else {
        await closeAbandonedCoreGame(game, context: "document deallocated during annotation change")
        return
      }
      var didMutate = false
      do {
        let previous = try await game.annotation(node: nodeID)
        guard previous != text else {
          guard await self.continueOperation(token: token, game: game) else {
            return
          }
          self.statusText = "节点注释未改变。"
          self.completeOperation()
          self.renderPresentation()
          return
        }
        // Encode the exact prospective immutable record before mutating Rust. A
        // valid 16 MiB annotation quota can expand when JSON escapes control
        // scalars, so discovering the 64 MiB file limit only after the FFI call
        // would incorrectly quarantine a successfully changed live game.
        let persistence = try await self.preparedAnnotationPersistence(
          nodeID: nodeID,
          replacement: text
        )
        try await game.setAnnotation(node: nodeID, text: text)
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.installPersistence(persistence)
        self.install(
          snapshot: snapshot,
          selectedSquare: priorSelection,
          legalDestinations: priorDestinations,
          lastMove: priorLastMove
        )
        switch origin {
        case .user:
          self.registerUndoForAnnotation(nodeID: nodeID, previous: previous, replacement: text)
        case .undo, .redo:
          break
        }
        self.statusText = "已更新当前节点注释。"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if didMutate {
          if origin != .user {
            self.preserveUnsavedDocumentStateAfterRegisteredUndoFailure()
          }
          await self.quarantineAfterMutation(token: token, game: game, error: error)
        } else {
          if origin != .user {
            self.undoManager?.removeAllActions()
            self.preserveUnsavedDocumentStateAfterRegisteredUndoFailure()
          }
          await self.finishFailure(token: token, error: error, game: game)
        }
      }
    }
  }

  private func beginOperation(status: String) -> UInt64 {
    operationCancellation?.cancel()
    operationCancellation = NativeXiangqiDocumentCancellation()
    operationGeneration &+= 1
    isOperationPending = true
    statusText = status
    renderPresentation()
    return operationGeneration
  }

  private func continueOperation(token: UInt64, game: XiangqiCoreGame) async -> Bool {
    guard token == operationGeneration, !isClosing, !Task.isCancelled,
      operationCancellation?.isCancelled != true
    else {
      do {
        try await game.close()
      } catch {
        documentLogger.error(
          "Rust game close after canceled operation failed: \(diagnosticCode(error), privacy: .public)"
        )
      }
      if coreGame === game {
        coreGame = nil
      }
      await closeLiveCoreForClosing(excluding: game)
      interactionTask = nil
      isOperationPending = false
      operationCancellation = nil
      failReadinessWaiter(NativeXiangqiDocumentReadinessError.unavailable)
      return false
    }
    return true
  }

  private func completeOperation() {
    interactionTask = nil
    isOperationPending = false
    operationCancellation = nil
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
    operationCancellation?.cancel()
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
      if let game, coreGame === game {
        coreGame = nil
      }
      await closeLiveCoreForClosing(excluding: game)
      interactionTask = nil
      isOperationPending = false
      operationCancellation = nil
      failReadinessWaiter(NativeXiangqiDocumentReadinessError.unavailable)
      return
    }
    interactionTask = nil
    isOperationPending = false
    operationCancellation = nil
    failReadinessWaiter(NativeXiangqiDocumentReadinessError.unavailable)
    if let game, coreGame !== game {
      do {
        try await game.close()
      } catch {
        documentLogger.error(
          "Candidate Rust game close after failure failed: \(diagnosticCode(error), privacy: .public)"
        )
      }
    }
    if isClosing || Task.isCancelled {
      return
    }
    let code = diagnosticCode(error)
    documentLogger.error("Rust core operation failed: \(code, privacy: .public)")
    statusText = "\(recoverableDescription(error)) 棋局保持不变，可继续浏览或重试。"
    renderPresentation()
  }

  private func snapshotAfterMutation(_ game: XiangqiCoreGame) async throws
    -> XiangqiCoreBoardSnapshot
  {
    #if DEBUG
      if shouldFailNextPostMutationSnapshotForTesting {
        shouldFailNextPostMutationSnapshotForTesting = false
        throw NativeXiangqiDocumentInternalError.postMutationSnapshotUnavailable
      }
    #endif
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
    operationCancellation = nil
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

  private func quarantineAfterReplacementCloseFailure(
    token: UInt64,
    liveGame: XiangqiCoreGame,
    candidate: XiangqiCoreGame,
    error: Error
  ) async {
    do {
      try await candidate.close()
    } catch {
      documentLogger.error(
        "Candidate Rust game close after replacement failure failed: \(diagnosticCode(error), privacy: .public)"
      )
    }
    do {
      try await liveGame.close()
    } catch {
      documentLogger.error(
        "Live Rust game close after replacement failure failed: \(diagnosticCode(error), privacy: .public)"
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
    operationCancellation = nil
    guard token == operationGeneration, !isClosing else {
      return
    }
    let code = diagnosticCode(error)
    documentLogger.error(
      "Old Rust game close before document replacement failed: \(code, privacy: .public)"
    )
    statusText = "无法安全替换棋谱（\(code)）；本地会话已关闭以避免状态分叉。请重新打开或新建棋局。"
    renderPresentation()
  }

  private func closeCoreSession() {
    guard !isClosing else {
      return
    }
    isClosing = true
    operationGeneration &+= 1
    operationCancellation?.cancel()
    interactionTask?.cancel()
    serializationCache.discardPendingOpen()
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
      self.operationCancellation = nil
    }
  }

  private func closeLiveCoreForClosing(excluding candidate: XiangqiCoreGame?) async {
    guard isClosing, let live = coreGame, live !== candidate else {
      return
    }
    do {
      try await live.close()
    } catch {
      documentLogger.error(
        "Rust game close after candidate cancellation failed: \(diagnosticCode(error), privacy: .public)"
      )
    }
    coreGame = nil
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
  }

  private func preparedPersistence(
    for game: XiangqiCoreGame,
    touchesModifiedDate: Bool
  ) async throws -> NativeXiangqiPreparedPersistence {
    let cancellation = operationCancellation
    try cancellation?.check()
    guard let record = persistenceRecord else {
      throw NativeXiangqiDocumentInternalError.missingPersistenceRecord
    }
    let core = try await game.documentSnapshot()
    return try await preparedPersistence(
      record: record,
      core: core,
      touchesModifiedDate: touchesModifiedDate,
      cancellation: cancellation
    )
  }

  /// Rejects a near-capacity record before any direct Rust mutation. The cache is
  /// always produced by the canonical bounded encoder, so this fixed reserved
  /// margin is an upper bound for a single non-annotation core delta.
  private func requireCoreMutationPersistenceHeadroom(
    reservationBytes: Int = NativeXiangqiDocumentPersistenceAdmission.reservedCoreMutationBytes
  ) throws {
    #if DEBUG
      let currentBytes: Int
      if let persistenceByteCountOverrideForTesting {
        currentBytes = persistenceByteCountOverrideForTesting
      } else {
        currentBytes = try serializationCache.data().count
      }
    #else
      let currentBytes = try serializationCache.data().count
    #endif
    try NativeXiangqiDocumentPersistenceAdmission.requireCoreMutationHeadroom(
      currentBytes: currentBytes,
      reservationBytes: reservationBytes
    )
  }

  /// Builds and size-checks the exact future JSON cache without treating Swift
  /// as an independent board authority: the base snapshot came from Rust and
  /// the only proposed delta is the one annotation whose FFI mutation follows.
  /// This keeps an over-limit escape expansion on the recoverable pre-mutation
  /// path rather than leaving a live Rust game changed but unserializable.
  private func preparedAnnotationPersistence(
    nodeID: UInt32,
    replacement: String
  ) async throws -> NativeXiangqiPreparedPersistence {
    guard let record = persistenceRecord else {
      throw NativeXiangqiDocumentInternalError.missingPersistenceRecord
    }
    var didReplace = false
    let nodes = record.core.nodes.map { node -> XiangqiCoreDocumentNode in
      guard node.nodeID == nodeID else {
        return node
      }
      didReplace = true
      return XiangqiCoreDocumentNode(
        nodeID: node.nodeID,
        parentNodeID: node.parentNodeID,
        move: node.move,
        childNodeIDs: node.childNodeIDs,
        selectedChildNodeID: node.selectedChildNodeID,
        annotation: replacement
      )
    }
    guard didReplace else {
      throw NativeXiangqiDocumentInternalError.persistenceNodeUnavailable
    }
    let prospective = XiangqiCoreDocumentSnapshot(
      initialFEN: record.core.initialFEN,
      profileID: record.core.profileID,
      profileVersion: record.core.profileVersion,
      currentNodeID: record.core.currentNodeID,
      nodes: nodes
    )
    return try await preparedPersistence(
      record: record,
      core: prospective,
      touchesModifiedDate: true
    )
  }

  private func preparedPersistence(
    record: NativeXiangqiDocumentRecord,
    core: XiangqiCoreDocumentSnapshot,
    touchesModifiedDate: Bool,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) async throws -> NativeXiangqiPreparedPersistence {
    let activeCancellation = cancellation ?? operationCancellation
    try activeCancellation?.check()
    var updatedRecord = record
    updatedRecord.updateCore(core, touchesModifiedDate: touchesModifiedDate)
    let ledger = try makeVariationLedger(from: core)
    let data = try await documentCodec.encode(updatedRecord, cancellation: activeCancellation)
    return NativeXiangqiPreparedPersistence(record: updatedRecord, data: data, ledger: ledger)
  }

  private func installPersistence(_ persistence: NativeXiangqiPreparedPersistence) {
    persistenceRecord = persistence.record
    variationLedger = persistence.ledger
    serializationCache.install(data: persistence.data)
  }

  private func makeVariationLedger(
    from core: XiangqiCoreDocumentSnapshot
  ) throws -> [UInt32: XiangqiVariationDisplayEntry] {
    guard core.nodes.count <= Self.maximumVariationDisplayNodes else {
      throw NativeXiangqiDocumentInternalError.displayLedgerUnavailable
    }
    var ledger: [UInt32: XiangqiVariationDisplayEntry] = [:]
    ledger.reserveCapacity(core.nodes.count)
    for node in core.nodes {
      if node.nodeID == 0 {
        guard node.parentNodeID == nil, node.move == nil else {
          throw NativeXiangqiDocumentInternalError.displayLedgerUnavailable
        }
        ledger[0] = XiangqiVariationDisplayEntry.root(childNodeIDs: node.childNodeIDs)
        continue
      }
      guard let parentNodeID = node.parentNodeID,
        let coreMove = node.move,
        let move = XiangqiBoardDisplayedMove(from: coreMove.from, to: coreMove.to)
      else {
        throw NativeXiangqiDocumentInternalError.displayLedgerUnavailable
      }
      ledger[node.nodeID] = XiangqiVariationDisplayEntry(
        nodeID: node.nodeID,
        parentNodeID: parentNodeID,
        move: move,
        childNodeIDs: node.childNodeIDs
      )
    }
    guard ledger.count == core.nodes.count else {
      throw NativeXiangqiDocumentInternalError.displayLedgerUnavailable
    }
    return ledger
  }

  private func moveForNode(_ nodeID: UInt32) -> XiangqiBoardDisplayedMove? {
    variationLedger[nodeID]?.move
  }

  /// `NSDocument` observes an UndoManager action before our asynchronous Rust
  /// inverse finishes. If that inverse fails, retain a conservative edited state
  /// rather than letting a transient `.changeUndone`/`.changeRedone` transition
  /// claim that append-only variation content has been saved or discarded.
  private func preserveUnsavedDocumentStateAfterRegisteredUndoFailure() {
    updateChangeCount(.changeDone)
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

  private func registerUndoForAnnotation(nodeID: UInt32, previous: String, replacement: String) {
    undoManager?.registerUndo(withTarget: self) { target in
      target.performRegisteredAnnotationChange(
        nodeID: nodeID,
        text: previous,
        reverseText: replacement,
        origin: .undo
      )
    }
    undoManager?.setActionName("编辑注释")
  }

  private func performRegisteredAnnotationChange(
    nodeID: UInt32,
    text: String,
    reverseText: String,
    origin: NativeXiangqiAnnotationChangeOrigin
  ) {
    guard !isOperationPending else {
      return
    }
    let nextOrigin: NativeXiangqiAnnotationChangeOrigin = origin == .undo ? .redo : .undo
    undoManager?.registerUndo(withTarget: self) { target in
      target.performRegisteredAnnotationChange(
        nodeID: nodeID,
        text: reverseText,
        reverseText: text,
        origin: nextOrigin
      )
    }
    undoManager?.setActionName(origin == .undo ? "重做注释" : "编辑注释")
    requestAnnotationChange(nodeID: nodeID, text: text, origin: origin)
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
        try self.requireCoreMutationPersistenceHeadroom()
        try await game.undo()
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        let persistence = try await self.preparedPersistence(for: game, touchesModifiedDate: false)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.installPersistence(persistence)
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        // Rust's variation arena is append-only: native Undo moves the cursor but
        // deliberately retains the newly created branch for later navigation and
        // serialization. Counteract UndoManager's automatic clean transition so
        // closing after Cmd-Z cannot silently drop that retained record content.
        self.updateChangeCount(.changeDone)
        self.statusText = "已撤销。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if didMutate {
          self.preserveUnsavedDocumentStateAfterRegisteredUndoFailure()
          await self.quarantineAfterMutation(token: token, game: game, error: error)
        } else {
          self.undoManager?.removeAllActions()
          self.preserveUnsavedDocumentStateAfterRegisteredUndoFailure()
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
        try self.requireCoreMutationPersistenceHeadroom()
        try await game.redo(childNode: childNode)
        didMutate = true
        let snapshot = try await self.snapshotAfterMutation(game)
        let persistence = try await self.preparedPersistence(for: game, touchesModifiedDate: false)
        guard await self.continueOperation(token: token, game: game) else {
          return
        }
        self.installPersistence(persistence)
        self.install(
          snapshot: snapshot, selectedSquare: nil, legalDestinations: [],
          lastMove: self.moveForNode(snapshot.currentNode))
        self.statusText = "已重做。\(Self.baseRuleModeTitle)"
        self.completeOperation()
        self.renderPresentation()
      } catch {
        if didMutate {
          self.preserveUnsavedDocumentStateAfterRegisteredUndoFailure()
          await self.quarantineAfterMutation(token: token, game: game, error: error)
        } else {
          self.undoManager?.removeAllActions()
          self.preserveUnsavedDocumentStateAfterRegisteredUndoFailure()
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
  case missingPersistenceRecord
  case persistenceNodeUnavailable
}

private struct NativeXiangqiPreparedPersistence {
  let record: NativeXiangqiDocumentRecord
  let data: Data
  let ledger: [UInt32: XiangqiVariationDisplayEntry]
}

private enum NativeXiangqiAnnotationChangeOrigin: Equatable {
  case user
  case undo
  case redo
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

  static func root(childNodeIDs: [UInt32] = []) -> XiangqiVariationDisplayEntry {
    XiangqiVariationDisplayEntry(
      nodeID: 0,
      parentNodeID: nil,
      move: nil,
      childNodeIDs: childNodeIDs
    )
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
  if let documentError = error as? NativeXiangqiDocumentFormatError {
    return documentError.diagnosticCode
  }
  if let documentError = error as? XiangqiCoreDocumentError {
    return documentError.diagnosticCode
  }
  return "core-operation"
}

/// A concise recovery message may include only protocol field names, status codes,
/// or a one-based ply number. It must never echo FEN, UCCI, annotations, paths,
/// JSON keys, or other user-controlled record text.
private func recoverableDescription(_ error: Error) -> String {
  if let coreError = error as? XiangqiCoreError {
    switch coreError {
    case .fenFailure(let status, let field):
      return "FEN 字段 \(field.diagnosticCode) 无效（状态 \(status)）。"
    case .mainlineFailure(let status, let ply):
      if let ply {
        return "UCCI 主线第 \(ply) 手无效（状态 \(status)）。"
      }
      if status == XiangqiCoreBinary.inputTooLargeStatus {
        return "UCCI 字段 inputBytes 超出 \(XiangqiCoreBinary.maximumInputBytes) 字节上限。"
      }
      return "UCCI 主线无效（状态 \(status)）。"
    default:
      break
    }
  }
  if let documentError = error as? NativeXiangqiDocumentFormatError {
    switch documentError {
    case .field(let field):
      return "棋谱字段 \(safeDocumentFieldToken(field)) 无效。"
    case .resourceLimit(let field):
      return "棋谱字段 \(safeDocumentFieldToken(field)) 超出资源上限。"
    case .malformedJSON:
      return "棋谱 JSON 无效。"
    case .cancelled:
      return "棋谱操作已取消。"
    }
  }
  if let documentError = error as? XiangqiCoreDocumentError {
    return "棋谱字段 \(safeDocumentFieldToken(documentError.field)) 未通过 Rust 验证。"
  }
  return "操作未完成（\(diagnosticCode(error))）。"
}

private func safeDocumentFieldToken(_ field: String) -> String {
  let allowed = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._[]")
  guard !field.isEmpty,
    field.utf8.count <= 128,
    field.unicodeScalars.allSatisfy({ allowed.contains($0) })
  else {
    return "document"
  }
  return field
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

// MARK: - Internal T040 integration-test hooks

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

  /// Test-only fixture injection. User-facing FEN replacement goes through the
  /// explicit confirmation command, while this helper keeps terminal-state tests
  /// independent from AppKit alert presentation.
  func replaceWithFixtureForTesting(_ fen: String) async throws {
    guard !isOperationPending, !isClosing else {
      throw TestingError.unavailableCore
    }
    let replacement = try await XiangqiCoreGame.fromFEN(fen)
    do {
      let snapshot = try await replacement.snapshot()
      let core = try await replacement.documentSnapshot()
      let persistence = try await preparedPersistence(
        record: NativeXiangqiDocumentRecord.newDocument(core: core),
        core: core,
        touchesModifiedDate: false
      )
      if let current = coreGame {
        try await current.close()
      }
      coreGame = replacement
      currentSnapshot = nil
      selectedSquare = nil
      legalDestinations.removeAll(keepingCapacity: true)
      lastMove = nil
      installPersistence(persistence)
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

  #if DEBUG
    func failNextPostMutationSnapshotForTesting() {
      shouldFailNextPostMutationSnapshotForTesting = true
    }

    func setPersistenceByteCountOverrideForTesting(_ value: Int?) {
      persistenceByteCountOverrideForTesting = value
    }
  #endif

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

  #endif
}
