import AVFoundation
import Speech

// turns the microphone into words. it knows nothing about the script:
// the engine gives the words to ScriptFollower.
// start and stop must run on the main thread. callbacks arrive on the main thread.
final class SpeechListener {
  var onTranscript: (([String]) -> Void)?
  var onLog: ((String) -> Void)?

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private let audioEngine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var hints: [String] = []
  private var generation = 0
  private(set) var running = false

  // written on the audio thread, read on the main thread
  private let counterLock = NSLock()
  private var bufferCount = 0
  private var lastBufferTime: CFTimeInterval = 0

  static var microphoneGranted: Bool {
    AVAudioSession.sharedInstance().recordPermission == .granted
  }

  static var speechGranted: Bool {
    SFSpeechRecognizer.authorizationStatus() == .authorized
  }

  static func requestPermissions(completion: @escaping (_ microphone: Bool, _ speech: Bool) -> Void) {
    AVAudioSession.sharedInstance().requestRecordPermission { microphone in
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async {
          completion(microphone, status == .authorized)
        }
      }
    }
  }

  // seconds since the microphone gave audio. a large value means ios took the
  // microphone away (for example, another app started to record).
  var secondsSinceAudio: CFTimeInterval {
    counterLock.lock()
    defer { counterLock.unlock() }
    return lastBufferTime > 0 ? CACurrentMediaTime() - lastBufferTime : .infinity
  }

  var buffersHeard: Int {
    counterLock.lock()
    defer { counterLock.unlock() }
    return bufferCount
  }

  // hints: unusual words from the script, so the recognizer prefers them
  func start(hints: [String]) throws {
    guard let recognizer, recognizer.isAvailable else {
      throw ListenerError.recognizerUnavailable
    }
    stop()
    self.hints = hints

    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw ListenerError.noMicrophone
    }
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      self.counterLock.lock()
      self.bufferCount += 1
      self.lastBufferTime = CACurrentMediaTime()
      self.counterLock.unlock()
      self.request?.append(buffer)
    }
    audioEngine.prepare()
    try audioEngine.start()
    running = true
    startTask()
    onLog?("listening. on-device recognition: \(recognizer.supportsOnDeviceRecognition)")
  }

  func stop() {
    guard running else { return }
    running = false
    generation += 1
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
  }

  // a recognition task ends by itself after a long silence, on an error, or
  // at the time limit of server recognition. start the next one immediately.
  private func startTask() {
    guard running, let recognizer else { return }
    generation += 1
    let current = generation

    let newRequest = SFSpeechAudioBufferRecognitionRequest()
    newRequest.shouldReportPartialResults = true
    newRequest.taskHint = .dictation
    newRequest.addsPunctuation = false
    newRequest.contextualStrings = hints
    if recognizer.supportsOnDeviceRecognition {
      // audio stays on the phone, and there is no time limit
      newRequest.requiresOnDeviceRecognition = true
    }
    request = newRequest

    task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
      let words = result.map { ScriptFollower.normalizedWords(in: $0.bestTranscription.formattedString) }
      let finished = error != nil || (result?.isFinal ?? false)
      DispatchQueue.main.async {
        guard let self, self.running, self.generation == current else { return }
        if let words, !words.isEmpty {
          self.onTranscript?(words)
        }
        if finished {
          self.request?.endAudio()
          // a short wait, so an error that repeats does not make a tight loop
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == current else { return }
            self.startTask()
          }
        }
      }
    }
  }
}

enum ListenerError: LocalizedError {
  case recognizerUnavailable
  case noMicrophone

  var errorDescription: String? {
    switch self {
    case .recognizerUnavailable:
      return "Speech recognition is not available now."
    case .noMicrophone:
      return "The microphone gives no audio."
    }
  }
}
