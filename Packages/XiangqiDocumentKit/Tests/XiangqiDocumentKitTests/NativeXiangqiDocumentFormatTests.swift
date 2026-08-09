import Foundation
import XCTest
import XiangqiCoreBinary

@testable import XiangqiDocumentKit

final class NativeXiangqiDocumentFormatTests: XCTestCase {
  private let initialFEN =
    "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"

  func testV1RoundTripPreservesBranchesSelectionsAnnotationsAndExtensions() throws {
    var record = makeBranchRecord()
    record.extensions = [
      "example.extension": .object([
        "flag": .boolean(true),
        "number": .number("-12.5e+3"),
        "nested": .array([.null, .string("保留")]),
      ])
    ]
    record.unknownTopLevel = ["futurePayload": .object(["version": .integer(2)])]

    let encoded = try NativeXiangqiDocumentFormat.encode(record)
    let decoded = try NativeXiangqiDocumentFormat.decode(encoded)
    let reencoded = try NativeXiangqiDocumentFormat.encode(decoded)
    let redecode = try NativeXiangqiDocumentFormat.decode(reencoded)

    XCTAssertEqual(decoded, record)
    XCTAssertEqual(redecode, record)
    XCTAssertEqual(decoded.core.currentNodeID, 1)
    XCTAssertEqual(decoded.core.nodes[0].selectedChildNodeID, 2)
    XCTAssertEqual(decoded.core.nodes[1].annotation, "主线注释")
  }

  func testPreparedOpenCanonicalizesRootFENBeforeAnyDocumentInstallation() throws {
    var record = makeBranchRecord()
    let nonCanonical = initialFEN.replacingOccurrences(of: "/9/", with: "/111111111/")
    record.core = XiangqiCoreDocumentSnapshot(
      initialFEN: nonCanonical,
      profileID: record.core.profileID,
      profileVersion: record.core.profileVersion,
      currentNodeID: record.core.currentNodeID,
      nodes: record.core.nodes
    )
    let source = try NativeXiangqiDocumentFormat.encode(record)
    let prepared = try makeNativeXiangqiPreparedOpen(source)
    defer { XiangqiCoreGame.discardPreparedDocument(prepared.core) }
    XCTAssertEqual(prepared.record.core.initialFEN, initialFEN)
    XCTAssertEqual(prepared.core.canonicalInitialFEN, initialFEN)
  }

  func testV0MigrationPreservesEverySupportedAnnotationAndRejectsOrphans() throws {
    let valid = """
      {"schemaVersion":0,"documentID":"00000000-0000-4000-8000-000000000001","createdAtMilliseconds":1,"modifiedAtMilliseconds":2,"initialFEN":"\(initialFEN)","ruleProfile":{"id":1,"version":1,"snapshot":"base-v1"},"ucciMainline":["b2b3"],"annotations":{"0":"root","1":"line"},"result":null,"extensions":{"knownFuture":true},"unknownPayload":{"x":1},"metadata":{"legacy":true}}
      """
    let migrated = try NativeXiangqiDocumentFormat.decode(Data(valid.utf8))
    XCTAssertEqual(migrated.core.nodes.count, 2)
    XCTAssertEqual(migrated.core.nodes[0].annotation, "root")
    XCTAssertEqual(migrated.core.nodes[1].annotation, "line")
    XCTAssertEqual(
      migrated.extensions["org.nativexiangqi.migrated-v0"],
      .object([
        "extensions": .object(["knownFuture": .boolean(true)]),
        "unknownTopLevel": .object([
          "unknownPayload": .object(["x": .integer(1)]),
          "metadata": .object(["legacy": .boolean(true)]),
        ]),
      ])
    )
    XCTAssertTrue(migrated.unknownTopLevel.isEmpty)
    XCTAssertEqual(
      try NativeXiangqiDocumentFormat.decode(try NativeXiangqiDocumentFormat.encode(migrated)),
      migrated
    )

    let orphan = valid.replacingOccurrences(of: "\"1\":\"line\"", with: "\"2\":\"orphan\"")
    XCTAssertThrowsError(try NativeXiangqiDocumentFormat.decode(Data(orphan.utf8))) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .field("annotations.key"))
    }
  }

  func testBoundedParserRejectsDepthLongNumberDuplicateKeyAndUnsafeExtensionKey() throws {
    let deeplyNested = String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129)
    XCTAssertThrowsError(try NativeXiangqiDocumentFormat.decode(Data(deeplyNested.utf8))) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .resourceLimit("json.depth"))
    }

    let longNumber = "[" + String(repeating: "1", count: 129) + "]"
    XCTAssertThrowsError(try NativeXiangqiDocumentFormat.decode(Data(longNumber.utf8))) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .resourceLimit("json.number"))
    }

    let duplicate = "{\"schemaVersion\":1,\"schemaVersion\":1}"
    XCTAssertThrowsError(try NativeXiangqiDocumentFormat.decode(Data(duplicate.utf8))) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .field("json.duplicateKey"))
    }

    var record = makeBranchRecord()
    record.extensions = [String(repeating: "x", count: 129): .boolean(true)]
    XCTAssertThrowsError(try NativeXiangqiDocumentFormat.encode(record)) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .field("extensions.key"))
    }
  }

  func testRecordResourceDiagnosticsNameTheExactField() throws {
    var record = makeBranchRecord()
    record.core = XiangqiCoreDocumentSnapshot(
      initialFEN: String(repeating: "x", count: XiangqiCoreDocumentSnapshot.maximumFENBytes + 1),
      profileID: record.core.profileID,
      profileVersion: record.core.profileVersion,
      currentNodeID: record.core.currentNodeID,
      nodes: record.core.nodes
    )
    XCTAssertThrowsError(try NativeXiangqiDocumentFormat.encode(record)) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .resourceLimit("initialFEN"))
    }
  }

  func testCoreMutationAdmissionFailsBeforeTheReservedFileTail() throws {
    XCTAssertNoThrow(
      try NativeXiangqiDocumentPersistenceAdmission.requireCoreMutationHeadroom(
        currentBytes: NativeXiangqiDocumentFormatLimits.maximumFileBytes
          - NativeXiangqiDocumentPersistenceAdmission.reservedCoreMutationBytes
      )
    )
    XCTAssertThrowsError(
      try NativeXiangqiDocumentPersistenceAdmission.requireCoreMutationHeadroom(
        currentBytes: NativeXiangqiDocumentFormatLimits.maximumFileBytes
          - NativeXiangqiDocumentPersistenceAdmission.reservedCoreMutationBytes + 1
      )
    ) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .resourceLimit("fileBytes"))
    }

    XCTAssertNoThrow(
      try NativeXiangqiDocumentPersistenceAdmission.requireCoreMutationHeadroom(
        currentBytes: NativeXiangqiDocumentFormatLimits.maximumFileBytes
          - NativeXiangqiDocumentPersistenceAdmission.reservedNavigationMutationBytes,
        reservationBytes: NativeXiangqiDocumentPersistenceAdmission.reservedNavigationMutationBytes
      )
    )
    XCTAssertThrowsError(
      try NativeXiangqiDocumentPersistenceAdmission.requireCoreMutationHeadroom(
        currentBytes: NativeXiangqiDocumentFormatLimits.maximumFileBytes
          - NativeXiangqiDocumentPersistenceAdmission.reservedNavigationMutationBytes + 1,
        reservationBytes: NativeXiangqiDocumentPersistenceAdmission.reservedNavigationMutationBytes
      )
    ) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .resourceLimit("fileBytes"))
    }
  }

  func testCoordinatedURLReaderRejectsBeforeMaterializingAnOversizeFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NativeXiangqi-reader-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("oversize.xqgame", isDirectory: false)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([0, 1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: directory) }

    XCTAssertThrowsError(try readNativeXiangqiDocumentFile(url, maximumBytes: 1)) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .resourceLimit("fileBytes"))
    }

    let symbolicLink = directory.appendingPathComponent("linked.xqgame", isDirectory: false)
    try FileManager.default.createSymbolicLink(
      atPath: symbolicLink.path,
      withDestinationPath: url.path
    )
    XCTAssertThrowsError(try readNativeXiangqiDocumentFile(symbolicLink, maximumBytes: 2)) {
      error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .field("fileRead"))
    }
  }

  func testMalformedSelectedChildAndIllegalMoveFailBeforeDocumentInstallation() throws {
    var invalidSelection = makeBranchRecord()
    invalidSelection.core = XiangqiCoreDocumentSnapshot(
      initialFEN: invalidSelection.core.initialFEN,
      profileID: invalidSelection.core.profileID,
      profileVersion: invalidSelection.core.profileVersion,
      currentNodeID: invalidSelection.core.currentNodeID,
      nodes: invalidSelection.core.nodes.map { node in
        node.nodeID == 0
          ? XiangqiCoreDocumentNode(
            nodeID: node.nodeID,
            parentNodeID: node.parentNodeID,
            move: node.move,
            childNodeIDs: node.childNodeIDs,
            selectedChildNodeID: nil,
            annotation: node.annotation
          )
          : node
      }
    )
    XCTAssertThrowsError(try NativeXiangqiDocumentFormat.encode(invalidSelection)) { error in
      XCTAssertEqual(
        error as? NativeXiangqiDocumentFormatError,
        .field("variationTree.nodes[0].children")
      )
    }

    var illegal = makeBranchRecord()
    illegal.core = XiangqiCoreDocumentSnapshot(
      initialFEN: illegal.core.initialFEN,
      profileID: illegal.core.profileID,
      profileVersion: illegal.core.profileVersion,
      currentNodeID: illegal.core.currentNodeID,
      nodes: [
        XiangqiCoreDocumentNode(
          nodeID: 0,
          parentNodeID: nil,
          move: nil,
          childNodeIDs: [1],
          selectedChildNodeID: 1,
          annotation: illegal.core.nodes[0].annotation
        ),
        XiangqiCoreDocumentNode(
          nodeID: 1,
          parentNodeID: 0,
          move: XiangqiCoreVariationMove(from: 0, to: 1),
          childNodeIDs: [],
          selectedChildNodeID: nil,
          annotation: ""
        ),
      ]
    )
    XCTAssertThrowsError(try XiangqiCoreGame.preflightDocumentSnapshot(illegal.core)) { error in
      guard case .core(let field, _) = error as? XiangqiCoreDocumentError else {
        return XCTFail("expected Rust preflight error, received \(error)")
      }
      XCTAssertEqual(field, "variationTree.nodes[1]")
    }
  }

  func testCancelledEncodeAndDecodeReturnTypedFailure() throws {
    let token = NativeXiangqiDocumentCancellation()
    token.cancel()
    XCTAssertThrowsError(
      try NativeXiangqiDocumentFormat.encode(makeBranchRecord(), cancellation: token)
    ) {
      error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .cancelled)
    }

    XCTAssertThrowsError(
      try NativeXiangqiDocumentFormat.decode(Data("{}".utf8), cancellation: token)
    ) { error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .cancelled)
    }

    #if DEBUG
      // The first two checks occur at the API/parser boundaries. The third is
      // reached after the parser has consumed a bounded block of whitespace,
      // proving a cancellation that arrives during work is not deferred until
      // an entire untrusted byte stream has been processed.
      let duringParse = NativeXiangqiDocumentCancellation()
      duringParse.cancelAfterChecksForTesting(2)
      let whitespaceThenObject = Data((String(repeating: " ", count: 8_192) + "{}").utf8)
      XCTAssertThrowsError(
        try NativeXiangqiDocumentFormat.decode(whitespaceThenObject, cancellation: duringParse)
      ) { error in
        XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .cancelled)
      }
    #endif
  }

  private func makeBranchRecord() -> NativeXiangqiDocumentRecord {
    let root = XiangqiCoreDocumentNode(
      nodeID: 0,
      parentNodeID: nil,
      move: nil,
      childNodeIDs: [1, 2],
      selectedChildNodeID: 2,
      annotation: "起始注释"
    )
    let first = XiangqiCoreDocumentNode(
      nodeID: 1,
      parentNodeID: 0,
      move: XiangqiCoreVariationMove(from: 19, to: 28),
      childNodeIDs: [],
      selectedChildNodeID: nil,
      annotation: "主线注释"
    )
    let second = XiangqiCoreDocumentNode(
      nodeID: 2,
      parentNodeID: 0,
      move: XiangqiCoreVariationMove(from: 29, to: 38),
      childNodeIDs: [],
      selectedChildNodeID: nil,
      annotation: "分支注释"
    )
    let core = XiangqiCoreDocumentSnapshot(
      initialFEN: initialFEN,
      profileID: 1,
      profileVersion: 1,
      currentNodeID: 1,
      nodes: [root, first, second]
    )
    return NativeXiangqiDocumentRecord(
      documentID: "00000000-0000-4000-8000-000000000001",
      metadata: NativeXiangqiDocumentMetadata(
        createdAtMilliseconds: 1,
        modifiedAtMilliseconds: 2,
        title: "格式测试"
      ),
      core: core,
      result: nil,
      extensions: [:],
      unknownTopLevel: [:]
    )
  }
}
