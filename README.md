# floating teleprompter

an iphone app for the grok bot / expo showcase. paste a script, float it in a native picture in picture window that shows two short scrolling lines, then open apple's camera app and record a talking-head clip. the prompt is not in the clip, because the camera app records the camera and not the screen.

it is an expo development build (sdk 58) with one local swift module. it does not run in expo go.

## run it

```bash
cd demos/floating-teleprompter
bun install
bun run ios:device     # build, sign and install on the connected iphone, then start metro on port 8097
```

the app is already installed on rami's iphone 16 pro (bundle id `com.ramimaalouf.floatingteleprompter`, signed with the "apple development: rami maalouf" identity). if the app is installed and only the javascript changed, start metro alone:

```bash
bun run start          # metro on port 8097, dev client mode
```

then open the app on the phone. the phone and the mac must be on the same network. the port is 8097 because the sibling demo `pocket-soundboard` uses 8088.

since 2026-11-27 the phone has a release build. it holds its own javascript, so it runs with no mac and no metro, and it has no dev gear button. to put a new release build on the phone:

```bash
bun run ios:release    # build the release configuration and install it on the connected iphone
```

`bun run ios:device` puts the development build back (same app, it replaces the release build).

`bun run ios` builds for a simulator. the iphone simulator has no picture in picture (see "what was tested"), so use it only for the screen and the scroll.

after a change to a swift file or to `app.json`, build again with `bun run ios:device`. `ios/` is generated and ignored: do not edit it.

## use it

1. tap the script card. a bottom sheet opens with the editor. paste, clear or type, then tap done. the frame above the sheet shows each change.
2. turn "follow my voice" on or off. the first time you turn it on, ios asks for the microphone and for speech recognition. allow both.
3. set the text size. with the voice off, also set the speed and the start delay. the two round buttons under the frame are restart and play, so you can rehearse first.
4. tap "float the prompt". the floating window appears.
5. open the camera app and start to record.
   - voice on: read. the prompt moves when you speak and waits when you stop.
   - voice off: the prompt starts by itself after the start delay (default 10 s).
6. come back to the app and tap stop when you are done.

"session log" at the bottom opens a sheet with what ios did. it is for checks on a real phone.

## the screen

the screen was made simpler on 2026-11-27. each part was kept, moved or removed for a reason:

- the frame: kept, and it is the focal point. it is the real picture that floats.
- the caption under the frame, the status pill, and the "listening" card: removed. one status line under the frame replaces the three.
- play and restart: kept as two round glass buttons next to the status line. stop shows only while the prompt is armed.
- the script field: moved to a bottom sheet (expo router `formSheet`, detents 62% and 100%). the main screen shows a two-line excerpt and the word count.
- "the scroll follows: my voice / a timer": now one switch, "follow my voice".
- speed and start delay: shown only with the voice off, because only the timer uses them.
- the window type (call / video): removed from the screen. the video type disappears over camera, so the call type is the only one in use. the native code keeps both, and `-prompterVideoWindow` is no longer read by the screen.
- the session log: moved to a sheet behind one low-emphasis link.

buttons, cards and sheets use liquid glass (`expo-glass-effect`, ios 26 and later). on an older ios they are plain dark surfaces. the switch is the system switch. icons are sf symbols (`expo-symbols`).

files: `src/app/index.tsx` (main screen), `src/app/script.tsx` and `src/app/log.tsx` (sheets), `src/app/_layout.tsx` (stack), `src/components/` (glass and controls), `src/store.ts` (the settings both screens share).

## floating window type

rami saw on the phone that the first window type (a video-player window) disappears when camera opens. the app now has two types, under "floating window type":

- call (default): a video-call window (`AVPictureInPictureVideoCallViewController`). ios does not treat it as media playback. it has no play button, and ios sends it no "pause". the timer delay or the voice starts the scroll.
- video: the video-player window with play, pause and skip buttons. this is the type that disappeared over camera.

iphone log, call type, camera in front for 25 s: the window started, ios sent no stop, and the "display layer failed: operation interrupted" line that the video type logged about 10 s after camera opened did not occur. this is a good sign, not proof: nobody looked at the screen. other app store apps state that their floating prompt stays on top of the built-in camera app, so ios permits it in some form.

## voice follow

the app listens with on-device speech recognition and finds your place in the script from the last 6 words it heard.

- the row with your next word is the top row. the next row shows below it. the words you said are dim.
- say a section again, and the prompt goes back with you. a jump back of up to 60 words needs 3 words in a row that match. a jump to a place farther away needs 4.
- skip a part, and the prompt jumps forward by the same rules. 1 or 2 matching words are enough for the next 10 words.
- words that are not in the script (an ad lib) do not move the prompt.
- a wrong word from the recognizer inside a run is allowed, and "app" matches "apps".
- if the microphone gives no audio for 2 s (for example, another app takes it), the scroll runs on the timer at the speed you set. when audio comes back, it follows your voice again. the prompt does not freeze.
- the skip buttons on the floating window move one row.
- the recognizer is set to english (en-US).

why the timer delay exists: ios pauses the floating window when the camera app opens (measured, see below). the timer presses play for you, so you do not have to touch the floating window while you record. with the delay off, tap the floating window and then tap play.

## how it works

- `modules/floating-prompter/ios/PrompterRenderer.swift` wraps the script with core text and draws each video frame: a 1200 x 400 strip (3:1) with two rows of 200 points.
- `modules/floating-prompter/ios/PrompterEngine.swift` owns one `CMTimebase`. the timebase is the only source of the scroll position. a 30 fps timer draws frames into an `AVSampleBufferDisplayLayer`, and an `AVPictureInPictureController` floats that layer. play, pause and skip from the floating window move the timebase.
- `modules/floating-prompter/ios/SpeechListener.swift` turns the microphone into words (`SFSpeechRecognizer`, on-device when the phone supports it). it knows nothing about the script.
- `modules/floating-prompter/ios/ScriptFollower.swift` finds the place in the script from the heard words. it has no audio and no ui, so `bun run test:follower` runs it on the mac. in the voice mode the engine keeps the timebase at rate 0 and moves its time to the row that the follower found.
- `modules/floating-prompter/ios/FloatingPrompterModule.swift` is the expo module: functions, two events (`onStateChange`, `onLog`) and the preview view.
- `src/app/` holds the main screen and two sheets (expo router). `app.json` adds the `audio` background mode, which picture in picture needs.

three facts in the engine come from measurements on the iphone, not from documentation:

- the first `startPictureInPicture()` call after the controller is made gives no callback. the engine asks again every 0.5 s until ios answers. the second request worked every time.
- without real audio output, ios suspended the app when camera came to the front (22 s pause in a 30 s check). a silent audio loop fixed it (longest pause 0.04 s). with settings in front, the app stayed alive even without the loop.
- ios sends "pause" to the floating window when camera opens. a play request made later, with camera still in front, works.

## not built on purpose: auto-pause at [demo]

`[demo]` in a script is plain text today: it scrolls past like any other line. the auto-pause is left for the on-camera iteration. the sample script contains one `[demo]` line to test with.

where it goes:

- `PrompterRenderer.layout` is where the script becomes rows. record the row index of each `[demo]` line there (and decide whether to draw the marker).
- `PrompterEngine.tick` is where the position advances. when the position crosses a marker row, call `setPlaying(false)`. the floating window's play button, or the in-app play button, then continues.
- in the voice mode, `PrompterEngine.handleTranscript` is where the cursor moves: stop there when the cursor reaches a marker word. nobody says "[demo]" aloud, so the follower passes it when it hears the words after it.

## what was tested

real iphone (iphone 16 pro, ios 27.0.1, over the cable, driven from the terminal with `devicectl`, read through the app's `[prompter]` log lines). nobody looked at the phone screen during these checks.

- build, sign, install and launch of the development build: passed.
- picture in picture starts: ios reported "will start" and "started" (4 runs).
- camera in front for 45 s with the prompt floating: the app was not suspended (longest pause 0.04 s), the auto start pressed play after 10 s, 798 frames were drawn, and the script reached its end 25.7 s later (25 s script).
- settings in front for 20 s: the app stayed alive.
- voice follow with simulated words (`-prompterSimulateVoice YES`, no microphone) behind camera for 22 s: ios paused the window, the engine continued after 1 s, the app was not suspended (longest pause 0.06 s).
- real microphone, after rami allowed the permissions: with camera in front for 20 s (not recording), the listener started with on-device recognition and the microphone gave 189 buffers. nobody spoke, so the follow itself is still not tested with a voice.
- return to the app: the engine reports the background time, the frames and the longest pause in the session log.

simulator (iphone 17 pro, ios 27.0, screenshots inspected):

- the screen in its idle, playing, end-of-script and editing (keyboard) states.
- the frame: two rows, scroll, edge fade, progress bar, three text sizes, speed change, play at the end starts again.
- voice follow with simulated words: a read with one repeated section. the scroll followed, the said words were dim, and the read ended on the correct row. the frame at the moment of the jump back is not in a screenshot.
- `AVPictureInPictureController.isPictureInPictureSupported()` is false on this simulator, so the app shows "picture in picture is not available" there. no picture in picture check is possible on it.

mac: `bun run test:follower` passes 11 checks: a clean read, a repeated section (back after 3 words), a repeat in a new transcript, an ad lib, a long jump forward, the `[demo]` marker, wrong words, and single common words.

also: `bun run typecheck` passes, and `bunx expo-doctor` passes 20 of 20 checks. eslint is not set up in this project.

## hardware-only checks (not done, need eyes and hands on the phone)

the logs prove that the app runs and draws frames behind camera. they do not prove what is on the glass. check these on the phone:

1. the floating window is visible on top of the camera app, in photo mode and in video mode. check the call type first. the video type failed this check on rami's phone.
2. the window stays visible and keeps scrolling after you press record. this is the most important one. the terminal cannot press record, so nothing here tested a recording.
3. the recorded clip has clean audio. the app plays a silent loop with `mixWithOthers`, and the effect of that on camera's audio was not tested.
4. the text is readable at arm's length in sizes s, m and l, and after a pinch to resize the window.
5. play, pause and the skip buttons work on the floating window while camera is in front.
6. the window can be dragged next to the front lens, and the swipe to hide it at the screen edge still works.

voice follow, none of it tested with a real voice:

7. choose "my voice" and allow both permissions. tap play in the app and read: the card shows "listening" and your last words, and the prompt follows.
8. the picture in picture window still starts in the voice mode. the voice mode uses another audio category (`playAndRecord`), and that combination was not tested.
9. the prompt follows your voice with camera in front, before you record.
10. the prompt follows your voice while camera records. this is the main risk: camera uses the microphone to record, and ios can take it from this app. if the card or the log says "the microphone gives no audio: the scroll runs on the timer", ios took it, and the voice follow cannot work with apple's camera app in this form.
11. the clip's audio is clean while this app listens.
12. back in the app, the log line "microphone buffers while away" is above 0.

the session log at the bottom of the app shows what ios did. after a recording, come back to the app and read the "back in app after ..." line: a "longest pause" above 1 s means ios suspended the app during the recording.

known small things:

- the engine logs "display layer failed: operation interrupted" once, about 10 s after camera opens. it flushes the layer and continues. the cause is unknown.
- the dev client's floating gear button sits at the top right. no control is under it. it exists only in development builds.

## terminal checks on the phone

launch with `-prompterAutostart YES` to float the saved script with no tap. add `-prompterSimulateVoice YES` to run the voice follow with a built-in read (one repeated section) and no microphone. the phone must be unlocked.

```bash
D=<device udid>            # xcrun devicectl list devices
xcrun devicectl device process launch --device $D --terminate-existing --console \
  --payload-url "exp+floating-teleprompter://expo-development-client/?url=http%3A%2F%2F<mac ip>%3A8097" \
  -- com.ramimaalouf.floatingteleprompter -prompterAutostart YES
xcrun devicectl device process launch --device $D com.apple.camera
```
