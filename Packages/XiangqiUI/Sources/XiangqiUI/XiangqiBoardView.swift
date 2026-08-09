import AppKit

@MainActor
public protocol XiangqiBoardViewDelegate: AnyObject {
  func boardView(_ boardView: XiangqiBoardView, didRequestSquare square: UInt8)
  func boardViewDidRequestCancel(_ boardView: XiangqiBoardView)
  func boardView(
    _ boardView: XiangqiBoardView, didRequestNavigation navigation: XiangqiBoardNavigation)
}

public enum XiangqiBoardNavigation: Sendable, Equatable {
  case previous
  case next
  case first
  case last
}

/// One custom Core Graphics board view. It owns no rules state, layers, square
/// subviews, observers, timers, or per-square tasks.
@MainActor
public final class XiangqiBoardView: NSView {
  public weak var delegate: (any XiangqiBoardViewDelegate)?

  public private(set) var presentation = XiangqiBoardPresentation.empty {
    didSet {
      if oldValue.perspective != presentation.perspective {
        drawingCache = nil
      }
      invalidatePresentationChange(from: oldValue, to: presentation)
      updateAccessibilityElements()
    }
  }

  /// Input is disabled while the document has its single bounded Rust operation in
  /// flight. Drawing and accessibility remain available for recovery feedback.
  public var acceptsBoardInput = true

  public private(set) var keyboardFocusSquare: UInt8?
  private var virtualSquares: [XiangqiBoardSquareAccessibilityElement] = []
  private let accessibilityActionID = UUID()
  private var accessibilityActionsRegistered = false
  private var drawingCache: XiangqiBoardDrawingCache?

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = false
    focusRingType = .default
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("象棋棋盘，基础规则模式")
    accessibilityActionsRegistered = XiangqiBoardAccessibilityActionRegistry.register(
      self, identifier: accessibilityActionID)
    virtualSquares = (0..<90).map {
      XiangqiBoardSquareAccessibilityElement(square: UInt8($0), actionID: accessibilityActionID)
    }
    updateAccessibilityElements()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  public override var acceptsFirstResponder: Bool {
    true
  }

  deinit {
    let identifier = accessibilityActionID
    MainActor.assumeIsolated {
      XiangqiBoardAccessibilityActionRegistry.unregister(identifier: identifier)
    }
  }

  public override func layout() {
    super.layout()
    drawingCache = nil
    needsDisplay = true
    updateAccessibilityElements()
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    drawingCache = nil
    needsDisplay = true
    updateAccessibilityElements()
  }

  public override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext,
      let geometry = boardGeometry,
      !dirtyRect.isEmpty
    else {
      return
    }
    let cache = drawingCache(for: geometry)
    let clippedDirtyRect = dirtyRect.intersection(bounds)
    guard !clippedDirtyRect.isNull, !clippedDirtyRect.isEmpty else {
      return
    }
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: clippedDirtyRect)
    context.setFillColor(NSColor.controlBackgroundColor.cgColor)
    context.fill(clippedDirtyRect)
    drawBoard(in: context, cache: cache)
    drawOverlays(in: context, cache: cache, dirtyRect: clippedDirtyRect)
    drawPieces(in: context, cache: cache, dirtyRect: clippedDirtyRect)
    drawCoordinateLabels(cache: cache, dirtyRect: clippedDirtyRect)
  }

  public override func mouseDown(with event: NSEvent) {
    guard acceptsBoardInput else {
      return
    }
    window?.makeFirstResponder(self)
    guard let geometry = boardGeometry else {
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    guard let square = geometry.canonicalSquare(at: point) else {
      return
    }
    setKeyboardFocusSquare(square)
    delegate?.boardView(self, didRequestSquare: square)
  }

  public override func keyDown(with event: NSEvent) {
    guard acceptsBoardInput else {
      return
    }
    let command = event.modifierFlags.contains(.command)
    let gridNavigation = event.modifierFlags.contains(.option)
    switch event.keyCode {
    case 53:  // Escape
      delegate?.boardViewDidRequestCancel(self)
    case 123:  // left arrow
      if command {
        delegate?.boardView(self, didRequestNavigation: .first)
      } else if gridNavigation {
        moveKeyboardFocus(displayFileDelta: -1, displayRankDelta: 0)
      } else {
        delegate?.boardView(self, didRequestNavigation: .previous)
      }
    case 124:  // right arrow
      if command {
        delegate?.boardView(self, didRequestNavigation: .last)
      } else if gridNavigation {
        moveKeyboardFocus(displayFileDelta: 1, displayRankDelta: 0)
      } else {
        delegate?.boardView(self, didRequestNavigation: .next)
      }
    case 125:  // down arrow
      moveKeyboardFocus(displayFileDelta: 0, displayRankDelta: -1)
    case 126:  // up arrow
      moveKeyboardFocus(displayFileDelta: 0, displayRankDelta: 1)
    case 36, 49:  // Return and Space
      if let keyboardFocusSquare {
        delegate?.boardView(self, didRequestSquare: keyboardFocusSquare)
      }
    default:
      super.keyDown(with: event)
      return
    }
    updateAccessibilityElements()
  }

  public func setPresentation(_ presentation: XiangqiBoardPresentation) {
    self.presentation = presentation
  }

  public func virtualAccessibilityElements() -> [NSAccessibilityElement] {
    virtualSquares
  }

  static var accessibilityRegistryCountForTesting: Int {
    XiangqiBoardAccessibilityActionRegistry.liveRegistrationCount
  }

  public override func accessibilityChildren() -> [Any]? {
    virtualSquares
  }

  private var boardGeometry: XiangqiBoardGeometry? {
    XiangqiBoardGeometry(
      bounds: bounds,
      backingScaleFactor: max(
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1),
      perspective: presentation.perspective
    )
  }

  private func moveKeyboardFocus(displayFileDelta: Int, displayRankDelta: Int) {
    let current = keyboardFocusSquare ?? presentation.selectedSquare ?? 0
    guard let coordinates = XiangqiBoardGeometry.coordinates(for: current) else {
      return
    }
    let canonicalMultiplier = presentation.perspective == .redAtBottom ? 1 : -1
    let fileDelta = displayFileDelta * canonicalMultiplier
    let rankDelta = displayRankDelta * canonicalMultiplier
    let file = min(max(coordinates.file + fileDelta, 0), XiangqiBoardGeometry.files - 1)
    let rank = min(max(coordinates.rank + rankDelta, 0), XiangqiBoardGeometry.ranks - 1)
    setKeyboardFocusSquare(UInt8(rank * XiangqiBoardGeometry.files + file))
  }

  private func setKeyboardFocusSquare(_ next: UInt8?) {
    let previous = keyboardFocusSquare
    guard previous != next else {
      return
    }
    keyboardFocusSquare = next
    guard let geometry = boardGeometry else {
      needsDisplay = true
      updateAccessibilityElements()
      return
    }
    let changed = [previous, next].compactMap { $0 }
    let rect = changed.reduce(CGRect.null) { partial, square in
      guard let squareRect = geometry.invalidationRect(forCanonicalSquare: square) else {
        return partial
      }
      return partial.union(squareRect)
    }
    if rect.isNull {
      needsDisplay = true
    } else {
      setNeedsDisplay(rect)
    }
    updateAccessibilityElements()
  }

  private func invalidatePresentationChange(
    from old: XiangqiBoardPresentation,
    to new: XiangqiBoardPresentation
  ) {
    guard let rect = invalidationRectForPresentationChange(from: old, to: new) else {
      return
    }
    if rect == bounds {
      needsDisplay = true
    } else {
      setNeedsDisplay(rect)
    }
  }

  /// Computes the smallest safe invalidation region for immutable presentation
  /// changes. Keeping this separate also makes the cache/overlay contract
  /// directly testable without inferring it from AppKit's draw coalescing.
  func invalidationRectForPresentationChange(
    from old: XiangqiBoardPresentation,
    to new: XiangqiBoardPresentation
  ) -> CGRect? {
    guard old.perspective == new.perspective,
      let geometry = boardGeometry
    else {
      return bounds
    }
    var changed = Set<UInt8>()
    for index in 0..<90 where old.cells[index] != new.cells[index] {
      changed.insert(UInt8(index))
    }
    for square in [
      old.selectedSquare, new.selectedSquare, old.lastMove?.from, old.lastMove?.to,
      new.lastMove?.from, new.lastMove?.to,
    ].compactMap({ $0 }) {
      changed.insert(square)
    }
    changed.formUnion(old.legalDestinations)
    changed.formUnion(new.legalDestinations)
    for presentation in [old, new] {
      guard let checkedSide = presentation.checkedSide else {
        continue
      }
      let general = checkedSide == .red ? UInt8(1) : UInt8(8)
      if let square = presentation.cells.firstIndex(of: general) {
        changed.insert(UInt8(square))
      }
    }
    var rect = changed.reduce(CGRect.null) { partial, square in
      guard let squareRect = geometry.invalidationRect(forCanonicalSquare: square) else {
        return partial
      }
      return partial.union(squareRect)
    }
    if old.fakeCandidates != new.fakeCandidates || old.terminal != new.terminal {
      let cache = drawingCache(for: geometry)
      if old.fakeCandidates != new.fakeCandidates {
        rect = rect.union(cache.candidatePreviewFrame)
      }
      if old.terminal != new.terminal {
        rect = rect.union(cache.terminalTextFrame)
      }
    }
    return rect.isNull ? nil : rect.intersection(bounds)
  }

  private func drawingCache(for geometry: XiangqiBoardGeometry) -> XiangqiBoardDrawingCache {
    if let drawingCache, drawingCache.geometry == geometry {
      return drawingCache
    }
    let cache = XiangqiBoardDrawingCache(geometry: geometry)
    drawingCache = cache
    return cache
  }

  private func drawBoard(in context: CGContext, cache: XiangqiBoardDrawingCache) {
    NSColor(red: 0.95, green: 0.87, blue: 0.68, alpha: 1).setFill()
    context.fill(cache.boardBackgroundRect)
    context.setStrokeColor(NSColor.labelColor.cgColor)
    context.setLineWidth(cache.boardLineWidth)
    context.addPath(cache.boardPath)
    context.strokePath()
    cache.riverText.draw(at: cache.riverTextOrigin, withAttributes: cache.riverAttributes)
  }

  private func drawOverlays(
    in context: CGContext,
    cache: XiangqiBoardDrawingCache,
    dirtyRect: CGRect
  ) {
    if let lastMove = presentation.lastMove {
      for square in [lastMove.from, lastMove.to] {
        drawSquareMarker(
          in: context,
          square: square,
          cache: cache,
          dirtyRect: dirtyRect,
          color: NSColor.systemYellow.withAlphaComponent(0.45),
          lineWidth: 3,
          symbol: nil
        )
      }
    }
    if let selected = presentation.selectedSquare {
      drawSquareMarker(
        in: context,
        square: selected,
        cache: cache,
        dirtyRect: dirtyRect,
        color: NSColor.controlAccentColor,
        lineWidth: 3,
        symbol: "选"
      )
    }
    for target in presentation.legalDestinations {
      let captured = presentation.cells[Int(target)] != 0
      drawSquareMarker(
        in: context,
        square: target,
        cache: cache,
        dirtyRect: dirtyRect,
        color: captured ? NSColor.systemOrange : NSColor.systemGreen,
        lineWidth: 2,
        symbol: captured ? "×" : "•"
      )
    }
    if let keyboardFocusSquare {
      drawSquareMarker(
        in: context,
        square: keyboardFocusSquare,
        cache: cache,
        dirtyRect: dirtyRect,
        color: NSColor.keyboardFocusIndicatorColor,
        lineWidth: 2,
        symbol: "焦"
      )
    }
    for (offset, target) in presentation.legalDestinations.sorted()
      .prefix(presentation.fakeCandidates.count).enumerated()
    {
      drawSquareMarker(
        in: context,
        square: target,
        cache: cache,
        dirtyRect: dirtyRect,
        color: NSColor.controlAccentColor,
        lineWidth: 1.5,
        symbol: "\(offset + 1)"
      )
    }
    if let checkedSide = presentation.checkedSide,
      let generalSquare = presentation.cells.indices.first(where: {
        let encoded = presentation.cells[$0]
        return encoded == (checkedSide == .red ? 1 : 8)
      })
    {
      drawSquareMarker(
        in: context,
        square: UInt8(generalSquare),
        cache: cache,
        dirtyRect: dirtyRect,
        color: NSColor.systemRed,
        lineWidth: 4,
        symbol: "将"
      )
    }
    if !presentation.fakeCandidates.isEmpty,
      cache.candidatePreviewFrame.intersects(dirtyRect)
    {
      cache.candidatePreview.draw(
        at: cache.candidatePreviewOrigin,
        withAttributes: cache.candidatePreviewAttributes
      )
    }
  }

  private func drawSquareMarker(
    in context: CGContext,
    square: UInt8,
    cache: XiangqiBoardDrawingCache,
    dirtyRect: CGRect,
    color: NSColor,
    lineWidth: CGFloat,
    symbol: String?
  ) {
    let geometry = cache.geometry
    guard let point = geometry.point(forCanonicalSquare: square),
      let markerRect = geometry.invalidationRect(forCanonicalSquare: square),
      markerRect.intersects(dirtyRect)
    else {
      return
    }
    let radius = geometry.spacing * 0.41
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(lineWidth)
    context.strokeEllipse(
      in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    guard let symbol else {
      return
    }
    var attributes = cache.markerAttributes
    attributes[.foregroundColor] = color
    let text = symbol as NSString
    let size = text.size(withAttributes: attributes)
    text.draw(
      at: CGPoint(x: point.x - size.width / 2, y: point.y + radius * 0.64),
      withAttributes: attributes)
  }

  private func drawPieces(in context: CGContext, cache: XiangqiBoardDrawingCache, dirtyRect: CGRect)
  {
    let geometry = cache.geometry
    for (index, encoded) in presentation.cells.enumerated() where encoded != 0 {
      guard let point = geometry.point(forCanonicalSquare: UInt8(index)),
        let descriptor = pieceDescriptor(encoded)
      else {
        continue
      }
      let radius = geometry.spacing * 0.37
      let pieceRect = CGRect(
        x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
      guard pieceRect.intersects(dirtyRect) else {
        continue
      }
      context.setFillColor(NSColor.windowBackgroundColor.cgColor)
      context.fillEllipse(in: pieceRect)
      context.setStrokeColor(descriptor.color.cgColor)
      context.setLineWidth(2.2)
      context.strokeEllipse(in: pieceRect)
      let attributes =
        descriptor.side == .red ? cache.redPieceAttributes : cache.blackPieceAttributes
      let text = descriptor.glyph as NSString
      let size = text.size(withAttributes: attributes)
      text.draw(
        at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2 + 1),
        withAttributes: attributes)
    }
  }

  private func drawCoordinateLabels(cache: XiangqiBoardDrawingCache, dirtyRect: CGRect) {
    for label in cache.coordinateLabels where label.frame.intersects(dirtyRect) {
      label.text.draw(at: label.origin, withAttributes: cache.coordinateAttributes)
    }
    guard cache.terminalTextFrame.intersects(dirtyRect) else {
      return
    }
    let status = presentation.terminal.accessibilityDescription as NSString
    status.draw(at: cache.terminalTextOrigin, withAttributes: cache.coordinateAttributes)
  }

  private func updateAccessibilityElements() {
    for element in virtualSquares {
      element.refresh(
        label: accessibilityDescription(for: element.square),
        frameInParentSpace: accessibilityFrameInParentSpace(for: element.square),
        parent: self
      )
    }
    setAccessibilityChildren(virtualSquares)
  }

  fileprivate func performAccessibilityPress(square: UInt8) {
    guard acceptsBoardInput, accessibilityActionsRegistered else {
      return
    }
    window?.makeFirstResponder(self)
    setKeyboardFocusSquare(square)
    delegate?.boardView(self, didRequestSquare: square)
  }

  fileprivate func accessibilityDescription(for square: UInt8) -> String {
    let canonical = canonicalCoordinate(square)
    let displayed = boardGeometry?.displayedCoordinateLabel(forCanonicalSquare: square) ?? canonical
    let piece = pieceAccessibilityDescription(presentation.cells[Int(square)])
    let selected = presentation.selectedSquare == square ? "，已选中" : ""
    let keyboardFocus = keyboardFocusSquare == square ? "，键盘焦点" : ""
    let legal: String
    if presentation.legalDestinations.contains(square) {
      legal = presentation.cells[Int(square)] == 0 ? "，可走" : "，可吃"
    } else {
      legal = ""
    }
    let check: String
    if let checkedSide = presentation.checkedSide,
      presentation.cells[Int(square)] == (checkedSide == .red ? 1 : 8)
    {
      check = "，正在被将军"
    } else {
      check = ""
    }
    return
      "显示坐标\(displayed)，规范坐标\(canonical)，\(piece)\(selected)\(keyboardFocus)\(legal)\(check)，\(presentation.terminal.accessibilityDescription)"
  }

  fileprivate func accessibilityFrameInParentSpace(for square: UInt8) -> NSRect {
    guard let point = boardGeometry?.point(forCanonicalSquare: square) else {
      return .zero
    }
    let half = max(boardGeometry?.spacing ?? 0, 1) * 0.48
    return NSRect(x: point.x - half, y: point.y - half, width: half * 2, height: half * 2)
  }

  private func canonicalCoordinate(_ square: UInt8) -> String {
    guard let coordinates = XiangqiBoardGeometry.coordinates(for: square) else {
      return "?"
    }
    let fileLabels: [Character] = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
    return "\(fileLabels[coordinates.file])\(coordinates.rank)"
  }

  private func pieceDescriptor(_ encoded: UInt8) -> (
    glyph: String, color: NSColor, side: XiangqiBoardSide
  )? {
    switch encoded {
    case 1...7:
      return (Self.redPieceGlyphs[Int(encoded - 1)], .systemRed, .red)
    case 8...14:
      return (Self.blackPieceGlyphs[Int(encoded - 8)], .labelColor, .black)
    default:
      return nil
    }
  }

  private func pieceAccessibilityDescription(_ encoded: UInt8) -> String {
    guard let descriptor = pieceDescriptor(encoded) else {
      return "空位"
    }
    let side = encoded <= 7 ? "红方" : "黑方"
    return "\(side)\(descriptor.glyph)"
  }

  private static let redPieceGlyphs = ["将", "仕", "相", "马", "车", "炮", "兵"]
  private static let blackPieceGlyphs = ["将", "士", "象", "马", "车", "炮", "卒"]
}

@MainActor
private struct XiangqiBoardDrawingCache {
  let geometry: XiangqiBoardGeometry
  let boardBackgroundRect: CGRect
  let boardLineWidth: CGFloat
  let boardPath: CGPath
  let riverText: NSString
  let riverAttributes: [NSAttributedString.Key: Any]
  let riverTextOrigin: CGPoint
  let markerAttributes: [NSAttributedString.Key: Any]
  let redPieceAttributes: [NSAttributedString.Key: Any]
  let blackPieceAttributes: [NSAttributedString.Key: Any]
  let coordinateAttributes: [NSAttributedString.Key: Any]
  let coordinateLabels: [XiangqiBoardCachedLabel]
  let terminalTextOrigin: CGPoint
  let terminalTextFrame: CGRect
  let candidatePreview: NSString
  let candidatePreviewAttributes: [NSAttributedString.Key: Any]
  let candidatePreviewOrigin: CGPoint
  let candidatePreviewFrame: CGRect

  init(geometry: XiangqiBoardGeometry) {
    self.geometry = geometry
    let grid = geometry.gridRect
    boardBackgroundRect = grid.insetBy(dx: -geometry.spacing * 0.28, dy: -geometry.spacing * 0.28)
    boardLineWidth = max(1 / geometry.backingScaleFactor, 1.1)
    boardPath = Self.makeBoardPath(geometry: geometry)

    let riverFont = NSFont.systemFont(ofSize: max(12, geometry.spacing * 0.33), weight: .medium)
    riverAttributes = [.font: riverFont, .foregroundColor: NSColor.secondaryLabelColor]
    riverText = "楚河                 汉界"
    let riverSize = riverText.size(withAttributes: riverAttributes)
    riverTextOrigin = CGPoint(
      x: grid.midX - riverSize.width / 2, y: grid.minY + geometry.spacing * 4.36)

    markerAttributes = [
      .font: NSFont.systemFont(ofSize: max(10, geometry.spacing * 0.22), weight: .bold)
    ]
    let pieceFont = NSFont.systemFont(ofSize: max(15, geometry.spacing * 0.47), weight: .semibold)
    redPieceAttributes = [.font: pieceFont, .foregroundColor: NSColor.systemRed]
    blackPieceAttributes = [.font: pieceFont, .foregroundColor: NSColor.labelColor]
    coordinateAttributes = [
      .font: NSFont.monospacedDigitSystemFont(
        ofSize: max(10, geometry.spacing * 0.21), weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    coordinateLabels = Self.makeCoordinateLabels(
      geometry: geometry, attributes: coordinateAttributes)
    terminalTextOrigin = CGPoint(x: geometry.bounds.minX + 8, y: geometry.bounds.maxY - 22)
    terminalTextFrame = CGRect(
      x: terminalTextOrigin.x,
      y: terminalTextOrigin.y,
      width: max(1, geometry.bounds.maxX - terminalTextOrigin.x - 8),
      height: 20
    )
    candidatePreview = "界面提示（非引擎）"
    candidatePreviewAttributes = [
      .font: NSFont.systemFont(ofSize: max(10, geometry.spacing * 0.21), weight: .medium),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    candidatePreviewOrigin = CGPoint(x: geometry.bounds.minX + 8, y: geometry.bounds.minY + 8)
    let candidateSize = candidatePreview.size(withAttributes: candidatePreviewAttributes)
    candidatePreviewFrame = CGRect(origin: candidatePreviewOrigin, size: candidateSize)
  }

  private static func makeBoardPath(geometry: XiangqiBoardGeometry) -> CGPath {
    let grid = geometry.gridRect
    let path = CGMutablePath()
    for rank in 0..<XiangqiBoardGeometry.ranks {
      let y = grid.minY + CGFloat(rank) * geometry.spacing
      path.move(to: CGPoint(x: grid.minX, y: y))
      path.addLine(to: CGPoint(x: grid.maxX, y: y))
    }
    for file in 0..<XiangqiBoardGeometry.files {
      let x = grid.minX + CGFloat(file) * geometry.spacing
      if file == 0 || file == XiangqiBoardGeometry.files - 1 {
        path.move(to: CGPoint(x: x, y: grid.minY))
        path.addLine(to: CGPoint(x: x, y: grid.maxY))
      } else {
        path.move(to: CGPoint(x: x, y: grid.minY))
        path.addLine(to: CGPoint(x: x, y: grid.minY + geometry.spacing * 4))
        path.move(to: CGPoint(x: x, y: grid.minY + geometry.spacing * 5))
        path.addLine(to: CGPoint(x: x, y: grid.maxY))
      }
    }
    addPalace(to: path, origin: grid.origin, spacing: geometry.spacing, top: false)
    addPalace(to: path, origin: grid.origin, spacing: geometry.spacing, top: true)
    return path
  }

  private static func addPalace(
    to path: CGMutablePath, origin: CGPoint, spacing: CGFloat, top: Bool
  ) {
    let startRank = top ? 7 : 0
    let y = origin.y + CGFloat(startRank) * spacing
    let x = origin.x + 3 * spacing
    path.move(to: CGPoint(x: x, y: y))
    path.addLine(to: CGPoint(x: x + 2 * spacing, y: y + 2 * spacing))
    path.move(to: CGPoint(x: x + 2 * spacing, y: y))
    path.addLine(to: CGPoint(x: x, y: y + 2 * spacing))
  }

  private static func makeCoordinateLabels(
    geometry: XiangqiBoardGeometry,
    attributes: [NSAttributedString.Key: Any]
  ) -> [XiangqiBoardCachedLabel] {
    var labels: [XiangqiBoardCachedLabel] = []
    labels.reserveCapacity(18)
    for square in 0..<90 {
      let canonical = UInt8(square)
      guard let point = geometry.point(forCanonicalSquare: canonical),
        let label = geometry.displayedCoordinateLabel(forCanonicalSquare: canonical),
        let coordinates = XiangqiBoardGeometry.coordinates(for: canonical),
        coordinates.rank == 0 || coordinates.file == 0
      else {
        continue
      }
      let text = label as NSString
      let size = text.size(withAttributes: attributes)
      let origin = CGPoint(x: point.x - size.width / 2, y: point.y - geometry.spacing * 0.72)
      labels.append(
        XiangqiBoardCachedLabel(
          text: text, origin: origin, frame: CGRect(origin: origin, size: size)))
    }
    return labels
  }
}

private struct XiangqiBoardCachedLabel {
  let text: NSString
  let origin: CGPoint
  let frame: CGRect
}

private final class XiangqiBoardSquareAccessibilityElement: NSAccessibilityElement {
  let square: UInt8
  private let actionID: UUID

  init(square: UInt8, actionID: UUID) {
    self.square = square
    self.actionID = actionID
    super.init()
    setAccessibilityRole(.button)
  }

  func refresh(label: String, frameInParentSpace: NSRect, parent: AnyObject) {
    setAccessibilityLabel(label)
    setAccessibilityFrameInParentSpace(frameInParentSpace)
    setAccessibilityParent(parent)
  }

  override func accessibilityPerformPress() -> Bool {
    let relay = XiangqiBoardAccessibilityPressRelay(actionID: actionID, square: square)
    if Thread.isMainThread {
      relay.performOnMainThread()
    } else {
      // Accessibility clients are allowed to call this API off-main. Hop through
      // AppKit's synchronous main-thread bridge instead of asserting actor
      // isolation on an arbitrary client thread.
      relay.performSelector(
        onMainThread: #selector(XiangqiBoardAccessibilityPressRelay.performOnMainThread),
        with: nil,
        waitUntilDone: true
      )
    }
    return relay.didPerform
  }
}

/// A short-lived Objective-C relay keeps the AppKit accessibility callback safe
/// when an assistive client enters from a non-main thread. It never retains a
/// board: the bounded registry still owns only weak references.
private final class XiangqiBoardAccessibilityPressRelay: NSObject {
  private let actionID: UUID
  private let square: UInt8
  private(set) var didPerform = false

  init(actionID: UUID, square: UInt8) {
    self.actionID = actionID
    self.square = square
  }

  @objc func performOnMainThread() {
    let identifier = actionID
    let requestedSquare = square
    didPerform = MainActor.assumeIsolated {
      XiangqiBoardAccessibilityActionRegistry.perform(
        identifier: identifier, square: requestedSquare)
    }
  }
}

@MainActor
private enum XiangqiBoardAccessibilityActionRegistry {
  private static let maximumBoards = 64
  private final class WeakBoardReference {
    weak var board: XiangqiBoardView?

    init(_ board: XiangqiBoardView) {
      self.board = board
    }
  }

  private static var boards: [UUID: WeakBoardReference] = [:]

  static func register(_ board: XiangqiBoardView, identifier: UUID) -> Bool {
    boards = boards.filter { $0.value.board != nil }
    guard boards[identifier] != nil || boards.count < maximumBoards else {
      return false
    }
    boards[identifier] = WeakBoardReference(board)
    return true
  }

  static func unregister(identifier: UUID) {
    boards.removeValue(forKey: identifier)
  }

  static var liveRegistrationCount: Int {
    boards = boards.filter { $0.value.board != nil }
    return boards.count
  }

  static func perform(identifier: UUID, square: UInt8) -> Bool {
    guard let board = boards[identifier]?.board, board.acceptsBoardInput else {
      boards.removeValue(forKey: identifier)
      return false
    }
    board.performAccessibilityPress(square: square)
    return true
  }
}
