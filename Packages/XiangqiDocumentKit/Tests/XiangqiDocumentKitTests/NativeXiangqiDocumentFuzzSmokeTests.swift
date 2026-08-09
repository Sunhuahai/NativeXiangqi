import Foundation
import XCTest
import XiangqiCoreBinary

@testable import XiangqiDocumentKit

final class NativeXiangqiDocumentFuzzSmokeTests: XCTestCase {
  private static let maximumGeneratedInputBytes = 1_024
  private static let generatedCaseCount = 512
  private static let deterministicSeed: UInt64 = 0x93D1_7A04_CE62_B85F

  func testFixedMigrationAndMalformedCorpusHasOnlyTypedOutcomes() async throws {
    let codec = NativeXiangqiDocumentCodec()
    let v0 = try fixture(named: "v0-linear")
    let v1 = try fixture(named: "v1-unknown-extension")

    let migrated = try await codec.decodeAndPreflight(v0)
    XCTAssertEqual(migrated.core.nodes.count, 3)
    XCTAssertEqual(migrated.core.nodes[2].annotation, "second ply")
    XCTAssertEqual(
      migrated.extensions["org.nativexiangqi.migrated-v0"],
      .object([
        "extensions": .object(["migrationFixture": .boolean(true)]),
        "unknownTopLevel": .object([
          "futureV0": .object(["retained": .string("yes")])
        ]),
      ])
    )

    let original = try await codec.decodeAndPreflight(v1)
    let roundTripped = try NativeXiangqiDocumentFormat.encode(original)
    let restored = try await codec.decodeAndPreflight(roundTripped)
    XCTAssertEqual(restored, original)
    XCTAssertEqual(
      restored.unknownTopLevel["futureTopLevel"],
      .object(["retained": .string("yes")])
    )

    for name in [
      "malformed-duplicate-key",
      "malformed-selected-child",
      "malformed-illegal-variation",
    ] {
      let data = try fixture(named: name)
      do {
        _ = try await codec.decodeAndPreflight(data)
        XCTFail("malformed corpus input \(name) unexpectedly decoded and preflighted")
      } catch {
        assertTypedDocumentFailure(error, inputName: name)
      }
    }
  }

  func testDeterministicRawBytesStayWithinBoundAndProduceTypedFailures() async throws {
    var generator = XorShift64(seed: Self.deterministicSeed)
    let codec = NativeXiangqiDocumentCodec()
    let seededInputs = [
      try fixture(named: "v0-linear"),
      try fixture(named: "v1-unknown-extension"),
      try fixture(named: "malformed-duplicate-key"),
      Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]),
      Data("[]".utf8),
    ]
    XCTAssertEqual(seededInputs.count, 5)

    for index in 0..<Self.generatedCaseCount {
      let input =
        if index < seededInputs.count {
          seededInputs[index]
        } else {
          generatedData(using: &generator)
        }
      XCTAssertLessThanOrEqual(
        input.count,
        Self.maximumGeneratedInputBytes,
        "generated input \(index) exceeded its explicit byte limit"
      )
      do {
        _ = try await codec.decodeAndPreflight(input)
      } catch {
        assertTypedDocumentFailure(error, inputName: "generated-\(index)")
      }
    }
  }

  private func fixture(named name: String) throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: name,
        withExtension: "xqgame",
        subdirectory: "Fixtures"
      )
    else {
      throw NativeXiangqiDocumentFormatError.field("testFixture.\(name)")
    }
    return try Data(contentsOf: url, options: [.mappedIfSafe])
  }

  private func assertTypedDocumentFailure(_ error: Error, inputName: String) {
    if error is NativeXiangqiDocumentFormatError || error is XiangqiCoreDocumentError {
      return
    }
    XCTFail("\(inputName) returned an unexpected error type: \(type(of: error))")
  }

  private func generatedData(using generator: inout XorShift64) -> Data {
    let length = generator.nextInt(upperBound: Self.maximumGeneratedInputBytes + 1)
    var bytes = Data()
    bytes.reserveCapacity(length)
    for _ in 0..<length {
      bytes.append(UInt8(truncatingIfNeeded: generator.next()))
    }
    return bytes
  }
}

private struct XorShift64 {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state ^= state << 7
    state ^= state >> 9
    state ^= state << 8
    return state
  }

  mutating func nextInt(upperBound: Int) -> Int {
    precondition(upperBound > 0)
    return Int(next() % UInt64(upperBound))
  }
}
