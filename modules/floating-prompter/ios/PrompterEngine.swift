import AVFoundation
import AVKit
import UIKit

// the view that holds the video layer. the in-app preview shows it, and
// picture in picture takes its content when the prompt floats.
final class PrompterHostView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

  var displayLayer: AVSampleBufferDisplayLayer {
    // swiftlint:disable:next force_cast
    layer as! AVSampleBufferDisplayLayer
  }
}

// owns the scroll position, the frame timer and the picture in picture controller.
// every method must run on the main thread.
//
// invariants:
// - the timebase is the only source of the scroll position. the timer mode lets it
//   run at rate 1. the voice mode keeps the rate at 0 and moves the time to the
//   row that ScriptFollower found.
// - frames are drawn only in tick()
// - "armed" means the audio session and the picture in picture controller are live
final class PrompterEngine: NSObject {
  static let shared = PrompterEngine()

  var onState: (([String: Any]) -> Void)?
  var onLog: ((String) -> Void)?

  lazy var hostView: PrompterHostView = {
    let view = PrompterHostView()
    view.backgroundColor = .black
    view.displayLayer.videoGravity = .resizeAspect
    view.displayLayer.controlTimebase = timebase
    return view
  }()

  private let renderer = PrompterRenderer()
  private let timebase: CMTimebase
  private var timer: DispatchSourceTimer?
  private var pip: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?
  private var observers: [NSObjectProtocol] = []

  // a silent loop. measured on an iphone: without real audio output, ios
  // suspends this app when the camera app comes to the front.
  private let audioEngine = AVAudioEngine()
  private let silencePlayer = AVAudioPlayerNode()
  private var silenceAttached = false

  // voice follow: the microphone and ScriptFollower move the scroll
  private let listener = SpeechListener()
  private var follower = ScriptFollower()
  private var voiceMode = false
  // feed words with debugHear, with no microphone (simulator and terminal checks)
  private var simulatedVoice = false
  // the microphone gives audio now. when it does not, the scroll runs on the timer.
  private var voiceLive = false
  private var listenStart: CFTimeInterval = 0
  private var heard = ""
  private var debugTranscript: [String] = []
  private var backgroundMicBuffers = 0

  private var wordsPerMinute: Double = 140
  // seconds between "the app left the front" and "the scroll starts". 0 is off.
  private var autoStartDelay: Double = 0
  private var autoStartToken: UUID?
  private var duration: Double = 0
  private var armed = false
  private var playing = false
  private var pipActive = false
  private var pendingStart = false
  private var startAttempts = 0
  // ios called a delegate method for the current start request
  private var startAnswered = false
  private var dirty = true
  private var lastRender: CFTimeInterval = 0
  private var lastFollow: CFTimeInterval = 0
  private var lastStateEmit: CFTimeInterval = 0

  // background run statistics. they show whether ios kept the app running
  // while another app (camera) was in front.
  private var backgroundStart: CFTimeInterval?
  private var backgroundFrames = 0
  private var backgroundLongestGap: CFTimeInterval = 0
  private var lastTick: CFTimeInterval = 0

  override private init() {
    var created: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &created
    )
    // swiftlint:disable:next force_unwrapping
    timebase = created!
    super.init()
    CMTimebaseSetTime(timebase, time: .zero)
    CMTimebaseSetRate(timebase, rate: 0)
  }

  // MARK: - public api

  var state: [String: Any] {
    [
      "armed": armed,
      "floating": pipActive,
      "playing": playing,
      "progress": progress,
      "duration": duration,
      "rowCount": renderer.rowCount,
      "wordCount": renderer.wordCount,
      "voice": voiceMode,
      "listening": playing && voiceMode && voiceLive,
      "heard": heard,
      "wordIndex": follower.cursor,
    ]
  }

  func configure(text: String, wordsPerMinute: Double, fontSize: Double, autoStartDelay: Double, voice: Bool) {
    let previousProgress = progress
    let voiceChanged = voice != voiceMode
    voiceMode = voice
    self.autoStartDelay = max(autoStartDelay, 0)
    self.wordsPerMinute = max(wordsPerMinute, 1)
    renderer.layout(text: text, fontSize: CGFloat(fontSize))
    duration = Double(renderer.wordCount) / self.wordsPerMinute * 60
    // keep the same place in the script when the speed or the size changes
    setTime(previousProgress * duration)
    follower.setScript(renderer.scriptWords, keepCursor: true)
    if voiceChanged {
      syncCursorToPosition()
      if armed || playing {
        // the microphone needs another audio category
        try? activateAudioSession()
      }
    }
    applyDrive()
    startTimerIfNeeded()
    observeAppIfNeeded()
    dirty = true
    pip?.invalidatePlaybackState()
    emitState()
  }

  func start() throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw PrompterError.unsupported
    }
    guard renderer.rowCount > 0 else {
      throw PrompterError.emptyScript
    }

    if !armed {
      try activateAudioSession()
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: hostView.displayLayer,
        playbackDelegate: self
      )
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      // the prompt also floats by itself when the user leaves the app
      controller.canStartPictureInPictureAutomaticallyFromInline = true
      pip = controller
      possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.startPendingIfPossible() }
      }
      armed = true
      log("armed: \(renderer.rowCount) rows, \(Int(duration)) s at \(Int(wordsPerMinute)) wpm")
    }

    dirty = true
    pendingStart = true
    startAnswered = false
    startPendingIfPossible()
    emitState()

    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      guard let self, self.pendingStart else { return }
      self.pendingStart = false
      let possible = self.pip?.isPictureInPicturePossible ?? false
      let active = UIApplication.shared.applicationState == .active
      self.log("error: picture in picture did not start in 4 s. possible: \(possible). app active: \(active)")
    }
  }

  func setPlaying(_ shouldPlay: Bool) {
    guard shouldPlay != playing else { return }
    if shouldPlay && (voiceMode ? follower.cursor >= renderer.wordCount : isAtEnd) {
      // play at the end starts the script again
      setTime(0)
      follower.moveCursor(to: 0)
    }
    if shouldPlay && voiceMode && !armed {
      // rehearsal in the app, before the prompt floats
      try? activateAudioSession()
    }
    playing = shouldPlay
    applyDrive()
    if !shouldPlay && !armed {
      stopSilence()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    dirty = true
    pip?.invalidatePlaybackState()
    emitState()
  }

  // simulator and terminal checks: words arrive as if the recognizer heard them
  func setSimulatedVoice(_ simulated: Bool) {
    simulatedVoice = simulated
    debugTranscript = []
    applyDrive()
  }

  func debugHear(_ text: String) {
    debugTranscript.append(contentsOf: ScriptFollower.normalizedWords(in: text))
    handleTranscript(debugTranscript)
  }

  func restart() {
    setTime(0)
    follower.moveCursor(to: 0)
    debugTranscript = []
    dirty = true
    pip?.invalidatePlaybackState()
    emitState()
  }

  func stop() {
    pendingStart = false
    autoStartToken = nil
    setPlaying(false)
    if pipActive {
      pip?.stopPictureInPicture()
    }
    possibleObservation = nil
    pip = nil
    pipActive = false
    if armed {
      armed = false
      stopSilence()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      log("stopped")
    }
    dirty = true
    emitState()
  }

  // MARK: - position

  private var currentTime: Double {
    let seconds = CMTimebaseGetTime(timebase).seconds
    return seconds.isFinite ? min(max(seconds, 0), duration) : 0
  }

  // the timebase keeps time in small steps, so compare with a small margin
  private var isAtEnd: Bool {
    currentTime >= duration - 0.05
  }

  private var progress: Double {
    duration > 0 ? currentTime / duration : 0
  }

  private func setTime(_ seconds: Double) {
    let clamped = min(max(seconds, 0), duration)
    CMTimebaseSetTime(timebase, time: CMTime(seconds: clamped, preferredTimescale: 60_000))
  }

  // MARK: - frames

  private func startTimerIfNeeded() {
    guard timer == nil else { return }
    let source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
    source.setEventHandler { [weak self] in self?.tick() }
    source.resume()
    timer = source
  }

  private func tick() {
    let now = CACurrentMediaTime()

    if backgroundStart != nil, lastTick > 0 {
      backgroundLongestGap = max(backgroundLongestGap, now - lastTick)
    }
    lastTick = now

    if playing && voiceMode {
      updateVoiceLive()
    }

    if playing && voiceMode && voiceLive {
      followVoice(elapsed: lastFollow > 0 ? now - lastFollow : 0.033)
      lastFollow = now
    } else if playing {
      lastFollow = 0
      dirty = true
      if isAtEnd {
        // the last row reached the top: hold there
        setPlaying(false)
        setTime(duration)
        log("reached the end of the script")
      }
    }

    // draw when something changed, and once a second so a new surface always gets a frame
    guard dirty || now - lastRender >= 1 else { return }
    render(now: now)

    if playing, now - lastStateEmit >= 0.25 {
      emitState()
    }
  }

  private func render(now: CFTimeInterval) {
    let displayLayer = hostView.displayLayer
    if displayLayer.status == .failed {
      log("display layer failed: \(displayLayer.error?.localizedDescription ?? "unknown"). flushing")
      displayLayer.flush()
    }

    let currentProgress = progress
    guard
      let sampleBuffer = renderer.makeSampleBuffer(
        offset: CGFloat(currentProgress) * renderer.maxOffset,
        progress: CGFloat(currentProgress),
        readWords: voiceMode ? follower.cursor : nil,
        time: CMTimebaseGetTime(timebase)
      )
    else { return }

    displayLayer.enqueue(sampleBuffer)
    dirty = false
    lastRender = now
    if backgroundStart != nil {
      backgroundFrames += 1
    }
  }

  // MARK: - voice follow

  // one place decides who moves the scroll: the timer, the voice, or nothing
  private func applyDrive() {
    let wantListener = playing && voiceMode && !simulatedVoice
    if wantListener && !listener.running {
      startListening()
    } else if !wantListener && listener.running {
      listener.stop()
      log("stopped listening")
    }
    if !(playing && voiceMode) {
      voiceLive = false
    } else if simulatedVoice {
      voiceLive = true
    }
    let timerDrives = playing && !(voiceMode && voiceLive)
    CMTimebaseSetRate(timebase, rate: timerDrives ? 1 : 0)
  }

  private func startListening() {
    guard SpeechListener.microphoneGranted, SpeechListener.speechGranted else {
      log("error: allow the microphone and speech recognition to follow your voice")
      return
    }
    listener.onLog = { [weak self] message in self?.log(message) }
    listener.onTranscript = { [weak self] words in self?.handleTranscript(words) }
    do {
      try listener.start(hints: recognitionHints())
      listenStart = CACurrentMediaTime()
      voiceLive = true
    } catch {
      voiceLive = false
      log("error: listening did not start: \(error.localizedDescription)")
    }
  }

  // unusual words from the script. the recognizer prefers words that it gets as hints.
  private func recognitionHints() -> [String] {
    var seen = Set<String>()
    var hints: [String] = []
    for word in renderer.scriptWords {
      let trimmed = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
      guard trimmed.count >= 6, seen.insert(trimmed.lowercased()).inserted else { continue }
      hints.append(trimmed)
      if hints.count == 100 { break }
    }
    return hints
  }

  // the microphone can stop while the listener runs, for example when another
  // app takes it. then the timer moves the scroll, so the prompt never freezes.
  private func updateVoiceLive() {
    guard !simulatedVoice else { return }
    let now = CACurrentMediaTime()
    let live = listener.running && (listener.secondsSinceAudio < 2 || now - listenStart < 2)
    guard live != voiceLive else { return }
    voiceLive = live
    if live {
      syncCursorToPosition()
      log("the microphone gives audio again: the scroll follows your voice")
    } else {
      log("the microphone gives no audio: the scroll runs on the timer")
      if !listener.running || listener.secondsSinceAudio > 5 {
        // try to get the microphone back
        listener.stop()
        startListening()
        voiceLive = false
      }
    }
    applyDrive()
    emitState()
  }

  private func handleTranscript(_ words: [String]) {
    guard playing, voiceMode else { return }
    let moved = follower.hear(words)
    let newHeard = words.suffix(4).joined(separator: " ")
    if moved {
      dirty = true
      if follower.cursor >= renderer.wordCount {
        log("reached the end of the script")
      }
    }
    if moved || newHeard != heard {
      heard = newHeard
      emitState()
    }
  }

  // the row with the next word goes to the top row, and the row after it shows below.
  // the target looks one word ahead, because the recognizer is a little late.
  private func followVoice(elapsed: CFTimeInterval) {
    guard renderer.maxOffset > 0, duration > 0 else { return }
    let lookAhead = min(follower.cursor + 1, max(renderer.wordCount - 1, 0))
    let targetOffset = CGFloat(renderer.row(ofWord: lookAhead)) * PrompterRenderer.rowHeight
    let targetTime = Double(targetOffset / renderer.maxOffset) * duration
    let difference = targetTime - currentTime
    guard abs(difference) > 0.0001 else { return }
    // ease to the target: fast at first, soft at the end. snap when it is near,
    // so the engine stops drawing new frames.
    let step = difference * (1 - exp(-elapsed * 9))
    setTime(abs(difference) < 0.004 ? targetTime : currentTime + step)
    dirty = true
  }

  // after a change of mode or a seek, the cursor starts at the row on screen
  private func syncCursorToPosition() {
    let row = Int((CGFloat(progress) * renderer.maxOffset / PrompterRenderer.rowHeight).rounded())
    follower.moveCursor(to: renderer.firstWord(ofRow: row))
    debugTranscript = []
  }

  // MARK: - picture in picture

  private func startPendingIfPossible() {
    guard pendingStart, let pip, pip.isPictureInPicturePossible else { return }
    guard UIApplication.shared.applicationState == .active else { return }
    pendingStart = false
    startAttempts = 0
    attemptStart()
  }

  // measured on an iphone 16 pro with ios 27.0.1: the first start call after the
  // controller is made gives no callback at all, and a later call works.
  // so ask again until ios answers.
  private func attemptStart() {
    guard armed, let pip, !pipActive, !startAnswered else { return }
    guard startAttempts < 10 else {
      log("error: ios did not answer 10 requests to start picture in picture")
      return
    }
    startAttempts += 1
    log("asking ios to start picture in picture (\(startAttempts))")
    pip.startPictureInPicture()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.attemptStart()
    }
  }

  private func activateAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    // playback is required for picture in picture. mixWithOthers asks ios not to
    // treat this app as the owner of audio, so other apps keep their audio.
    if voiceMode && !simulatedVoice {
      try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
    } else {
      try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
    }
    try session.setActive(true)
    startSilence()
  }

  private func startSilence() {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)
    else { return }
    buffer.frameLength = buffer.frameCapacity

    if !silenceAttached {
      audioEngine.attach(silencePlayer)
      audioEngine.connect(silencePlayer, to: audioEngine.mainMixerNode, format: format)
      silenceAttached = true
    }
    do {
      if !audioEngine.isRunning {
        try audioEngine.start()
      }
      silencePlayer.stop()
      silencePlayer.scheduleBuffer(buffer, at: nil, options: .loops)
      silencePlayer.play()
    } catch {
      log("error: silent audio did not start: \(error.localizedDescription)")
    }
  }

  private func stopSilence() {
    silencePlayer.stop()
    audioEngine.stop()
  }

  // MARK: - app and audio events

  private func observeAppIfNeeded() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default

    observers.append(
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
        [weak self] _ in
        guard let self else { return }
        self.backgroundStart = CACurrentMediaTime()
        self.backgroundFrames = 0
        self.backgroundLongestGap = 0
        self.lastTick = 0
        self.log("app in background. floating: \(self.pipActive)")

        // measured on an iphone: ios pauses the floating window when the camera app
        // opens, and a play request made later from here works. so start the scroll
        // from a timer, and the user does not have to touch the floating window.
        // the voice mode has nothing to wait for: it listens again after 1 s.
        self.backgroundMicBuffers = self.listener.buffersHeard
        let delay = self.voiceMode ? 1 : self.autoStartDelay
        if self.pipActive, delay > 0 {
          let token = UUID()
          self.autoStartToken = token
          DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.autoStartToken == token, self.backgroundStart != nil, self.pipActive else { return }
            self.log("auto start: play")
            self.setPlaying(true)
          }
        }
      })

    observers.append(
      center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
        [weak self] _ in
        guard let self, let start = self.backgroundStart else { return }
        self.autoStartToken = nil
        let now = CACurrentMediaTime()
        // a gap between the last tick and now means ios suspended the app
        let longestGap = max(self.backgroundLongestGap, self.lastTick > 0 ? now - self.lastTick : now - start)
        self.backgroundStart = nil
        self.log(
          String(
            format: "back in app after %.0f s. frames drawn: %d. longest pause: %.2f s",
            now - start, self.backgroundFrames, longestGap
          ))
        if self.voiceMode {
          self.log("microphone buffers while away: \(self.listener.buffersHeard - self.backgroundMicBuffers)")
        }
        self.dirty = true
        self.emitState()
      })

    observers.append(
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
        [weak self] notification in
        guard let self,
          let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
          self.log("audio session interrupted")
        case .ended:
          self.log("audio session interruption ended")
          if self.armed {
            try? AVAudioSession.sharedInstance().setActive(true)
            self.startSilence()
            if self.listener.running {
              self.listener.stop()
            }
            self.applyDrive()
          }
        @unknown default:
          break
        }
      })
  }

  private func emitState() {
    lastStateEmit = CACurrentMediaTime()
    onState?(state)
  }

  private func log(_ message: String) {
    NSLog("[prompter] %@", message)
    onLog?(message)
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PrompterEngine: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
    startAnswered = true
    log("picture in picture will start")
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    pipActive = true
    dirty = true
    log("picture in picture started")
    emitState()
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    pipActive = false
    dirty = true
    log("picture in picture stopped")
    emitState()
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    pipActive = false
    startAnswered = true
    log("error: picture in picture failed to start: \(error.localizedDescription)")
    emitState()
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PrompterEngine: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    // ios calls this for a tap on the floating window, and also by itself
    // (measured: it sends "pause" when the camera app opens)
    let appState = UIApplication.shared.applicationState == .active ? "front" : "background"
    log("floating window asked to \(playing ? "play" : "pause") (app in \(appState))")
    setPlaying(playing)
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: CMTime(seconds: max(duration, 0.1), preferredTimescale: 600))
  }

  func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    !playing
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    if voiceMode {
      // the skip buttons move one row
      let row = renderer.row(ofWord: min(follower.cursor, max(renderer.wordCount - 1, 0)))
      follower.moveCursor(to: renderer.firstWord(ofRow: row + (skipInterval.seconds < 0 ? -1 : 1)))
      debugTranscript = []
    } else {
      setTime(currentTime + skipInterval.seconds)
    }
    dirty = true
    emitState()
    completionHandler()
  }
}

enum PrompterError: LocalizedError {
  case unsupported
  case emptyScript

  var errorDescription: String? {
    switch self {
    case .unsupported:
      return "Picture in Picture is not available on this device."
    case .emptyScript:
      return "Paste a script first."
    }
  }
}
