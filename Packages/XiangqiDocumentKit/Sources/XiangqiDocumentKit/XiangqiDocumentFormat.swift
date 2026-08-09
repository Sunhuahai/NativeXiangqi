import Foundation
import Synchronization
import XiangqiCoreBinary

/// Limits for the single-file, JSON-based `.xqgame` v1 document format.
///
/// The core arena currently limits both nodes and logical depth to 4,096. The
/// JSON representation is deliberately flat, so a valid deeply varied game never
/// needs to exceed the independent JSON nesting limit.
enum NativeXiangqiDocumentFormatLimits {
  static let maximumFileBytes = 64 * 1024 * 1024
  static let maximumJSONDepth = 128
  static let maximumStringBytes = 64 * 1024
  static let maximumObjectEntries = 4_096
  static let maximumArrayEntries = 4_096
  static let maximumExtensionEntries = 256
  static let maximumUnknownTopLevelEntries = 64
  static let maximumExtensionBytes = 1 * 1024 * 1024
  static let maximumMetadataTitleBytes = 4 * 1024
  static let maximumResultBytes = 4 * 1024
  static let maximumTotalAnnotationBytes = 16 * 1024 * 1024
  static let maximumExtensionDepth = 32
  static let maximumExtensionKeyBytes = 128
  /// A parsed record can legitimately retain 4,096 flat nodes plus annotations
  /// and safe extension values. This cap prevents a compact, deeply nested JSON
  /// payload from expanding into millions of Swift enum/container allocations.
  static let maximumDecodedJSONValues = 131_072
  /// Includes decoded string values and object keys. It leaves room for the core
  /// 16 MiB annotation quota plus metadata and the bounded extension envelope.
  static let maximumDecodedStringBytes = 20 * 1024 * 1024
}

/// Admission control for state-changing core operations. A normal move can only
/// add one fixed ASCII node plus one bounded parent-child reference; 4 KiB is a
/// deliberately conservative proof margin for that canonical JSON delta.
/// Navigation can rewrite `selectedChild` along a 4,096-node path: each decimal
/// spelling can grow by at most three bytes (`1` → `4095`), plus `currentNode`,
/// so 16 KiB is a conservative upper bound. A document inside either reserved
/// tail stays readable/exportable and may still shrink annotations, but the
/// relevant mutation is rejected before Rust changes state.
enum NativeXiangqiDocumentPersistenceAdmission {
  static let reservedCoreMutationBytes = 4 * 1024
  static let reservedNavigationMutationBytes = 16 * 1024

  static func requireCoreMutationHeadroom(
    currentBytes: Int,
    reservationBytes: Int = reservedCoreMutationBytes
  ) throws {
    guard currentBytes >= 0,
      reservationBytes > 0,
      reservationBytes <= NativeXiangqiDocumentFormatLimits.maximumFileBytes,
      currentBytes <= NativeXiangqiDocumentFormatLimits.maximumFileBytes - reservationBytes
    else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("fileBytes")
    }
  }
}

private let nativeXiangqiDocumentReadChunkBytes = 64 * 1024

/// A stable, field-addressable codec failure. Its description deliberately omits
/// user content and paths so callers can log only a diagnostic code and field.
enum NativeXiangqiDocumentFormatError: Error, Equatable, Sendable, LocalizedError {
  case field(String)
  case resourceLimit(String)
  case malformedJSON
  case cancelled

  var errorDescription: String? {
    switch self {
    case .field(let field):
      "The .xqgame field \(field) is invalid."
    case .resourceLimit(let field):
      "The .xqgame field \(field) exceeds a documented resource limit."
    case .malformedJSON:
      "The .xqgame JSON is malformed."
    case .cancelled:
      "The .xqgame operation was cancelled before installation."
    }
  }

  var diagnosticCode: String {
    switch self {
    case .field:
      "document-field"
    case .resourceLimit:
      "document-limit"
    case .malformedJSON:
      "document-json"
    case .cancelled:
      "document-cancelled"
    }
  }

  var field: String {
    switch self {
    case .field(let field), .resourceLimit(let field):
      field
    case .malformedJSON:
      "json"
    case .cancelled:
      "operation"
    }
  }
}

/// A bounded, Sendable cancellation signal shared only with a single document
/// operation. It avoids waiting on the MainActor from parser/encoder callbacks.
final class NativeXiangqiDocumentCancellation: Sendable {
  private struct State: Sendable {
    var cancelled = false
    #if DEBUG
      var remainingChecksBeforeCancellation: Int?
    #endif
  }

  private let state = Mutex(State())

  func cancel() {
    state.withLock { $0.cancelled = true }
  }

  var isCancelled: Bool {
    state.withLock(\.cancelled)
  }

  func check() throws {
    let cancelled = state.withLock { value in
      #if DEBUG
        if let remaining = value.remainingChecksBeforeCancellation {
          if remaining == 0 {
            value.cancelled = true
          } else {
            value.remainingChecksBeforeCancellation = remaining - 1
          }
        }
      #endif
      return value.cancelled
    }
    guard !cancelled, !Task.isCancelled else {
      throw NativeXiangqiDocumentFormatError.cancelled
    }
  }

  #if DEBUG
    /// Deterministic test hook for a cancellation that occurs after work has
    /// started rather than only before an API entry point.
    func cancelAfterChecksForTesting(_ checks: Int) {
      state.withLock { value in
        value.remainingChecksBeforeCancellation = max(0, checks)
      }
    }
  #endif
}

/// A lossless, safe JSON value retained only for forward-compatible extensions.
/// Numbers retain their validated JSON spelling so extension values do not become
/// Swift `Double`s or lose integer precision on a normal save cycle.
indirect enum NativeXiangqiJSONValue: Equatable, Sendable {
  case null
  case boolean(Bool)
  case number(String)
  case string(String)
  case array([NativeXiangqiJSONValue])
  case object([String: NativeXiangqiJSONValue])

  static func integer<T: BinaryInteger>(_ value: T) -> NativeXiangqiJSONValue {
    .number(String(value))
  }

  func asObject(field: String) throws -> [String: NativeXiangqiJSONValue] {
    guard case .object(let object) = self else {
      throw NativeXiangqiDocumentFormatError.field(field)
    }
    return object
  }

  func asArray(field: String) throws -> [NativeXiangqiJSONValue] {
    guard case .array(let array) = self else {
      throw NativeXiangqiDocumentFormatError.field(field)
    }
    return array
  }

  func asString(field: String) throws -> String {
    guard case .string(let value) = self else {
      throw NativeXiangqiDocumentFormatError.field(field)
    }
    return value
  }

  func asOptionalString(field: String) throws -> String? {
    switch self {
    case .null:
      nil
    case .string(let value):
      value
    default:
      throw NativeXiangqiDocumentFormatError.field(field)
    }
  }

  func asUInt32(field: String) throws -> UInt32 {
    guard case .number(let value) = self,
      let parsed = UInt32(value),
      String(parsed) == value
    else {
      throw NativeXiangqiDocumentFormatError.field(field)
    }
    return parsed
  }

  func asInt64(field: String) throws -> Int64 {
    guard case .number(let value) = self,
      let parsed = Int64(value),
      String(parsed) == value
    else {
      throw NativeXiangqiDocumentFormatError.field(field)
    }
    return parsed
  }
}

private struct NativeXiangqiJSONParser {
  /// Retain the caller's immutable Data directly. Copying a valid 64 MiB file
  /// into `[UInt8]` before parsing would needlessly consume half of the T040
  /// large-document memory budget.
  private let bytes: Data
  private let cancellation: NativeXiangqiDocumentCancellation?
  private var index = 0
  private var stringBytes = 0
  private var valueCount = 0
  private var workUnits = 0

  init(data: Data, cancellation: NativeXiangqiDocumentCancellation? = nil) {
    bytes = data
    self.cancellation = cancellation
  }

  mutating func parse() throws -> NativeXiangqiJSONValue {
    try checkCancellation()
    try skipWhitespace()
    let value = try parseValue(depth: 0)
    try skipWhitespace()
    guard index == bytes.count else {
      throw NativeXiangqiDocumentFormatError.malformedJSON
    }
    return value
  }

  private mutating func parseValue(depth: Int) throws -> NativeXiangqiJSONValue {
    try recordWork()
    guard let byte = peek() else {
      throw NativeXiangqiDocumentFormatError.malformedJSON
    }
    guard depth <= NativeXiangqiDocumentFormatLimits.maximumJSONDepth else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("json.depth")
    }
    let value: NativeXiangqiJSONValue
    switch byte {
    case 0x7B:  // {
      guard depth < NativeXiangqiDocumentFormatLimits.maximumJSONDepth else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("json.depth")
      }
      value = try parseObject(depth: depth + 1)
    case 0x5B:  // [
      guard depth < NativeXiangqiDocumentFormatLimits.maximumJSONDepth else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("json.depth")
      }
      value = try parseArray(depth: depth + 1)
    case 0x22:  // "
      value = .string(try parseString())
    case 0x74:  // t
      try consumeLiteral("true")
      value = .boolean(true)
    case 0x66:  // f
      try consumeLiteral("false")
      value = .boolean(false)
    case 0x6E:  // n
      try consumeLiteral("null")
      value = .null
    case 0x2D, 0x30...0x39:
      value = .number(try parseNumber())
    default:
      throw NativeXiangqiDocumentFormatError.malformedJSON
    }
    try recordValue()
    return value
  }

  private mutating func parseObject(depth: Int) throws -> NativeXiangqiJSONValue {
    try consume(0x7B)
    try skipWhitespace()
    var object: [String: NativeXiangqiJSONValue] = [:]
    object.reserveCapacity(16)
    if try consumeIf(0x7D) {
      return .object(object)
    }
    while true {
      guard object.count < NativeXiangqiDocumentFormatLimits.maximumObjectEntries else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("json.object")
      }
      guard peek() == 0x22 else {
        throw NativeXiangqiDocumentFormatError.malformedJSON
      }
      let key = try parseString()
      guard object[key] == nil else {
        throw NativeXiangqiDocumentFormatError.field("json.duplicateKey")
      }
      try skipWhitespace()
      try consume(0x3A)  // :
      try skipWhitespace()
      object[key] = try parseValue(depth: depth)
      try skipWhitespace()
      if try consumeIf(0x7D) {
        return .object(object)
      }
      try consume(0x2C)  // ,
      try skipWhitespace()
    }
  }

  private mutating func parseArray(depth: Int) throws -> NativeXiangqiJSONValue {
    try consume(0x5B)
    try skipWhitespace()
    var array: [NativeXiangqiJSONValue] = []
    array.reserveCapacity(16)
    if try consumeIf(0x5D) {
      return .array(array)
    }
    while true {
      guard array.count < NativeXiangqiDocumentFormatLimits.maximumArrayEntries else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("json.array")
      }
      array.append(try parseValue(depth: depth))
      try skipWhitespace()
      if try consumeIf(0x5D) {
        return .array(array)
      }
      try consume(0x2C)
      try skipWhitespace()
    }
  }

  private mutating func parseString() throws -> String {
    try consume(0x22)
    var output: [UInt8] = []
    output.reserveCapacity(32)
    while let byte = peek() {
      try recordWork()
      index += 1
      switch byte {
      case 0x22:  // "
        guard output.count <= NativeXiangqiDocumentFormatLimits.maximumStringBytes else {
          throw NativeXiangqiDocumentFormatError.resourceLimit("json.string")
        }
        let (nextStringBytes, stringOverflow) = stringBytes.addingReportingOverflow(output.count)
        guard !stringOverflow,
          nextStringBytes <= NativeXiangqiDocumentFormatLimits.maximumDecodedStringBytes
        else {
          throw NativeXiangqiDocumentFormatError.resourceLimit("json.decodedStringBytes")
        }
        guard let value = String(bytes: output, encoding: .utf8) else {
          throw NativeXiangqiDocumentFormatError.malformedJSON
        }
        stringBytes = nextStringBytes
        return value
      case 0x5C:  // \
        guard let escaped = peek() else {
          throw NativeXiangqiDocumentFormatError.malformedJSON
        }
        index += 1
        switch escaped {
        case 0x22, 0x5C, 0x2F:
          output.append(escaped)
        case 0x62:
          output.append(0x08)
        case 0x66:
          output.append(0x0C)
        case 0x6E:
          output.append(0x0A)
        case 0x72:
          output.append(0x0D)
        case 0x74:
          output.append(0x09)
        case 0x75:
          let scalar = try parseUnicodeEscape()
          output.append(contentsOf: String(scalar).utf8)
        default:
          throw NativeXiangqiDocumentFormatError.malformedJSON
        }
      case 0x00...0x1F:
        throw NativeXiangqiDocumentFormatError.malformedJSON
      default:
        output.append(byte)
      }
      guard output.count <= NativeXiangqiDocumentFormatLimits.maximumStringBytes else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("json.string")
      }
    }
    throw NativeXiangqiDocumentFormatError.malformedJSON
  }

  private mutating func parseUnicodeEscape() throws -> UnicodeScalar {
    let first = try parseHexCodeUnit()
    if (0xD800...0xDBFF).contains(first) {
      try consume(0x5C)
      try consume(0x75)
      let second = try parseHexCodeUnit()
      guard (0xDC00...0xDFFF).contains(second) else {
        throw NativeXiangqiDocumentFormatError.malformedJSON
      }
      let value = 0x1_0000 + ((UInt32(first) - 0xD800) << 10) + (UInt32(second) - 0xDC00)
      guard let scalar = UnicodeScalar(value) else {
        throw NativeXiangqiDocumentFormatError.malformedJSON
      }
      return scalar
    }
    guard !(0xDC00...0xDFFF).contains(first), let scalar = UnicodeScalar(UInt32(first)) else {
      throw NativeXiangqiDocumentFormatError.malformedJSON
    }
    return scalar
  }

  private mutating func parseHexCodeUnit() throws -> UInt16 {
    var value: UInt16 = 0
    for _ in 0..<4 {
      guard let byte = peek() else {
        throw NativeXiangqiDocumentFormatError.malformedJSON
      }
      index += 1
      let digit: UInt16
      switch byte {
      case 0x30...0x39:
        digit = UInt16(byte - 0x30)
      case 0x41...0x46:
        digit = UInt16(byte - 0x41 + 10)
      case 0x61...0x66:
        digit = UInt16(byte - 0x61 + 10)
      default:
        throw NativeXiangqiDocumentFormatError.malformedJSON
      }
      value = (value << 4) | digit
    }
    return value
  }

  private mutating func parseNumber() throws -> String {
    let start = index
    if peek() == 0x2D {
      try advanceNumberByte(start: start)
    }
    guard let first = peek() else {
      throw NativeXiangqiDocumentFormatError.malformedJSON
    }
    if first == 0x30 {
      try advanceNumberByte(start: start)
    } else if (0x31...0x39).contains(first) {
      try advanceNumberByte(start: start)
      while let byte = peek(), (0x30...0x39).contains(byte) {
        try advanceNumberByte(start: start)
      }
    } else {
      throw NativeXiangqiDocumentFormatError.malformedJSON
    }
    if peek() == 0x2E {
      try advanceNumberByte(start: start)
      guard let byte = peek(), (0x30...0x39).contains(byte) else {
        throw NativeXiangqiDocumentFormatError.malformedJSON
      }
      repeat {
        try advanceNumberByte(start: start)
      } while peek().map({ (0x30...0x39).contains($0) }) == true
    }
    if peek() == 0x65 || peek() == 0x45 {
      try advanceNumberByte(start: start)
      if peek() == 0x2B || peek() == 0x2D {
        try advanceNumberByte(start: start)
      }
      guard let byte = peek(), (0x30...0x39).contains(byte) else {
        throw NativeXiangqiDocumentFormatError.malformedJSON
      }
      repeat {
        try advanceNumberByte(start: start)
      } while peek().map({ (0x30...0x39).contains($0) }) == true
    }
    let number = String(bytes: bytes[start..<index], encoding: .ascii)
    guard let number else { throw NativeXiangqiDocumentFormatError.malformedJSON }
    return number
  }

  private mutating func advanceNumberByte(start: Int) throws {
    try recordWork()
    index += 1
    guard index - start <= 128 else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("json.number")
    }
  }

  private mutating func consumeLiteral(_ literal: StaticString) throws {
    let text = String(describing: literal)
    for expected in text.utf8 {
      try consume(expected)
    }
  }

  private mutating func skipWhitespace() throws {
    while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
      try recordWork()
      index += 1
    }
  }

  private mutating func recordWork() throws {
    workUnits += 1
    guard workUnits >= 4_096 else {
      return
    }
    workUnits = 0
    try checkCancellation()
  }

  private mutating func recordValue() throws {
    let (nextValueCount, overflow) = valueCount.addingReportingOverflow(1)
    guard !overflow,
      nextValueCount <= NativeXiangqiDocumentFormatLimits.maximumDecodedJSONValues
    else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("json.values")
    }
    valueCount = nextValueCount
    try recordWork()
  }

  private func checkCancellation() throws {
    try cancellation?.check()
    guard !Task.isCancelled else {
      throw NativeXiangqiDocumentFormatError.cancelled
    }
  }

  private func peek() -> UInt8? {
    index < bytes.count ? bytes[index] : nil
  }

  private mutating func consume(_ expected: UInt8) throws {
    guard peek() == expected else {
      throw NativeXiangqiDocumentFormatError.malformedJSON
    }
    index += 1
  }

  private mutating func consumeIf(_ expected: UInt8) throws -> Bool {
    guard peek() == expected else {
      return false
    }
    index += 1
    return true
  }
}

private enum NativeXiangqiJSONNumber {
  static func isValid(_ text: String) -> Bool {
    var parser = NativeXiangqiJSONParser(data: Data(text.utf8))
    guard case .number(let parsed)? = try? parser.parse() else {
      return false
    }
    return parsed == text
  }
}

private enum NativeXiangqiJSONEncoder {
  static func encode(
    _ value: NativeXiangqiJSONValue,
    maximumBytes: Int,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> Data {
    var bytes = Data()
    bytes.reserveCapacity(4 * 1024)
    var workUnits = 0
    try append(
      value,
      into: &bytes,
      maximumBytes: maximumBytes,
      cancellation: cancellation,
      workUnits: &workUnits
    )
    return bytes
  }

  private static func append(
    _ value: NativeXiangqiJSONValue,
    into bytes: inout Data,
    maximumBytes: Int,
    cancellation: NativeXiangqiDocumentCancellation?,
    workUnits: inout Int
  ) throws {
    try recordWork(cancellation: cancellation, workUnits: &workUnits)
    switch value {
    case .null:
      try appendASCII(
        "null", into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
        workUnits: &workUnits)
    case .boolean(let value):
      try appendASCII(
        value ? "true" : "false", into: &bytes, maximumBytes: maximumBytes,
        cancellation: cancellation, workUnits: &workUnits)
    case .number(let value):
      guard value.utf8.count <= 128, NativeXiangqiJSONNumber.isValid(value) else {
        throw NativeXiangqiDocumentFormatError.field("json.number")
      }
      try appendASCII(
        value, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
        workUnits: &workUnits)
    case .string(let value):
      try appendString(
        value, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
        workUnits: &workUnits)
    case .array(let values):
      try appendByte(
        0x5B, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
        workUnits: &workUnits)
      for (index, child) in values.enumerated() {
        if index != 0 {
          try appendByte(
            0x2C, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
            workUnits: &workUnits)
        }
        try append(
          child,
          into: &bytes,
          maximumBytes: maximumBytes,
          cancellation: cancellation,
          workUnits: &workUnits
        )
      }
      try appendByte(
        0x5D, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
        workUnits: &workUnits)
    case .object(let object):
      try appendByte(
        0x7B, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
        workUnits: &workUnits)
      for (index, key) in object.keys.sorted().enumerated() {
        guard let child = object[key] else {
          throw NativeXiangqiDocumentFormatError.malformedJSON
        }
        if index != 0 {
          try appendByte(
            0x2C, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
            workUnits: &workUnits)
        }
        try appendString(
          key, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
        try appendByte(
          0x3A, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
        try append(
          child,
          into: &bytes,
          maximumBytes: maximumBytes,
          cancellation: cancellation,
          workUnits: &workUnits
        )
      }
      try appendByte(
        0x7D, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
        workUnits: &workUnits)
    }
  }

  private static func appendString(
    _ string: String,
    into bytes: inout Data,
    maximumBytes: Int,
    cancellation: NativeXiangqiDocumentCancellation?,
    workUnits: inout Int
  ) throws {
    try appendByte(
      0x22, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
      workUnits: &workUnits)
    for scalar in string.unicodeScalars {
      try recordWork(cancellation: cancellation, workUnits: &workUnits)
      switch scalar.value {
      case 0x22:
        try appendASCII(
          "\\\"", into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
      case 0x5C:
        try appendASCII(
          "\\\\", into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
      case 0x08:
        try appendASCII(
          "\\b", into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
      case 0x0C:
        try appendASCII(
          "\\f", into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
      case 0x0A:
        try appendASCII(
          "\\n", into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
      case 0x0D:
        try appendASCII(
          "\\r", into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
      case 0x09:
        try appendASCII(
          "\\t", into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
      case 0x00...0x1F:
        let escaped = String(format: "\\u%04X", scalar.value)
        try appendASCII(
          escaped, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
      default:
        try appendASCII(
          String(scalar), into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
          workUnits: &workUnits)
      }
    }
    try appendByte(
      0x22, into: &bytes, maximumBytes: maximumBytes, cancellation: cancellation,
      workUnits: &workUnits)
  }

  private static func appendASCII(
    _ string: String,
    into bytes: inout Data,
    maximumBytes: Int,
    cancellation: NativeXiangqiDocumentCancellation?,
    workUnits: inout Int
  ) throws {
    try appendBytes(
      Array(string.utf8),
      into: &bytes,
      maximumBytes: maximumBytes,
      cancellation: cancellation,
      workUnits: &workUnits
    )
  }

  private static func appendByte(
    _ byte: UInt8,
    into bytes: inout Data,
    maximumBytes: Int,
    cancellation: NativeXiangqiDocumentCancellation?,
    workUnits: inout Int
  ) throws {
    try appendBytes(
      [byte],
      into: &bytes,
      maximumBytes: maximumBytes,
      cancellation: cancellation,
      workUnits: &workUnits
    )
  }

  private static func appendBytes(
    _ addition: [UInt8],
    into bytes: inout Data,
    maximumBytes: Int,
    cancellation: NativeXiangqiDocumentCancellation?,
    workUnits: inout Int
  ) throws {
    try recordWork(cancellation: cancellation, workUnits: &workUnits)
    guard bytes.count <= maximumBytes - addition.count else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("fileBytes")
    }
    bytes.append(contentsOf: addition)
  }

  private static func recordWork(
    cancellation: NativeXiangqiDocumentCancellation?,
    workUnits: inout Int
  ) throws {
    workUnits += 1
    guard workUnits >= 4_096 else {
      return
    }
    workUnits = 0
    try cancellation?.check()
    guard !Task.isCancelled else {
      throw NativeXiangqiDocumentFormatError.cancelled
    }
  }
}

struct NativeXiangqiDocumentMetadata: Equatable, Sendable {
  var createdAtMilliseconds: Int64
  var modifiedAtMilliseconds: Int64
  var title: String?

  static func newDocument() -> Self {
    let milliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    return Self(
      createdAtMilliseconds: milliseconds, modifiedAtMilliseconds: milliseconds, title: nil)
  }
}

/// The complete v1 persistence envelope. `core` is always an immutable snapshot
/// obtained from `XiangqiCoreGame`, never the T030 presentation ledger.
struct NativeXiangqiDocumentRecord: Equatable, Sendable {
  static let schemaVersion: UInt32 = 1
  static let profileSnapshot = "base-v1"

  var documentID: String
  var metadata: NativeXiangqiDocumentMetadata
  var core: XiangqiCoreDocumentSnapshot
  var result: String?
  var extensions: [String: NativeXiangqiJSONValue]
  var unknownTopLevel: [String: NativeXiangqiJSONValue]

  static func newDocument(core: XiangqiCoreDocumentSnapshot) -> Self {
    Self(
      documentID: UUID().uuidString.lowercased(),
      metadata: .newDocument(),
      core: core,
      result: nil,
      extensions: [:],
      unknownTopLevel: [:]
    )
  }

  mutating func updateCore(_ core: XiangqiCoreDocumentSnapshot, touchesModifiedDate: Bool) {
    self.core = core
    if touchesModifiedDate {
      metadata.modifiedAtMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
  }
}

actor NativeXiangqiDocumentCodec {
  func encode(
    _ record: NativeXiangqiDocumentRecord,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> Data {
    try NativeXiangqiDocumentFormat.encode(record, cancellation: cancellation)
  }

  func decode(
    _ data: Data,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> NativeXiangqiDocumentRecord {
    try NativeXiangqiDocumentFormat.decode(data, cancellation: cancellation)
  }

  func decodeAndPreflight(
    _ data: Data,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> NativeXiangqiDocumentRecord {
    let record = try NativeXiangqiDocumentFormat.decode(data, cancellation: cancellation)
    try cancellation?.check()
    try XiangqiCoreGame.preflightDocumentSnapshot(record.core)
    return record
  }

  /// Creates the exact capacity-one handoff used for open/revert from this
  /// worker actor. JSON decode, canonical Rust replay, and JSON re-encoding all
  /// finish before any MainActor state can be replaced.
  func prepareOpen(
    _ data: Data,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> NativeXiangqiPreparedOpen {
    try makeNativeXiangqiPreparedOpen(data, cancellation: cancellation)
  }
}

/// Builds a fully replayed Rust candidate and immutable persistence bytes on a
/// non-UI caller. The candidate is explicitly destroyed if encoding fails, so a
/// malformed extension or size limit cannot leak a handle after a successful
/// replay.
func makeNativeXiangqiPreparedOpen(
  _ data: Data,
  modificationDate: Date? = nil,
  cancellation: NativeXiangqiDocumentCancellation? = nil
) throws -> NativeXiangqiPreparedOpen {
  try cancellation?.check()
  var record = try NativeXiangqiDocumentFormat.decode(data, cancellation: cancellation)
  try cancellation?.check()
  let core = try XiangqiCoreGame.prepareDocumentSnapshotForOpen(record.core)
  do {
    if record.core.initialFEN != core.canonicalInitialFEN {
      record.updateCore(
        XiangqiCoreDocumentSnapshot(
          initialFEN: core.canonicalInitialFEN,
          profileID: record.core.profileID,
          profileVersion: record.core.profileVersion,
          currentNodeID: record.core.currentNodeID,
          nodes: record.core.nodes
        ),
        touchesModifiedDate: false
      )
    }
    let encoded = try NativeXiangqiDocumentFormat.encode(record, cancellation: cancellation)
    return NativeXiangqiPreparedOpen(
      record: record,
      data: encoded,
      modificationDate: modificationDate,
      core: core
    )
  } catch {
    XiangqiCoreGame.discardPreparedDocument(core)
    throw error
  }
}

struct NativeXiangqiDocumentFileContents: Sendable {
  let data: Data
  let modificationDate: Date?
}

/// Reads a single native document with a pre-materialization byte check. It is
/// used by both NSDocument's concurrent URL-open callback and the dedicated
/// restore worker, never by AppKit presentation code on the main actor.
func readNativeXiangqiDocumentFile(
  _ url: URL,
  maximumBytes: Int,
  cancellation: NativeXiangqiDocumentCancellation? = nil
) throws -> NativeXiangqiDocumentFileContents {
  try cancellation?.check()
  try Task.checkCancellation()
  var coordinatedResult: Result<NativeXiangqiDocumentFileContents, Error>?
  var coordinationError: NSError?
  let coordinator = NSFileCoordinator()
  coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
    coordinatedURL in
    coordinatedResult = Result {
      guard maximumBytes >= 0 else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("fileBytes")
      }
      // Check the caller-facing URL before FileHandle can follow it. The
      // coordinated URL is checked again below because a file presenter may
      // replace the item while the coordinator obtains its read lease.
      let originalValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard originalValues.isSymbolicLink != true else {
        throw NativeXiangqiDocumentFormatError.field("fileRead")
      }
      let values = try coordinatedURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let declaredSize = values.fileSize,
        declaredSize >= 0
      else {
        throw NativeXiangqiDocumentFormatError.field("fileRead")
      }
      guard declaredSize <= maximumBytes else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("fileBytes")
      }
      try cancellation?.check()
      try Task.checkCancellation()
      let handle = try FileHandle(forReadingFrom: coordinatedURL)
      do {
        var data = Data()
        data.reserveCapacity(declaredSize)
        var remainingBytes = maximumBytes + 1
        while remainingBytes > 0 {
          try cancellation?.check()
          try Task.checkCancellation()
          let requestBytes = min(nativeXiangqiDocumentReadChunkBytes, remainingBytes)
          guard let chunk = try handle.read(upToCount: requestBytes), !chunk.isEmpty else {
            break
          }
          guard chunk.count <= maximumBytes - data.count else {
            throw NativeXiangqiDocumentFormatError.resourceLimit("fileBytes")
          }
          data.append(chunk)
          remainingBytes -= chunk.count
        }
        guard remainingBytes > 0 else {
          throw NativeXiangqiDocumentFormatError.resourceLimit("fileBytes")
        }
        let contents = NativeXiangqiDocumentFileContents(
          data: data,
          modificationDate: values.contentModificationDate
        )
        try handle.close()
        return contents
      } catch {
        // A failed read must still close its descriptor before the caller can
        // retry. If closing itself fails, it remains a typed failed operation;
        // no partial bytes are returned or cached.
        try handle.close()
        throw error
      }
    }
  }
  if let coordinationError {
    throw coordinationError
  }
  guard let coordinatedResult else {
    throw NativeXiangqiDocumentFormatError.field("fileRead")
  }
  return try coordinatedResult.get()
}

actor NativeXiangqiDocumentFileReader {
  func read(
    _ url: URL,
    maximumBytes: Int,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> NativeXiangqiDocumentFileContents {
    try readNativeXiangqiDocumentFile(url, maximumBytes: maximumBytes, cancellation: cancellation)
  }

  /// A saved document outside an iCloud-backed location is already local. For
  /// ubiquitous files, require the current NSFileVersion to report local bytes
  /// before coordinating a read; this code never asks the system to download a
  /// nonlocal version.
  func readCurrentLocalDocument(
    _ url: URL,
    maximumBytes: Int,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> NativeXiangqiDocumentFileContents {
    let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
    if values.isUbiquitousItem == true {
      guard let version = NSFileVersion.currentVersionOfItem(at: url),
        version.hasLocalContents
      else {
        throw NativeXiangqiDocumentFormatError.field("localVersionRecovery")
      }
      return try read(version.url, maximumBytes: maximumBytes, cancellation: cancellation)
    }
    return try read(url, maximumBytes: maximumBytes, cancellation: cancellation)
  }

  /// Re-resolves the descriptor against the current local NSFileVersion set
  /// under the caller's file-access lease. A source-tagged descriptor is not a
  /// capability: stale or fabricated URLs must match a presently local version
  /// before bytes are read, and this code never requests nonlocal versions.
  func readLocalVersion(
    documentURL: URL,
    versionURL: URL,
    maximumBytes: Int,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> NativeXiangqiDocumentFileContents {
    guard
      let version = (NSFileVersion.otherVersionsOfItem(at: documentURL) ?? []).first(where: {
        $0.url == versionURL
      }), version.hasLocalContents
    else {
      throw NativeXiangqiDocumentFormatError.field("localVersionRecovery")
    }
    return try read(version.url, maximumBytes: maximumBytes, cancellation: cancellation)
  }
}

/// Nonisolated NSDocument callbacks use this Sendable mutex-protected cache only
/// for immutable values prepared by the document's core/codec operation. It does
/// not own game, UI, or rule state.
final class NativeXiangqiDocumentSerializationCache: Sendable {
  private struct State: Sendable {
    var data: Data?
    var pendingOpen: NativeXiangqiPreparedOpen?
  }

  private let state = Mutex(State(data: nil, pendingOpen: nil))

  deinit {
    discardPendingOpen()
  }

  func install(data: Data) {
    state.withLock { value in
      value.data = data
    }
  }

  func stagePreparedOpen(_ prepared: NativeXiangqiPreparedOpen) {
    let displaced = state.withLock { value -> NativeXiangqiPreparedOpen? in
      let previous = value.pendingOpen
      value.pendingOpen = prepared
      return previous
    }
    if let displaced {
      XiangqiCoreGame.discardPreparedDocument(displaced.core)
    }
  }

  func consumePendingOpen() -> NativeXiangqiPreparedOpen? {
    state.withLock { value in
      defer { value.pendingOpen = nil }
      return value.pendingOpen
    }
  }

  func discardPendingOpen() {
    let displaced = state.withLock { value -> NativeXiangqiPreparedOpen? in
      defer { value.pendingOpen = nil }
      return value.pendingOpen
    }
    if let displaced {
      XiangqiCoreGame.discardPreparedDocument(displaced.core)
    }
  }

  func data() throws -> Data {
    try state.withLock { value in
      guard let data = value.data else {
        throw NativeXiangqiDocumentFormatError.field("serializationSnapshot")
      }
      return data
    }
  }
}

/// A capacity-one staging record for AppKit's background `read` → MainActor
/// window-controller handoff. It contains a Rust-owned opaque handle, immutable
/// persistence bytes, and no mutable Swift rules/tree state.
struct NativeXiangqiPreparedOpen: Sendable {
  let record: NativeXiangqiDocumentRecord
  let data: Data
  let modificationDate: Date?
  var core: XiangqiCorePreparedDocument
}

enum NativeXiangqiDocumentFormat {
  /// v0 had no reserved-v1 namespace. Preserve all of its extension payload in
  /// one v1 extension envelope so a formerly unknown v0 top-level key such as
  /// `metadata` cannot collide with a v1 core field during re-encoding.
  private static let migratedV0EnvelopeKey = "org.nativexiangqi.migrated-v0"

  private static let knownRootFields: Set<String> = [
    "schemaVersion", "documentID", "metadata", "initialFEN", "ruleProfile", "variationTree",
    "currentNode", "annotations", "result", "extensions",
  ]

  static func encode(
    _ record: NativeXiangqiDocumentRecord,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> Data {
    try checkCancellation(cancellation)
    try validateRecord(record, cancellation: cancellation)
    var nodes: [NativeXiangqiJSONValue] = []
    nodes.reserveCapacity(record.core.nodes.count)
    for (index, node) in record.core.nodes.enumerated() {
      if index.isMultiple(of: 32) {
        try checkCancellation(cancellation)
      }
      nodes.append(encodeNode(node))
    }
    var annotations: [String: NativeXiangqiJSONValue] = [:]
    annotations.reserveCapacity(record.core.nodes.count)
    for (index, node) in record.core.nodes.enumerated() where !node.annotation.isEmpty {
      if index.isMultiple(of: 32) {
        try checkCancellation(cancellation)
      }
      annotations[String(node.nodeID)] = .string(node.annotation)
    }
    var root: [String: NativeXiangqiJSONValue] = [
      "schemaVersion": .integer(NativeXiangqiDocumentRecord.schemaVersion),
      "documentID": .string(record.documentID),
      "metadata": .object([
        "createdAtMilliseconds": .integer(record.metadata.createdAtMilliseconds),
        "modifiedAtMilliseconds": .integer(record.metadata.modifiedAtMilliseconds),
        "title": record.metadata.title.map(NativeXiangqiJSONValue.string) ?? .null,
      ]),
      "initialFEN": .string(record.core.initialFEN),
      "ruleProfile": .object([
        "id": .integer(record.core.profileID),
        "version": .integer(record.core.profileVersion),
        "snapshot": .string(NativeXiangqiDocumentRecord.profileSnapshot),
      ]),
      "variationTree": .object(["nodes": .array(nodes)]),
      "currentNode": .integer(record.core.currentNodeID),
      "annotations": .object(annotations),
      "result": record.result.map(NativeXiangqiJSONValue.string) ?? .null,
      "extensions": .object(record.extensions),
    ]
    for (index, keyValue) in record.unknownTopLevel.enumerated() {
      if index.isMultiple(of: 32) {
        try checkCancellation(cancellation)
      }
      let (key, value) = keyValue
      guard root[key] == nil else {
        throw NativeXiangqiDocumentFormatError.field("extensions")
      }
      root[key] = value
    }
    return try NativeXiangqiJSONEncoder.encode(
      .object(root),
      maximumBytes: NativeXiangqiDocumentFormatLimits.maximumFileBytes,
      cancellation: cancellation
    )
  }

  static func decode(
    _ data: Data,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> NativeXiangqiDocumentRecord {
    try checkCancellation(cancellation)
    guard !data.isEmpty, data.count <= NativeXiangqiDocumentFormatLimits.maximumFileBytes else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("fileBytes")
    }
    var parser = NativeXiangqiJSONParser(data: data, cancellation: cancellation)
    let value = try parser.parse()
    let root = try value.asObject(field: "root")
    let schemaVersion = try required(root, "schemaVersion", field: "schemaVersion").asUInt32(
      field: "schemaVersion"
    )
    switch schemaVersion {
    case NativeXiangqiDocumentRecord.schemaVersion:
      return try decodeV1(root, cancellation: cancellation)
    case 0:
      return try migrateV0(root, cancellation: cancellation)
    default:
      throw NativeXiangqiDocumentFormatError.field("schemaVersion")
    }
  }

  private static func decodeV1(
    _ root: [String: NativeXiangqiJSONValue],
    cancellation: NativeXiangqiDocumentCancellation?
  ) throws -> NativeXiangqiDocumentRecord {
    try checkCancellation(cancellation)
    let documentID = try decodeDocumentID(root)
    let metadata = try decodeMetadata(try required(root, "metadata", field: "metadata"))
    let initialFEN = try required(root, "initialFEN", field: "initialFEN").asString(
      field: "initialFEN")
    let (profileID, profileVersion) = try decodeProfile(
      try required(root, "ruleProfile", field: "ruleProfile")
    )
    let nodes = try decodeNodes(
      try required(root, "variationTree", field: "variationTree"),
      annotations: try required(root, "annotations", field: "annotations"),
      cancellation: cancellation
    )
    let currentNode = try required(root, "currentNode", field: "currentNode").asUInt32(
      field: "currentNode"
    )
    let result = try required(root, "result", field: "result").asOptionalString(field: "result")
    let extensions = try decodeExtensions(
      try required(root, "extensions", field: "extensions"),
      field: "extensions",
      maximumEntries: NativeXiangqiDocumentFormatLimits.maximumExtensionEntries,
      cancellation: cancellation
    )
    let unknownTopLevel = try decodeUnknownTopLevel(root, cancellation: cancellation)
    let record = NativeXiangqiDocumentRecord(
      documentID: documentID,
      metadata: metadata,
      core: XiangqiCoreDocumentSnapshot(
        initialFEN: initialFEN,
        profileID: profileID,
        profileVersion: profileVersion,
        currentNodeID: currentNode,
        nodes: nodes
      ),
      result: result,
      extensions: extensions,
      unknownTopLevel: unknownTopLevel
    )
    try validateRecord(record, cancellation: cancellation)
    return record
  }

  /// v0 was a linear, pre-branch fixture format. Migration is pure: it creates a
  /// v1 flat tree in memory and never writes a source file before Rust replay has
  /// succeeded in the owning NSDocument.
  private static func migrateV0(
    _ root: [String: NativeXiangqiJSONValue],
    cancellation: NativeXiangqiDocumentCancellation?
  ) throws -> NativeXiangqiDocumentRecord {
    try checkCancellation(cancellation)
    let documentID = try decodeDocumentID(root)
    let created = try required(root, "createdAtMilliseconds", field: "createdAtMilliseconds")
      .asInt64(field: "createdAtMilliseconds")
    let modified = try required(root, "modifiedAtMilliseconds", field: "modifiedAtMilliseconds")
      .asInt64(field: "modifiedAtMilliseconds")
    let initialFEN = try required(root, "initialFEN", field: "initialFEN").asString(
      field: "initialFEN")
    let (profileID, profileVersion) = try decodeProfile(
      try required(root, "ruleProfile", field: "ruleProfile")
    )
    let moveValues = try required(root, "ucciMainline", field: "ucciMainline").asArray(
      field: "ucciMainline"
    )
    guard moveValues.count < XiangqiCoreDocumentSnapshot.maximumNodes else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("ucciMainline")
    }
    var oldAnnotations = try decodeV0Annotations(
      try required(root, "annotations", field: "annotations"),
      maximumNodeID: UInt32(moveValues.count),
      cancellation: cancellation
    )
    let legacyExtensions = try decodeExtensions(
      try required(root, "extensions", field: "extensions"),
      field: "extensions",
      maximumEntries: NativeXiangqiDocumentFormatLimits.maximumExtensionEntries,
      cancellation: cancellation
    )
    var nodes: [XiangqiCoreDocumentNode] = [
      XiangqiCoreDocumentNode(
        nodeID: 0,
        parentNodeID: nil,
        move: nil,
        childNodeIDs: moveValues.isEmpty ? [] : [1],
        selectedChildNodeID: moveValues.isEmpty ? nil : 1,
        annotation: oldAnnotations.removeValue(forKey: 0) ?? ""
      )
    ]
    for (offset, value) in moveValues.enumerated() {
      if offset.isMultiple(of: 32) {
        try checkCancellation(cancellation)
      }
      let field = "ucciMainline[\(offset + 1)]"
      let move = try parseUCCIMove(value.asString(field: field), field: field)
      let nodeID = UInt32(offset + 1)
      let nextNode = offset + 1 < moveValues.count ? nodeID + 1 : nil
      nodes.append(
        XiangqiCoreDocumentNode(
          nodeID: nodeID,
          parentNodeID: nodeID - 1,
          move: move,
          childNodeIDs: nextNode.map { [$0] } ?? [],
          selectedChildNodeID: nextNode,
          annotation: oldAnnotations.removeValue(forKey: nodeID) ?? ""
        )
      )
    }
    guard oldAnnotations.isEmpty else {
      throw NativeXiangqiDocumentFormatError.field("annotations")
    }
    let result = try required(root, "result", field: "result").asOptionalString(field: "result")
    let legacyUnknownTopLevel = try decodeUnknownTopLevel(
      root,
      cancellation: cancellation,
      knownFields: [
        "schemaVersion", "documentID", "createdAtMilliseconds", "modifiedAtMilliseconds",
        "initialFEN", "ruleProfile", "ucciMainline", "annotations", "result", "extensions",
      ]
    )
    var extensions: [String: NativeXiangqiJSONValue] = [:]
    if !legacyExtensions.isEmpty || !legacyUnknownTopLevel.isEmpty {
      extensions[migratedV0EnvelopeKey] = .object([
        "extensions": .object(legacyExtensions),
        "unknownTopLevel": .object(legacyUnknownTopLevel),
      ])
    }
    let record = NativeXiangqiDocumentRecord(
      documentID: documentID,
      metadata: NativeXiangqiDocumentMetadata(
        createdAtMilliseconds: created,
        modifiedAtMilliseconds: modified,
        title: nil
      ),
      core: XiangqiCoreDocumentSnapshot(
        initialFEN: initialFEN,
        profileID: profileID,
        profileVersion: profileVersion,
        currentNodeID: UInt32(moveValues.count),
        nodes: nodes
      ),
      result: result,
      extensions: extensions,
      unknownTopLevel: [:]
    )
    try validateRecord(record, cancellation: cancellation)
    return record
  }

  private static func encodeNode(_ node: XiangqiCoreDocumentNode) -> NativeXiangqiJSONValue {
    .object([
      "id": .integer(node.nodeID),
      "parent": node.parentNodeID.map(NativeXiangqiJSONValue.integer) ?? .null,
      "move": node.move.map(encodeMove) ?? .null,
      "children": .array(node.childNodeIDs.map(NativeXiangqiJSONValue.integer)),
      "selectedChild": node.selectedChildNodeID.map(NativeXiangqiJSONValue.integer) ?? .null,
    ])
  }

  private static func encodeMove(_ move: XiangqiCoreVariationMove) -> NativeXiangqiJSONValue {
    .object(["from": .integer(move.from), "to": .integer(move.to)])
  }

  private static func decodeNodes(
    _ treeValue: NativeXiangqiJSONValue,
    annotations: NativeXiangqiJSONValue,
    cancellation: NativeXiangqiDocumentCancellation?
  ) throws -> [XiangqiCoreDocumentNode] {
    let tree = try treeValue.asObject(field: "variationTree")
    try rejectUnexpectedKeys(tree, allowed: ["nodes"], field: "variationTree")
    let values = try required(tree, "nodes", field: "variationTree.nodes").asArray(
      field: "variationTree.nodes"
    )
    guard !values.isEmpty, values.count <= XiangqiCoreDocumentSnapshot.maximumNodes else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("variationTree.nodes")
    }
    let annotationsObject = try annotations.asObject(field: "annotations")
    guard annotationsObject.count <= XiangqiCoreDocumentSnapshot.maximumNodes else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("annotations")
    }
    var annotationsByNode: [UInt32: String] = [:]
    var totalAnnotationBytes = 0
    for (index, keyValue) in annotationsObject.enumerated() {
      if index.isMultiple(of: 32) {
        try checkCancellation(cancellation)
      }
      let (key, value) = keyValue
      guard let nodeID = UInt32(key), String(nodeID) == key else {
        throw NativeXiangqiDocumentFormatError.field("annotations.key")
      }
      let annotation = try value.asString(field: "annotations.value")
      guard annotation.utf8.count <= XiangqiCoreDocumentSnapshot.maximumAnnotationBytesPerNode
      else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("annotations.value")
      }
      totalAnnotationBytes += annotation.utf8.count
      guard totalAnnotationBytes <= NativeXiangqiDocumentFormatLimits.maximumTotalAnnotationBytes,
        annotationsByNode[nodeID] == nil
      else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("annotations")
      }
      annotationsByNode[nodeID] = annotation
    }
    var nodes: [XiangqiCoreDocumentNode] = []
    nodes.reserveCapacity(values.count)
    for (index, value) in values.enumerated() {
      if index.isMultiple(of: 32) {
        try checkCancellation(cancellation)
      }
      let field = "variationTree.nodes[\(index)]"
      let object = try value.asObject(field: field)
      try rejectUnexpectedKeys(
        object,
        allowed: ["id", "parent", "move", "children", "selectedChild"],
        field: field
      )
      let nodeID = try required(object, "id", field: "\(field).id").asUInt32(field: "\(field).id")
      let parent = try optionalUInt32(
        required(object, "parent", field: "\(field).parent"),
        field: "\(field).parent"
      )
      let move = try optionalMove(
        required(object, "move", field: "\(field).move"),
        field: "\(field).move"
      )
      let childValues = try required(object, "children", field: "\(field).children").asArray(
        field: "\(field).children"
      )
      guard childValues.count <= 256 else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("\(field).children")
      }
      let childNodeIDs = try childValues.enumerated().map { childIndex, childValue in
        try childValue.asUInt32(field: "\(field).children[\(childIndex)]")
      }
      let selected = try optionalUInt32(
        required(object, "selectedChild", field: "\(field).selectedChild"),
        field: "\(field).selectedChild"
      )
      nodes.append(
        XiangqiCoreDocumentNode(
          nodeID: nodeID,
          parentNodeID: parent,
          move: move,
          childNodeIDs: childNodeIDs,
          selectedChildNodeID: selected,
          annotation: annotationsByNode.removeValue(forKey: nodeID) ?? ""
        )
      )
    }
    guard annotationsByNode.isEmpty else {
      throw NativeXiangqiDocumentFormatError.field("annotations")
    }
    return nodes
  }

  private static func decodeDocumentID(_ root: [String: NativeXiangqiJSONValue]) throws -> String {
    let value = try required(root, "documentID", field: "documentID").asString(field: "documentID")
    guard let identifier = UUID(uuidString: value) else {
      throw NativeXiangqiDocumentFormatError.field("documentID")
    }
    return identifier.uuidString.lowercased()
  }

  private static func decodeMetadata(_ value: NativeXiangqiJSONValue) throws
    -> NativeXiangqiDocumentMetadata
  {
    let object = try value.asObject(field: "metadata")
    try rejectUnexpectedKeys(
      object,
      allowed: ["createdAtMilliseconds", "modifiedAtMilliseconds", "title"],
      field: "metadata"
    )
    let created = try required(
      object, "createdAtMilliseconds", field: "metadata.createdAtMilliseconds"
    )
    .asInt64(field: "metadata.createdAtMilliseconds")
    let modified = try required(
      object, "modifiedAtMilliseconds", field: "metadata.modifiedAtMilliseconds"
    )
    .asInt64(field: "metadata.modifiedAtMilliseconds")
    let title = try required(object, "title", field: "metadata.title").asOptionalString(
      field: "metadata.title"
    )
    guard created >= 0, modified >= created,
      title?.utf8.count ?? 0 <= NativeXiangqiDocumentFormatLimits.maximumMetadataTitleBytes
    else {
      throw NativeXiangqiDocumentFormatError.field("metadata")
    }
    return NativeXiangqiDocumentMetadata(
      createdAtMilliseconds: created,
      modifiedAtMilliseconds: modified,
      title: title
    )
  }

  private static func decodeProfile(_ value: NativeXiangqiJSONValue) throws -> (UInt32, UInt32) {
    let object = try value.asObject(field: "ruleProfile")
    try rejectUnexpectedKeys(object, allowed: ["id", "version", "snapshot"], field: "ruleProfile")
    let identifier = try required(object, "id", field: "ruleProfile.id").asUInt32(
      field: "ruleProfile.id")
    let version = try required(object, "version", field: "ruleProfile.version").asUInt32(
      field: "ruleProfile.version"
    )
    let snapshot = try required(object, "snapshot", field: "ruleProfile.snapshot").asString(
      field: "ruleProfile.snapshot"
    )
    guard identifier == 1, version == 1, snapshot == NativeXiangqiDocumentRecord.profileSnapshot
    else {
      throw NativeXiangqiDocumentFormatError.field("ruleProfile")
    }
    return (identifier, version)
  }

  private static func decodeExtensions(
    _ value: NativeXiangqiJSONValue,
    field: String,
    maximumEntries: Int,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws -> [String: NativeXiangqiJSONValue] {
    let object = try value.asObject(field: field)
    guard object.count <= maximumEntries else {
      throw NativeXiangqiDocumentFormatError.resourceLimit(field)
    }
    var workUnits = 0
    for (key, extensionValue) in object {
      try recordSemanticWork(cancellation, workUnits: &workUnits)
      guard !key.isEmpty,
        key.utf8.count <= NativeXiangqiDocumentFormatLimits.maximumExtensionKeyBytes
      else {
        throw NativeXiangqiDocumentFormatError.field("\(field).key")
      }
      try validateExtension(
        extensionValue,
        depth: 0,
        field: "\(field).value",
        cancellation: cancellation,
        workUnits: &workUnits
      )
    }
    let encoded = try NativeXiangqiJSONEncoder.encode(
      .object(object),
      maximumBytes: NativeXiangqiDocumentFormatLimits.maximumExtensionBytes,
      cancellation: cancellation
    )
    guard encoded.count <= NativeXiangqiDocumentFormatLimits.maximumExtensionBytes else {
      throw NativeXiangqiDocumentFormatError.resourceLimit(field)
    }
    return object
  }

  private static func decodeUnknownTopLevel(
    _ root: [String: NativeXiangqiJSONValue],
    cancellation: NativeXiangqiDocumentCancellation? = nil,
    knownFields: Set<String> = knownRootFields
  ) throws -> [String: NativeXiangqiJSONValue] {
    let unknown = root.filter { !knownFields.contains($0.key) }
    guard unknown.count <= NativeXiangqiDocumentFormatLimits.maximumUnknownTopLevelEntries else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("extensions")
    }
    return try decodeExtensions(
      .object(unknown),
      field: "extensions",
      maximumEntries: NativeXiangqiDocumentFormatLimits.maximumUnknownTopLevelEntries,
      cancellation: cancellation
    )
  }

  private static func validateExtension(
    _ value: NativeXiangqiJSONValue,
    depth: Int,
    field: String,
    cancellation: NativeXiangqiDocumentCancellation?,
    workUnits: inout Int
  ) throws {
    try recordSemanticWork(cancellation, workUnits: &workUnits)
    guard depth <= NativeXiangqiDocumentFormatLimits.maximumExtensionDepth else {
      throw NativeXiangqiDocumentFormatError.resourceLimit(field)
    }
    switch value {
    case .null, .boolean, .number:
      return
    case .string(let string):
      guard string.utf8.count <= NativeXiangqiDocumentFormatLimits.maximumStringBytes else {
        throw NativeXiangqiDocumentFormatError.resourceLimit(field)
      }
    case .array(let values):
      guard values.count <= NativeXiangqiDocumentFormatLimits.maximumArrayEntries else {
        throw NativeXiangqiDocumentFormatError.resourceLimit(field)
      }
      for child in values {
        try validateExtension(
          child,
          depth: depth + 1,
          field: field,
          cancellation: cancellation,
          workUnits: &workUnits
        )
      }
    case .object(let object):
      guard object.count <= NativeXiangqiDocumentFormatLimits.maximumObjectEntries else {
        throw NativeXiangqiDocumentFormatError.resourceLimit(field)
      }
      for (key, child) in object {
        guard !key.isEmpty,
          key.utf8.count <= NativeXiangqiDocumentFormatLimits.maximumExtensionKeyBytes
        else {
          throw NativeXiangqiDocumentFormatError.field("\(field).key")
        }
        try validateExtension(
          child,
          depth: depth + 1,
          field: field,
          cancellation: cancellation,
          workUnits: &workUnits
        )
      }
    }
  }

  private static func validateRecord(
    _ record: NativeXiangqiDocumentRecord,
    cancellation: NativeXiangqiDocumentCancellation? = nil
  ) throws {
    try checkCancellation(cancellation)
    guard UUID(uuidString: record.documentID) != nil else {
      throw NativeXiangqiDocumentFormatError.field("documentID")
    }
    guard record.metadata.createdAtMilliseconds >= 0 else {
      throw NativeXiangqiDocumentFormatError.field("metadata.createdAtMilliseconds")
    }
    guard record.metadata.modifiedAtMilliseconds >= record.metadata.createdAtMilliseconds else {
      throw NativeXiangqiDocumentFormatError.field("metadata.modifiedAtMilliseconds")
    }
    guard
      record.metadata.title?.utf8.count ?? 0
        <= NativeXiangqiDocumentFormatLimits.maximumMetadataTitleBytes
    else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("metadata.title")
    }
    guard record.result?.utf8.count ?? 0 <= NativeXiangqiDocumentFormatLimits.maximumResultBytes
    else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("result")
    }
    guard record.core.initialFEN.utf8.count <= XiangqiCoreDocumentSnapshot.maximumFENBytes else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("initialFEN")
    }
    guard record.core.profileID == 1, record.core.profileVersion == 1 else {
      throw NativeXiangqiDocumentFormatError.field("ruleProfile")
    }
    guard !record.core.nodes.isEmpty else {
      throw NativeXiangqiDocumentFormatError.field("variationTree.nodes")
    }
    guard record.core.nodes.count <= XiangqiCoreDocumentSnapshot.maximumNodes else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("variationTree.nodes")
    }
    do {
      try XiangqiCoreGame.validateDocumentSnapshot(record.core)
    } catch let error as XiangqiCoreDocumentError {
      throw NativeXiangqiDocumentFormatError.field(error.field)
    }
    var totalAnnotationBytes = 0
    for (index, node) in record.core.nodes.enumerated() {
      if index.isMultiple(of: 32) {
        try checkCancellation(cancellation)
      }
      totalAnnotationBytes += node.annotation.utf8.count
      guard totalAnnotationBytes <= NativeXiangqiDocumentFormatLimits.maximumTotalAnnotationBytes
      else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("annotations")
      }
    }
    _ = try decodeExtensions(
      .object(record.extensions),
      field: "extensions",
      maximumEntries: NativeXiangqiDocumentFormatLimits.maximumExtensionEntries,
      cancellation: cancellation
    )
    _ = try decodeExtensions(
      .object(record.unknownTopLevel),
      field: "extensions",
      maximumEntries: NativeXiangqiDocumentFormatLimits.maximumUnknownTopLevelEntries,
      cancellation: cancellation
    )
  }

  private static func parseUCCIMove(_ text: String, field: String) throws
    -> XiangqiCoreVariationMove
  {
    let bytes = Array(text.utf8)
    guard bytes.count == 4,
      (UInt8(ascii: "a")...UInt8(ascii: "i")).contains(bytes[0]),
      bytes[1] >= UInt8(ascii: "0") && bytes[1] <= UInt8(ascii: "9"),
      (UInt8(ascii: "a")...UInt8(ascii: "i")).contains(bytes[2]),
      bytes[3] >= UInt8(ascii: "0") && bytes[3] <= UInt8(ascii: "9"),
      let move = XiangqiCoreVariationMove(
        from: (bytes[1] - UInt8(ascii: "0")) * 9 + (bytes[0] - UInt8(ascii: "a")),
        to: (bytes[3] - UInt8(ascii: "0")) * 9 + (bytes[2] - UInt8(ascii: "a"))
      )
    else {
      throw NativeXiangqiDocumentFormatError.field(field)
    }
    return move
  }

  private static func decodeV0Annotations(
    _ value: NativeXiangqiJSONValue,
    maximumNodeID: UInt32,
    cancellation: NativeXiangqiDocumentCancellation?
  ) throws -> [UInt32: String] {
    let object = try value.asObject(field: "annotations")
    guard object.count <= XiangqiCoreDocumentSnapshot.maximumNodes else {
      throw NativeXiangqiDocumentFormatError.resourceLimit("annotations")
    }
    var annotations: [UInt32: String] = [:]
    annotations.reserveCapacity(object.count)
    var totalBytes = 0
    for (index, keyValue) in object.enumerated() {
      if index.isMultiple(of: 32) {
        try checkCancellation(cancellation)
      }
      let (key, value) = keyValue
      guard let nodeID = UInt32(key), String(nodeID) == key, nodeID <= maximumNodeID else {
        throw NativeXiangqiDocumentFormatError.field("annotations.key")
      }
      let annotation = try value.asString(field: "annotations.value")
      guard annotation.utf8.count <= XiangqiCoreDocumentSnapshot.maximumAnnotationBytesPerNode
      else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("annotations.value")
      }
      totalBytes += annotation.utf8.count
      guard totalBytes <= NativeXiangqiDocumentFormatLimits.maximumTotalAnnotationBytes,
        annotations.updateValue(annotation, forKey: nodeID) == nil
      else {
        throw NativeXiangqiDocumentFormatError.resourceLimit("annotations")
      }
    }
    return annotations
  }

  private static func optionalUInt32(_ value: NativeXiangqiJSONValue, field: String) throws
    -> UInt32?
  {
    switch value {
    case .null:
      nil
    default:
      try value.asUInt32(field: field)
    }
  }

  private static func optionalMove(
    _ value: NativeXiangqiJSONValue,
    field: String
  ) throws -> XiangqiCoreVariationMove? {
    if case .null = value {
      return nil
    }
    let object = try value.asObject(field: field)
    try rejectUnexpectedKeys(object, allowed: ["from", "to"], field: field)
    let from = try required(object, "from", field: "\(field).from").asUInt32(field: "\(field).from")
    let to = try required(object, "to", field: "\(field).to").asUInt32(field: "\(field).to")
    guard from <= UInt32(UInt8.max), to <= UInt32(UInt8.max),
      let move = XiangqiCoreVariationMove(from: UInt8(from), to: UInt8(to))
    else {
      throw NativeXiangqiDocumentFormatError.field(field)
    }
    return move
  }

  private static func required(
    _ object: [String: NativeXiangqiJSONValue],
    _ key: String,
    field: String
  ) throws -> NativeXiangqiJSONValue {
    guard let value = object[key] else {
      throw NativeXiangqiDocumentFormatError.field(field)
    }
    return value
  }

  private static func rejectUnexpectedKeys(
    _ object: [String: NativeXiangqiJSONValue],
    allowed: Set<String>,
    field: String
  ) throws {
    guard object.keys.allSatisfy(allowed.contains) else {
      throw NativeXiangqiDocumentFormatError.field(field)
    }
  }

  private static func checkCancellation(_ cancellation: NativeXiangqiDocumentCancellation?) throws {
    try cancellation?.check()
    guard !Task.isCancelled else {
      throw NativeXiangqiDocumentFormatError.cancelled
    }
  }

  private static func recordSemanticWork(
    _ cancellation: NativeXiangqiDocumentCancellation?,
    workUnits: inout Int
  ) throws {
    workUnits += 1
    guard workUnits >= 32 else {
      return
    }
    workUnits = 0
    try checkCancellation(cancellation)
  }
}
