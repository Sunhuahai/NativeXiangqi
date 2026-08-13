import AppKit
import Darwin
import Foundation
import XiangqiDocumentKit
import XiangqiUI

/// Offline T030 measurement executable. The idle sample is deliberately taken
/// after constructing and displaying the real three-pane NSDocument window, and
/// before allocating the separate offscreen board used for draw measurements.
@main
@MainActor
struct XiangqiUIBenchmarks {
  static func main() async {
    _ = NSApplication.shared
    let hardLimitMiB =
      Int(ProcessInfo.processInfo.environment["NATIVEXIANGQI_EMPTY_WINDOW_HARD_MIB"] ?? "140")
      ?? 140

    let document = NativeXiangqiDocument()
    NSDocumentController.shared.addDocument(document)
    document.makeWindowControllers()
    document.showWindows()
    guard let documentWindow = document.windowControllers.first?.window else {
      fail("could not construct the native three-pane document window")
    }
    documentWindow.displayIfNeeded()
    NSApplication.shared.updateWindows()
    do {
      try await document.waitUntilLocalSessionReady()
    } catch {
      fail("native three-pane document did not become usable: \(error.localizedDescription)")
    }
    documentWindow.displayIfNeeded()
    NSApplication.shared.updateWindows()
    guard let idleBytes = residentBytes() else {
      fail("could not measure task resident memory")
    }

    let board = XiangqiBoardView(frame: NSRect(x: 0, y: 0, width: 900, height: 1_000))
    guard
      let presentation = XiangqiBoardPresentation(
        cells: standardCells(),
        sideToMove: .red,
        checkedSide: nil,
        terminal: .ongoing,
        selectedSquare: 19,
        legalDestinations: [28, 37, 46],
        lastMove: XiangqiBoardDisplayedMove(from: 19, to: 28),
        perspective: .redAtBottom,
        engineCandidates: []
      )
    else {
      fail("could not construct bounded benchmark presentation")
    }
    board.setPresentation(presentation)
    board.layoutSubtreeIfNeeded()
    let inputDelegate = BenchmarkInputDelegate()
    board.delegate = inputDelegate
    let inputWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 1_000),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    inputWindow.contentView = board
    inputWindow.displayIfNeeded()
    let drawingContext = makeDrawingContext()
    let drawSamples = tryMeasure(count: 120) {
      draw(board, in: drawingContext)
    }
    guard
      let geometry = XiangqiBoardGeometry(
        bounds: board.bounds,
        backingScaleFactor: 2,
        perspective: .redAtBottom
      )
    else {
      fail("could not construct benchmark geometry")
    }
    let inputBatchSize = 256
    var inputCounter = 0
    let inputSamples = tryMeasure(count: 160) {
      for _ in 0..<inputBatchSize {
        let square = UInt8(inputCounter % 90)
        inputCounter += 1
        guard
          let event = mouseDownEvent(
            board: board,
            window: inputWindow,
            geometry: geometry,
            square: square,
            eventNumber: inputCounter
          )
        else {
          fail("could not construct bounded pointer input event")
        }
        board.mouseDown(with: event)
      }
    }.map { $0 / UInt64(inputBatchSize) }
    guard inputDelegate.requestedSquareCount == 160 * inputBatchSize else {
      fail("pointer input did not reach the board delegate")
    }

    let report = BenchmarkReport(
      schemaVersion: 1,
      mode: "native-three-pane-document-window-no-engine",
      idleRSSBytes: idleBytes,
      idleRSSMiB: Double(idleBytes) / 1_048_576,
      emptyWindowHardMiB: hardLimitMiB,
      drawNanoseconds: summary(drawSamples),
      inputNanoseconds: summary(inputSamples),
      logicalCPUs: ProcessInfo.processInfo.processorCount,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      hostModel: ProcessInfo.processInfo.environment["NATIVEXIANGQI_HOST_MODEL"] ?? "unknown",
      gitCommit: ProcessInfo.processInfo.environment["NATIVEXIANGQI_GIT_COMMIT"] ?? "unknown"
    )
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(report)
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data([10]))
    } catch {
      fail("could not encode UI benchmark report")
    }
    guard report.idleRSSMiB <= Double(hardLimitMiB) else {
      fail("empty-window RSS hard limit exceeded")
    }
    withExtendedLifetime(document) {}
    withExtendedLifetime(documentWindow) {}
    withExtendedLifetime(inputWindow) {}
    withExtendedLifetime(board) {}
  }

  private static func standardCells() -> [UInt8] {
    var cells = Array(repeating: UInt8(0), count: 90)
    let blackBack: [UInt8] = [12, 11, 10, 9, 8, 9, 10, 11, 12]
    let redBack: [UInt8] = [5, 4, 3, 2, 1, 2, 3, 4, 5]
    for (file, piece) in blackBack.enumerated() {
      cells[81 + file] = piece
    }
    for (file, piece) in redBack.enumerated() {
      cells[file] = piece
    }
    cells[64] = 13
    cells[70] = 13
    cells[19] = 6
    cells[25] = 6
    for file in stride(from: 0, through: 8, by: 2) {
      cells[27 + file] = 7
      cells[54 + file] = 14
    }
    return cells
  }

  private static func makeDrawingContext() -> NSGraphicsContext {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1_800,
        pixelsHigh: 2_000,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
      fail("could not create bounded offscreen drawing context")
    }
    return context
  }

  private static func draw(_ board: XiangqiBoardView, in context: NSGraphicsContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    board.draw(board.bounds)
    NSGraphicsContext.restoreGraphicsState()
  }

  private static func mouseDownEvent(
    board: XiangqiBoardView,
    window: NSWindow,
    geometry: XiangqiBoardGeometry,
    square: UInt8,
    eventNumber: Int
  ) -> NSEvent? {
    guard let point = geometry.point(forCanonicalSquare: square),
      geometry.canonicalSquare(at: point) == square
    else {
      return nil
    }
    return NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: board.convert(point, to: nil),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 1
    )
  }

  private static func tryMeasure(count: Int, work: () -> Void) -> [UInt64] {
    var values: [UInt64] = []
    values.reserveCapacity(count)
    for _ in 0..<count {
      let start = DispatchTime.now().uptimeNanoseconds
      work()
      values.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    return values
  }

  private static func summary(_ samples: [UInt64]) -> LatencySummary {
    let ordered = samples.sorted()
    guard !ordered.isEmpty else {
      return LatencySummary(p50: 0, p95: 0)
    }
    let p50Index = (ordered.count - 1) / 2
    let p95Index = min(ordered.count - 1, Int((Double(ordered.count - 1) * 0.95).rounded(.up)))
    return LatencySummary(p50: ordered[p50Index], p95: ordered[p95Index])
  }

  private static func residentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return nil
    }
    return UInt64(info.resident_size)
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("UI benchmark failed: \(message)\n".utf8))
    exit(1)
  }
}

private struct LatencySummary: Encodable {
  let p50: UInt64
  let p95: UInt64
}

@MainActor
private final class BenchmarkInputDelegate: XiangqiBoardViewDelegate {
  private(set) var requestedSquareCount = 0

  func boardView(_ boardView: XiangqiBoardView, didRequestSquare square: UInt8) {
    requestedSquareCount += 1
  }

  func boardViewDidRequestCancel(_ boardView: XiangqiBoardView) {}

  func boardView(
    _ boardView: XiangqiBoardView, didRequestNavigation navigation: XiangqiBoardNavigation
  ) {}
}

private struct BenchmarkReport: Encodable {
  let schemaVersion: Int
  let mode: String
  let idleRSSBytes: UInt64
  let idleRSSMiB: Double
  let emptyWindowHardMiB: Int
  let drawNanoseconds: LatencySummary
  let inputNanoseconds: LatencySummary
  let logicalCPUs: Int
  let physicalMemoryBytes: UInt64
  let operatingSystem: String
  let hostModel: String
  let gitCommit: String
}
