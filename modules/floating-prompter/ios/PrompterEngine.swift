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
// - the timebase is the only source of the scroll position
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
    ]
  }

  func configure(text: String, wordsPerMinute: Double, fontSize: Double, autoStartDelay: Double) {
    let previousProgress = progress
    self.autoStartDelay = max(autoStartDelay, 0)
    self.wordsPerMinute = max(wordsPerMinute, 1)
    renderer.layout(text: text, fontSize: CGFloat(fontSize))
    duration = Double(renderer.wordCount) / self.wordsPerMinute * 60
    // keep the same place in the script when the speed or the size changes
    setTime(previousProgress * duration)
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
    if shouldPlay && isAtEnd {
      // play at the end starts the script again
      setTime(0)
    }
    playing = shouldPlay
    CMTimebaseSetRate(timebase, rate: shouldPlay ? 1 : 0)
    dirty = true
    pip?.invalidatePlaybackState()
    emitState()
  }

  func restart() {
    setTime(0)
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

  // the timebase keeps time in 1/600 s steps, so compare with a small margin
  private var isAtEnd: Bool {
    currentTime >= duration - 0.05
  }

  private var progress: Double {
    duration > 0 ? currentTime / duration : 0
  }

  private func setTime(_ seconds: Double) {
    let clamped = min(max(seconds, 0), duration)
    CMTimebaseSetTime(timebase, time: CMTime(seconds: clamped, preferredTimescale: 600))
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

    if playing {
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
    try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
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
        if self.pipActive, self.autoStartDelay > 0 {
          let token = UUID()
          self.autoStartToken = token
          DispatchQueue.main.asyncAfter(deadline: .now() + self.autoStartDelay) { [weak self] in
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
    setTime(currentTime + skipInterval.seconds)
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
