import AVKit
import ExpoModulesCore

struct PrompterConfig: Record {
  @Field var text: String = ""
  @Field var wordsPerMinute: Double = 140
  @Field var fontSize: Double = 120
  @Field var autoStartDelay: Double = 0
}

private let draftKey = "prompter.draft"

public class FloatingPrompterModule: Module {
  public func definition() -> ModuleDefinition {
    Name("FloatingPrompter")

    Events("onStateChange", "onLog")

    OnCreate { [weak self] in
      let engine = PrompterEngine.shared
      engine.onState = { [weak self] state in
        self?.sendEvent("onStateChange", state)
      }
      engine.onLog = { [weak self] message in
        self?.sendEvent("onLog", ["message": message])
      }
    }

    Function("isSupported") {
      AVPictureInPictureController.isPictureInPictureSupported()
    }

    // launch with "-prompterAutostart YES" to float the saved script with no tap.
    // this is for checks from a terminal on a real iphone.
    Function("shouldAutostart") {
      UserDefaults.standard.bool(forKey: "prompterAutostart")
    }

    Function("loadDraft") {
      UserDefaults.standard.string(forKey: draftKey)
    }

    Function("saveDraft") { (text: String) in
      UserDefaults.standard.set(text, forKey: draftKey)
    }

    AsyncFunction("configure") { (config: PrompterConfig) in
      PrompterEngine.shared.configure(
        text: config.text,
        wordsPerMinute: config.wordsPerMinute,
        fontSize: config.fontSize,
        autoStartDelay: config.autoStartDelay
      )
    }.runOnQueue(.main)

    AsyncFunction("start") {
      try PrompterEngine.shared.start()
    }.runOnQueue(.main)

    AsyncFunction("setPlaying") { (playing: Bool) in
      PrompterEngine.shared.setPlaying(playing)
    }.runOnQueue(.main)

    AsyncFunction("restart") {
      PrompterEngine.shared.restart()
    }.runOnQueue(.main)

    AsyncFunction("stop") {
      PrompterEngine.shared.stop()
    }.runOnQueue(.main)

    AsyncFunction("getState") {
      PrompterEngine.shared.state
    }.runOnQueue(.main)

    View(PrompterPreviewView.self) {}
  }
}

// shows the same video layer that floats, so the preview is the real picture
final class PrompterPreviewView: ExpoView {
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    let hostView = PrompterEngine.shared.hostView
    hostView.removeFromSuperview()
    addSubview(hostView)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    PrompterEngine.shared.hostView.frame = bounds
  }
}
