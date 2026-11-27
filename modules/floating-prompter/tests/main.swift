import Foundation

// plain swift test for ScriptFollower. run: bun run test:follower

let script = """
This prompt floats on top of every app on my iPhone.
I pasted my script, and I started Picture in Picture. Then I opened the Camera app.
The words scroll next to the lens, so I look at you and not at my notes.
[demo]
It is one Expo app with one small Swift module. That is the whole trick.
"""
let scriptWords = script.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)

var failures = 0
func check(_ name: String, _ actual: Int, _ expected: Int) {
  if actual == expected {
    print("ok    \(name)")
  } else {
    failures += 1
    print("FAIL  \(name): cursor \(actual), expected \(expected)")
  }
}

// feeds a transcript one word at a time, the way partial results grow
func speak(_ follower: inout ScriptFollower, _ text: String, transcript: inout [String]) {
  for word in ScriptFollower.normalizedWords(in: text) {
    transcript.append(word)
    follower.hear(transcript)
    follower.hear(transcript)  // recognizers repeat partial results
  }
}

func index(of word: String, occurrence: Int = 1) -> Int {
  var seen = 0
  for (position, candidate) in scriptWords.enumerated() where ScriptFollower.normalize(candidate) == word {
    seen += 1
    if seen == occurrence { return position }
  }
  fatalError("no word \(word)")
}

// 1. a clean read moves the cursor word by word
do {
  var follower = ScriptFollower()
  follower.setScript(scriptWords, keepCursor: false)
  var transcript: [String] = []
  speak(&follower, "This prompt floats on top of every app on my iPhone", transcript: &transcript)
  check("clean read", follower.cursor, index(of: "iphone") + 1)
}

// 2. the speaker repeats a section: the cursor goes back with the speaker
do {
  var follower = ScriptFollower()
  follower.setScript(scriptWords, keepCursor: false)
  var transcript: [String] = []
  speak(&follower, "This prompt floats on top of every app on my iPhone I pasted my script and I started Picture in Picture", transcript: &transcript)
  check("before the repeat", follower.cursor, index(of: "picture", occurrence: 2) + 1)
  speak(&follower, "I pasted my", transcript: &transcript)
  check("back after 3 repeated words", follower.cursor, index(of: "my", occurrence: 2) + 1)
  speak(&follower, "script and I started", transcript: &transcript)
  check("continues after the repeat", follower.cursor, index(of: "started") + 1)
}

// 3. a repeat after a pause arrives as a new, short transcript
do {
  var follower = ScriptFollower()
  follower.setScript(scriptWords, keepCursor: false)
  var transcript: [String] = []
  speak(&follower, "This prompt floats on top of every app on my iPhone I pasted my script", transcript: &transcript)
  transcript = []
  speak(&follower, "This prompt floats", transcript: &transcript)
  check("back to the start in a new transcript", follower.cursor, index(of: "floats") + 1)
}

// 4. words that are not in the script do not move the cursor
do {
  var follower = ScriptFollower()
  follower.setScript(scriptWords, keepCursor: false)
  var transcript: [String] = []
  speak(&follower, "This prompt floats on top", transcript: &transcript)
  let before = follower.cursor
  speak(&follower, "um okay so basically what happened yesterday", transcript: &transcript)
  check("ad lib does not move", follower.cursor, before)
  speak(&follower, "of every app", transcript: &transcript)
  check("continues after the ad lib", follower.cursor, index(of: "app") + 1)
}

// 5. the speaker skips words, and the [demo] marker is never spoken
do {
  var follower = ScriptFollower()
  follower.setScript(scriptWords, keepCursor: false)
  var transcript: [String] = []
  speak(&follower, "The words scroll next to the lens so I look at you and not at my notes", transcript: &transcript)
  check("long jump forward", follower.cursor, index(of: "notes") + 1)
  speak(&follower, "It is one Expo app", transcript: &transcript)
  check("passes the demo marker", follower.cursor, index(of: "app", occurrence: 3) + 1)
}

// 6. wrong words from the recognizer
do {
  var follower = ScriptFollower()
  follower.setScript(scriptWords, keepCursor: false)
  var transcript: [String] = []
  speak(&follower, "This prompt float on top of every apps on my iPhone", transcript: &transcript)
  check("misheard words", follower.cursor, index(of: "iphone") + 1)
}

// 7. one common word does not cause a jump
do {
  var follower = ScriptFollower()
  follower.setScript(scriptWords, keepCursor: false)
  var transcript: [String] = []
  speak(&follower, "This prompt floats on top of every app on my iPhone", transcript: &transcript)
  let before = follower.cursor
  speak(&follower, "the the on", transcript: &transcript)
  check("single common words", follower.cursor, before)
}

print(failures == 0 ? "all follower tests passed" : "\(failures) follower tests failed")
exit(failures == 0 ? 0 : 1)
