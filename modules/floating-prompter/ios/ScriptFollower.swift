import Foundation

// finds the place in the script that the speaker is at, from the last words
// that the speech recognizer heard. it has no audio and no ui, so it runs in
// a plain swift test on a mac (see tests/follower-test.swift).
//
// rules:
// - "cursor" is the index of the next word the speaker has to say
// - a move needs evidence: a run of heard words that match the script in order
// - a small step forward needs little evidence. a jump back (the speaker
//   repeats a section) or a long jump forward needs more.
// - when two places match equally well, the place nearest the cursor wins
struct ScriptFollower {
  private(set) var words: [String] = []
  private(set) var cursor = 0

  // how many heard words to compare
  static let tailLength = 6
  private static let nearForward = 10
  private static let middleDistance = 60

  static func normalize(_ word: String) -> String {
    String(
      word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    )
  }

  static func normalizedWords(in text: String) -> [String] {
    text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map { normalize(String($0)) }
  }

  // scriptWords must have one entry for each word on screen, in order
  mutating func setScript(_ scriptWords: [String], keepCursor: Bool) {
    words = scriptWords.map(Self.normalize)
    cursor = keepCursor ? min(cursor, words.count) : 0
  }

  mutating func moveCursor(to index: Int) {
    cursor = min(max(index, 0), words.count)
  }

  // heard: the normalized words of the transcript so far. only the end is used.
  // returns true when the cursor moved.
  @discardableResult
  mutating func hear(_ heard: [String]) -> Bool {
    let tail = Array(heard.filter { !$0.isEmpty }.suffix(Self.tailLength))
    guard !tail.isEmpty, !words.isEmpty else { return false }

    // "stay" is the place the cursor is at already: the last heard word is
    // the word before the cursor. recognizers repeat their partial results,
    // so this is the usual case.
    let stayIndex = cursor - 1
    var bestIndex = stayIndex
    var bestRun = stayIndex >= 0 ? run(endingAt: stayIndex, tail: tail) : 0
    var bestDistance = 0

    for index in words.indices where index != stayIndex {
      let matched = run(endingAt: index, tail: tail)
      guard matched >= evidenceNeeded(for: index) else { continue }
      let distance = abs(index - stayIndex)
      if matched > bestRun || (matched == bestRun && distance < bestDistance && bestIndex != stayIndex) {
        bestIndex = index
        bestRun = matched
        bestDistance = distance
      }
    }

    guard bestIndex != stayIndex else { return false }
    cursor = bestIndex + 1
    return true
  }

  private func evidenceNeeded(for index: Int) -> Int {
    let step = index - cursor
    if step == 0 { return 1 }
    if step > 0 && step < Self.nearForward { return 2 }
    if abs(step) <= Self.middleDistance { return 3 }
    return 4
  }

  // counts the heard words that match the script, from the end of the tail
  // backward, with the last heard word on script word "index". one wrong
  // word in the middle is allowed, because recognizers mishear words.
  private func run(endingAt index: Int, tail: [String]) -> Int {
    guard Self.matches(tail[tail.count - 1], words[index]) else { return 0 }
    var matched = 1
    var misses = 0
    var offset = 1
    while offset < tail.count, index - offset >= 0 {
      if Self.matches(tail[tail.count - 1 - offset], words[index - offset]) {
        matched += 1
      } else {
        misses += 1
        if misses > 1 { break }
      }
      offset += 1
    }
    // a run that ends in a miss has no evidence past the last match
    return matched
  }

  static func matches(_ heard: String, _ script: String) -> Bool {
    if heard.isEmpty || script.isEmpty { return false }
    if heard == script { return true }
    // "record" and "recording", "app" and "apps"
    let shorter = min(heard.count, script.count)
    if shorter >= 4 && (heard.hasPrefix(script) || script.hasPrefix(heard)) { return true }
    if shorter >= 5 && abs(heard.count - script.count) <= 1 {
      return editDistanceIsAtMostOne(Array(heard), Array(script))
    }
    return false
  }

  private static func editDistanceIsAtMostOne(_ a: [Character], _ b: [Character]) -> Bool {
    var i = 0
    var j = 0
    var edits = 0
    while i < a.count && j < b.count {
      if a[i] == b[j] {
        i += 1
        j += 1
        continue
      }
      edits += 1
      if edits > 1 { return false }
      if a.count > b.count {
        i += 1
      } else if b.count > a.count {
        j += 1
      } else {
        i += 1
        j += 1
      }
    }
    return edits + (a.count - i) + (b.count - j) <= 1
  }
}
