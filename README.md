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

`bun run ios` builds for a simulator. the iphone simulator has no picture in picture (see "what was tested"), so use it only for the screen and the scroll.

after a change to a swift file or to `app.json`, build again with `bun run ios:device`. `ios/` is generated and ignored: do not edit it.

## use it

1. paste the script. the frame at the top is the real picture that floats.
2. set the speed (words per minute) and the text size. play and restart work in the preview, so you can rehearse first.
3. tap "float the prompt". the floating window appears.
4. open the camera app and start to record. the prompt starts by itself after the "start after i leave the app" delay (default 10 s).
5. come back to the app and tap stop when you are done.

why the delay exists: ios pauses the floating window when the camera app opens (measured, see below). the timer presses play for you, so you do not have to touch the floating window while you record. with the delay off, tap the floating window and then tap play.

## how it works

- `modules/floating-prompter/ios/PrompterRenderer.swift` wraps the script with core text and draws each video frame: a 1200 x 400 strip (3:1) with two rows of 200 points.
- `modules/floating-prompter/ios/PrompterEngine.swift` owns one `CMTimebase`. the timebase is the only source of the scroll position. a 30 fps timer draws frames into an `AVSampleBufferDisplayLayer`, and an `AVPictureInPictureController` floats that layer. play, pause and skip from the floating window move the timebase.
- `modules/floating-prompter/ios/FloatingPrompterModule.swift` is the expo module: functions, two events (`onStateChange`, `onLog`) and the preview view.
- `App.tsx` is the one screen. `app.json` adds the `audio` background mode, which picture in picture needs.

three facts in the engine come from measurements on the iphone, not from documentation:

- the first `startPictureInPicture()` call after the controller is made gives no callback. the engine asks again every 0.5 s until ios answers. the second request worked every time.
- without real audio output, ios suspended the app when camera came to the front (22 s pause in a 30 s check). a silent audio loop fixed it (longest pause 0.04 s). with settings in front, the app stayed alive even without the loop.
- ios sends "pause" to the floating window when camera opens. a play request made later, with camera still in front, works.

## not built on purpose: auto-pause at [demo]

`[demo]` in a script is plain text today: it scrolls past like any other line. the auto-pause is left for the on-camera iteration. the sample script contains one `[demo]` line to test with.

where it goes:

- `PrompterRenderer.layout` is where the script becomes rows. record the row index of each `[demo]` line there (and decide whether to draw the marker).
- `PrompterEngine.tick` is where the position advances. when the position crosses a marker row, call `setPlaying(false)`. the floating window's play button, or the in-app play button, then continues.

## what was tested

real iphone (iphone 16 pro, ios 27.0.1, over the cable, driven from the terminal with `devicectl`, read through the app's `[prompter]` log lines). nobody looked at the phone screen during these checks.

- build, sign, install and launch of the development build: passed.
- picture in picture starts: ios reported "will start" and "started" (4 runs).
- camera in front for 45 s with the prompt floating: the app was not suspended (longest pause 0.04 s), the auto start pressed play after 10 s, 798 frames were drawn, and the script reached its end 25.7 s later (25 s script).
- settings in front for 20 s: the app stayed alive.
- return to the app: the engine reports the background time, the frames and the longest pause in the session log.

simulator (iphone 17 pro, ios 27.0, screenshots inspected):

- the screen in its idle, playing, end-of-script and editing (keyboard) states.
- the frame: two rows, scroll, edge fade, progress bar, three text sizes, speed change, play at the end starts again.
- `AVPictureInPictureController.isPictureInPictureSupported()` is false on this simulator, so the app shows "picture in picture is not available" there. no picture in picture check is possible on it.

also: `bun run typecheck` passes, and `bunx expo-doctor` passes 20 of 20 checks. eslint is not set up in this project.

## hardware-only checks (not done, need eyes and hands on the phone)

the logs prove that the app runs and draws frames behind camera. they do not prove what is on the glass. check these on the phone:

1. the floating window is visible on top of the camera app, in photo mode and in video mode.
2. the window stays visible and keeps scrolling after you press record. this is the most important one. the terminal cannot press record, so nothing here tested a recording.
3. the recorded clip has clean audio. the app plays a silent loop with `mixWithOthers`, and the effect of that on camera's audio was not tested.
4. the text is readable at arm's length in sizes s, m and l, and after a pinch to resize the window.
5. play, pause and the skip buttons work on the floating window while camera is in front.
6. the window can be dragged next to the front lens, and the swipe to hide it at the screen edge still works.

the session log at the bottom of the app shows what ios did. after a recording, come back to the app and read the "back in app after ..." line: a "longest pause" above 1 s means ios suspended the app during the recording.

known small things:

- the engine logs "display layer failed: operation interrupted" once, about 10 s after camera opens. it flushes the layer and continues. the cause is unknown.
- the dev client's floating gear button covers a part of the status pill at the top right. it exists only in development builds.

## terminal checks on the phone

launch with `-prompterAutostart YES` to float the saved script with no tap. the phone must be unlocked.

```bash
D=<device udid>            # xcrun devicectl list devices
xcrun devicectl device process launch --device $D --terminate-existing --console \
  --payload-url "exp+floating-teleprompter://expo-development-client/?url=http%3A%2F%2F<mac ip>%3A8097" \
  -- com.ramimaalouf.floatingteleprompter -prompterAutostart YES
xcrun devicectl device process launch --device $D com.apple.camera
```
