//! Strict, bounded parsing of individual UCI lines into typed values.
//!
//! Every numeric token is range-checked; malformed tokens make the affected
//! field nil or fail the whole line depending on the field. Unknown tokens are
//! ignored so engine output evolution cannot break the session.

import Foundation

enum PikafishUCI {
  /// Returns true when the token is a syntactically valid UCCI coordinate
  /// move: four ASCII characters, file a-i, rank 0-9, repeated for the target.
  static func isValidMoveToken(_ token: String) -> Bool {
    guard token.count == 4, token.allSatisfy(\.isASCII) else {
      return false
    }
    let scalars = Array(token.unicodeScalars)
    for (index, scalar) in scalars.enumerated() {
      let isFile = scalar.value >= 0x61 && scalar.value <= 0x69  // a-i
      let isRank = scalar.value >= 0x30 && scalar.value <= 0x39  // 0-9
      if index.isMultiple(of: 2) {
        if !isFile { return false }
      } else if !isRank {
        return false
      }
    }
    return scalars[0] != scalars[2] || scalars[1] != scalars[3]
  }

  /// Parses a bounded signed integer token. Rejects overflow and non-ASCII
  /// digits.
  static func parseBoundedInt(_ token: Substring, limit: Int) -> Int? {
    guard !token.isEmpty, token.utf8.count <= 18 else {
      return nil
    }
    let trimmed = token.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "-" || ($0 >= "0" && $0 <= "9") }),
      let value = Int(trimmed)
    else {
      return nil
    }
    guard abs(value) <= limit else {
      return nil
    }
    return value
  }

  /// Parses one `option name X type Y ...` line.
  static func parseOption(_ tokens: [Substring]) -> PikafishOption? {
    guard tokens.count >= 4, tokens[0] == "option", tokens[1] == "name" else {
      return nil
    }
    // The option name may contain spaces; find the `type` marker after it.
    guard let typeIndex = tokens.firstIndex(of: "type"), typeIndex > 2 else {
      return nil
    }
    let name = tokens[2..<typeIndex].joined(separator: " ")
    guard !name.isEmpty, name.utf8.count <= 256 else {
      return nil
    }
    let kindRaw = String(tokens[typeIndex + 1])
    let kind: PikafishOption.Kind
    switch kindRaw {
    case "check": kind = .check
    case "spin": kind = .spin
    case "combo": kind = .combo
    case "button": kind = .button
    case "string": kind = .string
    default: kind = .unknown
    }

    var defaultValue: String?
    var min: Int?
    var max: Int?
    var variables: [String] = []

    var index = typeIndex + 2
    while index < tokens.count {
      switch tokens[index] {
      case "default":
        if index + 1 < tokens.count {
          defaultValue = String(tokens[index + 1])
          index += 2
        } else {
          index += 1
        }
      case "min":
        if index + 1 < tokens.count,
          let value = parseBoundedInt(tokens[index + 1], limit: 1_000_000_000)
        {
          min = value
          index += 2
        } else {
          return nil
        }
      case "max":
        if index + 1 < tokens.count,
          let value = parseBoundedInt(tokens[index + 1], limit: 1_000_000_000)
        {
          max = value
          index += 2
        } else {
          return nil
        }
      case "var":
        guard index + 1 < tokens.count else {
          return nil
        }
        variables.append(String(tokens[index + 1]))
        index += 2
      default:
        // Unknown option tokens are ignored so newer engines stay compatible.
        index += 1
      }
    }
    if kind == .spin, min == nil || max == nil {
      return nil
    }
    return PikafishOption(
      name: name,
      kind: kind,
      defaultValue: defaultValue,
      min: min,
      max: max,
      variables: variables
    )
  }

  /// Parses one `info ...` line. Returns nil when no recognized field survived;
  /// individual malformed numbers make their field nil rather than failing the
  /// whole line, matching engine output tolerance.
  static func parseInfo(_ tokens: [Substring]) -> PikafishInfo? {
    guard tokens.first == "info" else {
      return nil
    }
    var depth: Int?
    var seldepth: Int?
    var multipv: Int?
    var score: PikafishScore?
    var nodes: Int?
    var nps: Int?
    var timeMilliseconds: Int?
    var hashfull: Int?
    var pv: [String] = []

    var index = 1
    let count = tokens.count
    while index < count {
      let token = tokens[index]
      switch token {
      case "depth":
        if index + 1 < count, let value = parseBoundedInt(tokens[index + 1], limit: 1_000_000) {
          depth = value
        }
        index += 2
      case "seldepth":
        if index + 1 < count, let value = parseBoundedInt(tokens[index + 1], limit: 1_000_000) {
          seldepth = value
        }
        index += 2
      case "multipv":
        if index + 1 < count, let value = parseBoundedInt(tokens[index + 1], limit: 1_000_000) {
          multipv = value
        }
        index += 2
      case "score":
        guard index + 2 < count else {
          index += 1
          continue
        }
        let unit = tokens[index + 1]
        let raw = tokens[index + 2]
        var bound: PikafishScoreBound?
        if index + 3 < count {
          switch tokens[index + 3] {
          case "lowerbound": bound = .lowerbound
          case "upperbound": bound = .upperbound
          default: bound = nil
          }
        }
        if unit == "cp", let value = parseBoundedInt(raw, limit: 2_000_000_000) {
          score = PikafishScore(kind: .centipawn(value), bound: bound)
        } else if unit == "mate", let value = parseBoundedInt(raw, limit: 1_000_000) {
          score = PikafishScore(kind: .mate(value), bound: bound)
        }
        index += 3 + (bound != nil ? 1 : 0)
      case "nodes":
        if index + 1 < count,
          let value = parseBoundedInt(tokens[index + 1], limit: 100_000_000_000_000)
        {
          nodes = value
        }
        index += 2
      case "nps":
        if index + 1 < count,
          let value = parseBoundedInt(tokens[index + 1], limit: 100_000_000_000_000)
        {
          nps = value
        }
        index += 2
      case "time":
        if index + 1 < count, let value = parseBoundedInt(tokens[index + 1], limit: 1_000_000_000) {
          timeMilliseconds = value
        }
        index += 2
      case "hashfull":
        if index + 1 < count, let value = parseBoundedInt(tokens[index + 1], limit: 1_000) {
          hashfull = value
        }
        index += 2
      case "pv":
        var pvIndex = index + 1
        while pvIndex < count, pv.count < PikafishLimits.maximumPVMoves {
          let moveToken = String(tokens[pvIndex])
          guard isValidMoveToken(moveToken) else {
            break
          }
          pv.append(moveToken)
          pvIndex += 1
        }
        index = count
      case "string":
        // Free-form engine text; ignored entirely.
        index = count
      default:
        index += 1
      }
    }

    if depth == nil, seldepth == nil, multipv == nil, score == nil, nodes == nil,
      nps == nil, timeMilliseconds == nil, hashfull == nil, pv.isEmpty
    {
      return nil
    }
    return PikafishInfo(
      depth: depth,
      seldepth: seldepth,
      multipv: multipv,
      score: score,
      nodes: nodes,
      nps: nps,
      timeMilliseconds: timeMilliseconds,
      hashfull: hashfull,
      pv: pv
    )
  }

  /// Parses one `bestmove ...` line. Returns nil when the line is not a
  /// bestmove; throws when the move token itself is malformed.
  static func parseBestMove(_ tokens: [Substring]) throws -> PikafishBestMove? {
    guard tokens.first == "bestmove" else {
      return nil
    }
    guard tokens.count >= 2 else {
      throw PikafishSessionError.malformedBestMove
    }
    let moveToken = String(tokens[1])
    if moveToken == "(none)" {
      var ponder: String?
      if tokens.count >= 4, tokens[2] == "ponder" {
        let ponderToken = String(tokens[3])
        guard isValidMoveToken(ponderToken) else {
          throw PikafishSessionError.illegalBestMove(ponderToken)
        }
        ponder = ponderToken
      }
      return PikafishBestMove(move: nil, ponder: ponder)
    }
    guard isValidMoveToken(moveToken) else {
      throw PikafishSessionError.illegalBestMove(moveToken)
    }
    var ponder: String?
    if tokens.count >= 4, tokens[2] == "ponder" {
      let ponderToken = String(tokens[3])
      guard isValidMoveToken(ponderToken) else {
        throw PikafishSessionError.illegalBestMove(ponderToken)
      }
      ponder = ponderToken
    }
    return PikafishBestMove(move: moveToken, ponder: ponder)
  }
}
