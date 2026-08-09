import CoreGraphics

/// Presentation orientation only. Canonical square IDs never change when it flips.
public enum XiangqiBoardPerspective: Sendable, Equatable {
  case redAtBottom
  case blackAtBottom
}

/// Pure, pixel-aware geometry for the fixed 9×10 Xiangqi lattice.
///
/// Canonical squares use Red coordinates: `a0 == 0`, with
/// `square == rank * 9 + file`. The type contains no AppKit state and is safe to
/// exercise in unit tests without creating a window.
public struct XiangqiBoardGeometry: Sendable, Equatable {
  public static let files = 9
  public static let ranks = 10

  public let bounds: CGRect
  public let backingScaleFactor: CGFloat
  public let perspective: XiangqiBoardPerspective
  public let spacing: CGFloat
  public let gridOrigin: CGPoint

  public init?(
    bounds: CGRect,
    backingScaleFactor: CGFloat,
    perspective: XiangqiBoardPerspective
  ) {
    guard bounds.isFiniteRect,
      backingScaleFactor.isFinite,
      backingScaleFactor > 0,
      bounds.width > 0,
      bounds.height > 0
    else {
      return nil
    }

    let edgeAllowance = max(18, min(bounds.width, bounds.height) * 0.055)
    let usableWidth = bounds.width - edgeAllowance * 2
    let usableHeight = bounds.height - edgeAllowance * 2
    guard usableWidth > 0, usableHeight > 0 else {
      return nil
    }
    let unsnappedSpacing = min(
      usableWidth / CGFloat(Self.files - 1),
      usableHeight / CGFloat(Self.ranks - 1)
    )
    let snappedSpacing = Self.pixelFloor(unsnappedSpacing, scale: backingScaleFactor)
    guard snappedSpacing >= 4 else {
      return nil
    }

    let gridWidth = snappedSpacing * CGFloat(Self.files - 1)
    let gridHeight = snappedSpacing * CGFloat(Self.ranks - 1)
    self.bounds = bounds
    self.backingScaleFactor = backingScaleFactor
    self.perspective = perspective
    spacing = snappedSpacing
    gridOrigin = CGPoint(
      x: Self.pixelRound(bounds.midX - gridWidth / 2, scale: backingScaleFactor),
      y: Self.pixelRound(bounds.midY - gridHeight / 2, scale: backingScaleFactor)
    )
  }

  public var gridRect: CGRect {
    CGRect(
      x: gridOrigin.x,
      y: gridOrigin.y,
      width: spacing * CGFloat(Self.files - 1),
      height: spacing * CGFloat(Self.ranks - 1)
    )
  }

  public func point(forCanonicalSquare square: UInt8) -> CGPoint? {
    guard let coordinates = Self.coordinates(for: square) else {
      return nil
    }
    let display = displayCoordinates(file: coordinates.file, rank: coordinates.rank)
    return CGPoint(
      x: gridOrigin.x + CGFloat(display.file) * spacing,
      y: gridOrigin.y + CGFloat(display.rank) * spacing
    )
  }

  public func canonicalSquare(at point: CGPoint, tolerance: CGFloat? = nil) -> UInt8? {
    guard point.x.isFinite, point.y.isFinite else {
      return nil
    }
    let allowedTolerance = min(max(tolerance ?? spacing * 0.43, 0), spacing * 0.49)
    let displayFile = Int(((point.x - gridOrigin.x) / spacing).rounded())
    let displayRank = Int(((point.y - gridOrigin.y) / spacing).rounded())
    guard (0..<Self.files).contains(displayFile), (0..<Self.ranks).contains(displayRank) else {
      return nil
    }
    let center = CGPoint(
      x: gridOrigin.x + CGFloat(displayFile) * spacing,
      y: gridOrigin.y + CGFloat(displayRank) * spacing
    )
    guard abs(point.x - center.x) <= allowedTolerance,
      abs(point.y - center.y) <= allowedTolerance
    else {
      return nil
    }
    let canonical: (file: Int, rank: Int)
    switch perspective {
    case .redAtBottom:
      canonical = (displayFile, displayRank)
    case .blackAtBottom:
      canonical = (Self.files - 1 - displayFile, Self.ranks - 1 - displayRank)
    }
    return UInt8(canonical.rank * Self.files + canonical.file)
  }

  /// A clipped small invalidation region around a square; this avoids redrawing a
  /// whole board for ordinary selection and move-overlay updates.
  public func invalidationRect(forCanonicalSquare square: UInt8) -> CGRect? {
    guard let point = point(forCanonicalSquare: square) else {
      return nil
    }
    let radius = spacing * 0.62
    let rect = CGRect(
      x: point.x - radius,
      y: point.y - radius,
      width: radius * 2,
      height: radius * 2
    )
    return rect.intersection(bounds)
  }

  public func displayedCoordinateLabel(forCanonicalSquare square: UInt8) -> String? {
    guard let coordinates = Self.coordinates(for: square) else {
      return nil
    }
    let display = displayCoordinates(file: coordinates.file, rank: coordinates.rank)
    let fileLabels: [Character] = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
    return "\(fileLabels[display.file])\(display.rank)"
  }

  public static func coordinates(for square: UInt8) -> (file: Int, rank: Int)? {
    guard square < UInt8(Self.files * Self.ranks) else {
      return nil
    }
    return (Int(square) % Self.files, Int(square) / Self.files)
  }

  private func displayCoordinates(file: Int, rank: Int) -> (file: Int, rank: Int) {
    switch perspective {
    case .redAtBottom:
      (file, rank)
    case .blackAtBottom:
      (Self.files - 1 - file, Self.ranks - 1 - rank)
    }
  }

  private static func pixelFloor(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    (value * scale).rounded(.down) / scale
  }

  private static func pixelRound(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    (value * scale).rounded() / scale
  }
}

extension CGRect {
  fileprivate var isFiniteRect: Bool {
    origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
  }
}
