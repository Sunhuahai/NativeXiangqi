//! Offline engine/cache benchmark for `make benchmark-engine`.
//!
//! Modes (all noninteractive, machine-readable JSON lines on stdout):
//!   --presets   real-helper search per preset (elapsed/nodes)
//!   --stress    100 cancel + 100 final + 500 lifecycle switches
//!   --long-run  continuous analysis for 30 minutes with helper RSS slope
//!
//! The helper path and NNUE directory come from the command line; the script
//! `benchmark-engine.sh` supplies the verified artifact paths and asserts the
//! release gates (RSS caps, helper reclaim, no zombies).

import Darwin
import Foundation
import PikafishKit

private let artifactsPath = CommandLine.arguments.dropFirst().first ?? ""

private func helperURL() -> URL? {
  let url = URL(fileURLWithPath: artifactsPath)
    .appendingPathComponent("pikafish-2026-01-02-apple-silicon")
  return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

private func networkURL() -> URL? {
  let url = URL(fileURLWithPath: artifactsPath).appendingPathComponent("pikafish.nnue")
  return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

private func makeSession() async throws -> PikafishSession? {
  guard let helper = helperURL(), networkURL() != nil else {
    return nil
  }
  let session = PikafishSession(
    configuration: PikafishConfiguration(
      executableURL: helper,
      handshakeTimeout: .seconds(15),
      readinessTimeout: .seconds(15),
      terminalWait: .seconds(3),
      exitWait: .seconds(5)
    )
  )
  try await session.start()
  return session
}

private let initialFEN =
  "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"

private func secondsSince(_ start: ContinuousClock.Instant) -> Double {
  let components = (ContinuousClock.now - start).components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private func rssBytes(of pid: Int32) -> Int64 {
  var info = proc_taskinfo()
  let size = Int32(MemoryLayout<proc_taskinfo>.size)
  let result = withUnsafeMutablePointer(to: &info) { pointer in
    proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, size)
  }
  guard result == size else {
    return -1
  }
  return Int64(info.pti_resident_size)
}

private func runPresets() async throws {
  guard let session = try await makeSession() else {
    print("{\"benchmark\": \"presets\", \"skipped\": true, \"reason\": \"artifacts missing\"}")
    return
  }
  defer {
    Task { await session.shutdown() }
  }
  for preset in PikafishResourcePreset.allCases {
    try await session.applyPreset(
      preset,
      totalPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount)
    _ = try await session.configureCandidates(desired: 3)
    try await session.newGame()
    try await session.position(fen: initialFEN)
    var samples: [Double] = []
    var totalNodes = 0
    for _ in 0..<3 {
      let startTime = ContinuousClock.now
      let result = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(300)))
      samples.append(secondsSince(startTime))
      totalNodes += result.finalInfo?.nodes ?? 0
    }
    let median = samples.sorted()[samples.count / 2]
    print(
      "{\"benchmark\": \"presets\", \"preset\": \"\(preset.name)\", \"medianMs\": \(median), \"nodes\": \(totalNodes)}"
    )
  }
}

private func runStress() async throws {
  guard let session = try await makeSession() else {
    print("{\"benchmark\": \"stress\", \"skipped\": true, \"reason\": \"artifacts missing\"}")
    return
  }
  defer {
    Task { await session.shutdown() }
  }
  try await session.applyPreset(
    .light,
    totalPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
    activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount)
  var cancelled = 0
  var finalised = 0
  for _ in 0..<100 {
    try await session.newGame()
    try await session.position(fen: initialFEN)
    let task = Task {
      try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(10_000)))
    }
    try await Task.sleep(for: .milliseconds(5))
    await session.stopSearch()
    _ = try? await task.value
    cancelled += 1
    try await session.newGame()
    try await session.position(fen: initialFEN)
    _ = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(1)))
    finalised += 1
  }
  var switches = 0
  for _ in 0..<500 {
    try await session.newGame()
    try await session.position(fen: initialFEN, moves: switches % 2 == 0 ? ["b2b3"] : [])
    _ = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(1)))
    switches += 1
  }
  print(
    "{\"benchmark\": \"stress\", \"cancelled\": \(cancelled), \"finalised\": \(finalised), \"switches\": \(switches), \"phase\": \"\(await session.summary().phase)\"}"
  )
}

private func runLong() async throws {
  guard let session = try await makeSession() else {
    print("{\"benchmark\": \"long-run\", \"skipped\": true, \"reason\": \"artifacts missing\"}")
    return
  }
  defer {
    Task { await session.shutdown() }
  }
  try await session.applyPreset(
    .standard,
    totalPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
    activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount)
  try await session.newGame()
  try await session.position(fen: initialFEN)
  let pid = await session.processIdentifier
  let start = ContinuousClock.now
  while ContinuousClock.now - start < .seconds(1_800) {
    let rss = rssBytes(of: pid)
    print(
      "{\"benchmark\": \"long-run\", \"rssBytes\": \(rss), \"elapsedSeconds\": \(Int((ContinuousClock.now - start).components.seconds))}"
    )
    _ = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(5_000)))
    try? await Task.sleep(for: .seconds(30))
  }
}

// MARK: - Main

let mode = CommandLine.arguments.dropFirst().dropFirst().first ?? "--presets"
let startTime = ContinuousClock.now
do {
  switch mode {
  case "--presets":
    try await runPresets()
  case "--stress":
    try await runStress()
  case "--long-run":
    try await runLong()
  default:
    print("unknown mode \(mode)")
    exit(2)
  }
} catch {
  print("{\"benchmark\": \"failed\", \"error\": \"\(error.localizedDescription)\"}")
  exit(1)
}
