import { useEvent, useEventListener } from 'expo';
import { StatusBar } from 'expo-status-bar';
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Keyboard,
  KeyboardAvoidingView,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';

import { FloatingPrompter, PrompterPreview, type PrompterState } from './modules/floating-prompter';
import { colors, radius, space } from './src/theme';

const SAMPLE_SCRIPT = `This prompt floats on top of every app on my iPhone.

I pasted my script, and I started Picture in Picture. Then I opened the Camera app.

The words scroll next to the lens, so I look at you and not at my notes.

[demo]

It is one Expo app with one small Swift module. That is the whole trick.`;

const SIZES = [
  { label: 'S', fontSize: 96 },
  { label: 'M', fontSize: 120 },
  { label: 'L', fontSize: 144 },
] as const;

// seconds between "the app left the front" and "the scroll starts"
const AUTO_STARTS = [
  { label: 'Off', seconds: 0 },
  { label: '5 s', seconds: 5 },
  { label: '10 s', seconds: 10 },
  { label: '15 s', seconds: 15 },
] as const;

const MIN_WPM = 80;
const MAX_WPM = 240;
const WPM_STEP = 10;

const IDLE_STATE: PrompterState = {
  armed: false,
  floating: false,
  playing: false,
  progress: 0,
  duration: 0,
  rowCount: 0,
  wordCount: 0,
  voice: false,
  listening: false,
  heard: '',
  wordIndex: 0,
};

// "-prompterSimulateVoice YES": a read with one repeated section, with no microphone.
// the speaker reads to "Picture in Picture", then says the second sentence again.
const SIMULATED_READ =
  'This prompt floats on top of every app on my iPhone I pasted my script and I started Picture in Picture ' +
  'I pasted my script and I started Picture in Picture Then I opened the Camera app';

function formatDuration(seconds: number) {
  const total = Math.round(seconds);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

export default function App() {
  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
      <PrompterScreen />
    </SafeAreaProvider>
  );
}

function PrompterScreen() {
  const [script, setScript] = useState(() => FloatingPrompter.loadDraft() ?? SAMPLE_SCRIPT);
  const [wordsPerMinute, setWordsPerMinute] = useState(140);
  const [fontSize, setFontSize] = useState<number>(SIZES[1].fontSize);
  const [autoStartDelay, setAutoStartDelay] = useState<number>(10);
  const [voice, setVoice] = useState(
    () => FloatingPrompter.voicePermissionsGranted() || FloatingPrompter.shouldSimulateVoice()
  );
  const [editing, setEditing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [logs, setLogs] = useState<string[]>([]);
  const [logOpen, setLogOpen] = useState(false);

  const state = useEvent(FloatingPrompter, 'onStateChange', IDLE_STATE);

  useEventListener(FloatingPrompter, 'onLog', ({ message }) => {
    setLogs((current) => [message, ...current].slice(0, 12));
    if (message.startsWith('error:')) {
      setError(message.replace('error: ', ''));
    }
  });

  // the native frame follows every change to the script, the speed and the size
  useEffect(() => {
    const handle = setTimeout(() => {
      FloatingPrompter.configure({ text: script, wordsPerMinute, fontSize, autoStartDelay, voice });
      FloatingPrompter.saveDraft(script);
    }, 150);
    return () => clearTimeout(handle);
  }, [script, wordsPerMinute, fontSize, autoStartDelay, voice]);

  // the voice mode needs the microphone and speech recognition
  // the window type. "-prompterVideoWindow YES" starts with the video type for terminal checks.
  const [callStyle, setCallStyle] = useState(() => !FloatingPrompter.shouldUseVideoWindow());
  const chooseCallStyle = useCallback(async (next: boolean) => {
    await FloatingPrompter.stop();
    setCallStyle(next);
  }, []);

  const chooseVoice = useCallback(async (next: boolean) => {
    setError(null);
    if (next && !FloatingPrompter.voicePermissionsGranted()) {
      const granted = await FloatingPrompter.requestVoicePermissions();
      if (!granted) {
        setError('Allow the microphone and speech recognition in Settings to follow your voice.');
        return;
      }
    }
    setVoice(next);
  }, []);

  // simulator and terminal checks: feed the words of a read, three words a second
  useEffect(() => {
    if (!FloatingPrompter.shouldSimulateVoice()) {
      return;
    }
    setScript(SAMPLE_SCRIPT);
    const words = SIMULATED_READ.split(' ');
    let index = 0;
    let interval: ReturnType<typeof setInterval> | undefined;
    const begin = setTimeout(async () => {
      await FloatingPrompter.setSimulatedVoice(true);
      await FloatingPrompter.restart();
      await FloatingPrompter.setPlaying(true);
      interval = setInterval(() => {
        if (index >= words.length) {
          clearInterval(interval);
          return;
        }
        FloatingPrompter.debugHear(words[index]);
        index += 1;
      }, 330);
    }, 2500);
    return () => {
      clearTimeout(begin);
      clearInterval(interval);
    };
  }, []);

  const float = useCallback(async () => {
    setError(null);
    Keyboard.dismiss();
    try {
      await FloatingPrompter.configure({ text: script, wordsPerMinute, fontSize, autoStartDelay, voice });
      await FloatingPrompter.setCallStyle(callStyle);
      await FloatingPrompter.start();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  }, [script, wordsPerMinute, fontSize, autoStartDelay, voice, callStyle]);

  // terminal checks on a real iphone: launch with "-prompterAutostart YES"
  const autostarted = useRef(false);
  useEffect(() => {
    if (autostarted.current || !FloatingPrompter.shouldAutostart()) {
      return;
    }
    autostarted.current = true;
    const handle = setTimeout(float, 1500);
    return () => clearTimeout(handle);
  }, [float]);

  const supported = FloatingPrompter.isSupported();
  const status = state.floating ? 'Floating' : state.armed ? 'Ready to float' : 'Not floating';

  return (
    <SafeAreaView style={styles.screen} edges={['top', 'bottom']}>
      <KeyboardAvoidingView style={styles.flex} behavior="padding">
        <View style={styles.header}>
          <Text style={styles.title}>Floating Teleprompter</Text>
          <View style={[styles.pill, state.floating && styles.pillActive]}>
            <View style={[styles.pillDot, state.floating && styles.pillDotActive]} />
            <Text style={[styles.pillText, state.floating && styles.pillTextActive]}>{status}</Text>
          </View>
        </View>

        <Pressable onPress={Keyboard.dismiss} style={styles.previewFrame}>
          <PrompterPreview style={styles.preview} />
        </Pressable>
        <Text style={styles.caption}>
          {state.floating
            ? 'The prompt is in the floating window.'
            : 'The floating window shows this frame: two lines that scroll.'}
        </Text>

        <View style={styles.modeCard}>
          <Text style={styles.settingLabel}>The scroll follows</Text>
          <View style={styles.segments}>
            {[
              { label: 'My voice', value: true },
              { label: 'A timer', value: false },
            ].map((option) => {
              const selected = option.value === voice;
              return (
                <Pressable
                  key={option.label}
                  accessibilityRole="button"
                  accessibilityLabel={`Scroll follows ${option.label}`}
                  accessibilityState={{ selected }}
                  onPress={() => chooseVoice(option.value)}
                  style={[styles.segment, selected && styles.segmentSelected]}>
                  <Text style={[styles.segmentText, selected && styles.segmentTextSelected]}>
                    {option.label}
                  </Text>
                </Pressable>
              );
            })}
          </View>
        </View>

        <View style={styles.modeCard}>
          <Text style={styles.settingLabel}>Floating window type</Text>
          <View style={styles.segments}>
            {[
              { label: 'Call', value: true },
              { label: 'Video', value: false },
            ].map((option) => {
              const selected = option.value === callStyle;
              return (
                <Pressable
                  key={option.label}
                  accessibilityRole="button"
                  accessibilityLabel={`Window type ${option.label}`}
                  accessibilityState={{ selected }}
                  onPress={() => chooseCallStyle(option.value)}
                  style={[styles.segment, selected && styles.segmentSelected]}>
                  <Text style={[styles.segmentText, selected && styles.segmentTextSelected]}>
                    {option.label}
                  </Text>
                </Pressable>
              );
            })}
          </View>
        </View>

        <View style={styles.settings}>
          <View style={styles.setting}>
            <Text style={styles.settingLabel}>Speed</Text>
            <View style={styles.stepper}>
              <StepButton
                label="−"
                accessibilityLabel="Slower"
                disabled={wordsPerMinute <= MIN_WPM}
                onPress={() => setWordsPerMinute((value) => Math.max(MIN_WPM, value - WPM_STEP))}
              />
              <Text style={styles.stepperValue}>{wordsPerMinute} wpm</Text>
              <StepButton
                label="+"
                accessibilityLabel="Faster"
                disabled={wordsPerMinute >= MAX_WPM}
                onPress={() => setWordsPerMinute((value) => Math.min(MAX_WPM, value + WPM_STEP))}
              />
            </View>
          </View>
          <View style={styles.setting}>
            <Text style={styles.settingLabel}>Text size</Text>
            <View style={styles.segments}>
              {SIZES.map((size) => {
                const selected = size.fontSize === fontSize;
                return (
                  <Pressable
                    key={size.label}
                    accessibilityRole="button"
                    accessibilityLabel={`Text size ${size.label}`}
                    accessibilityState={{ selected }}
                    onPress={() => setFontSize(size.fontSize)}
                    style={[styles.segment, selected && styles.segmentSelected]}>
                    <Text style={[styles.segmentText, selected && styles.segmentTextSelected]}>
                      {size.label}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          </View>
        </View>

        {voice ? (
          <View style={styles.modeCard}>
            <Text style={styles.settingLabel}>
              {state.listening ? 'Listening' : state.playing ? 'No microphone: timer' : 'Voice'}
            </Text>
            <Text numberOfLines={1} style={styles.heard}>
              {state.listening && state.heard
                ? `"${state.heard}"`
                : 'Read at your own pace. Say a section again, and the prompt goes back with you.'}
            </Text>
          </View>
        ) : (
          <View style={styles.autoStart}>
            <Text style={styles.settingLabel}>Start after I leave the app</Text>
            <View style={styles.segments}>
              {AUTO_STARTS.map((option) => {
                const selected = option.seconds === autoStartDelay;
                return (
                  <Pressable
                    key={option.label}
                    accessibilityRole="button"
                    accessibilityLabel={`Start delay ${option.label}`}
                    accessibilityState={{ selected }}
                    onPress={() => setAutoStartDelay(option.seconds)}
                    style={[styles.segment, selected && styles.segmentSelected]}>
                    <Text style={[styles.segmentText, selected && styles.segmentTextSelected]}>
                      {option.label}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          </View>
        )}

        <View style={[styles.scriptCard, editing && styles.scriptCardEditing]}>
          <View style={styles.scriptHeader}>
            <Text style={styles.settingLabel}>Script</Text>
            <Text style={styles.scriptMeta}>
              {state.wordCount} words · {formatDuration(state.duration)}
            </Text>
            {editing ? (
              <Pressable accessibilityRole="button" hitSlop={12} onPress={Keyboard.dismiss}>
                <Text style={styles.done}>Done</Text>
              </Pressable>
            ) : null}
          </View>
          <TextInput
            accessibilityLabel="Script"
            multiline
            value={script}
            onChangeText={setScript}
            onFocus={() => setEditing(true)}
            onBlur={() => setEditing(false)}
            placeholder="Paste your script here"
            placeholderTextColor={colors.textFaint}
            selectionColor={colors.accent}
            keyboardAppearance="dark"
            textAlignVertical="top"
            style={styles.scriptInput}
          />
        </View>

        {editing ? null : (
          <View style={styles.footer}>
            {error ? <Text style={styles.error}>{error}</Text> : null}

            {/* play and restart also work before the prompt floats, to rehearse in the preview */}
            <View style={styles.transport}>
              <SecondaryButton
                label={state.playing ? 'Pause' : 'Play'}
                onPress={() => FloatingPrompter.setPlaying(!state.playing)}
              />
              <SecondaryButton label="Restart" onPress={() => FloatingPrompter.restart()} />
              {state.armed ? (
                <SecondaryButton label="Stop" destructive onPress={() => FloatingPrompter.stop()} />
              ) : null}
            </View>

            {state.floating ? (
              <Text style={styles.hint}>
                {voice
                  ? 'Open the Camera app and start to record. The prompt follows your voice.'
                  : autoStartDelay > 0
                  ? `Open the Camera app and start to record. The prompt starts ${autoStartDelay} s after you leave this app.`
                  : 'Open the Camera app. iOS pauses the prompt there: tap the floating prompt, then tap play.'}
              </Text>
            ) : (
              <Pressable
                accessibilityRole="button"
                disabled={!supported || state.wordCount === 0}
                onPress={float}
                style={({ pressed }) => [
                  styles.primary,
                  pressed && styles.primaryPressed,
                  (!supported || state.wordCount === 0) && styles.primaryDisabled,
                ]}>
                <Text style={styles.primaryText}>
                  {supported ? 'Float the prompt' : 'Picture in Picture is not available'}
                </Text>
              </Pressable>
            )}

            {logs.length > 0 ? (
              <Pressable
                accessibilityRole="button"
                accessibilityLabel="Session log"
                onPress={() => setLogOpen((open) => !open)}>
                {logOpen ? (
                  <ScrollView style={styles.logList}>
                    {logs.map((line, index) => (
                      <Text key={`${index}-${line}`} style={styles.logLine}>
                        {line}
                      </Text>
                    ))}
                  </ScrollView>
                ) : (
                  <Text numberOfLines={1} style={styles.logLine}>
                    Log: {logs[0]}
                  </Text>
                )}
              </Pressable>
            ) : null}
          </View>
        )}
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

function StepButton(props: {
  label: string;
  accessibilityLabel: string;
  disabled: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={props.accessibilityLabel}
      disabled={props.disabled}
      hitSlop={6}
      onPress={props.onPress}
      style={({ pressed }) => [styles.stepButton, pressed && styles.pressed]}>
      <Text style={[styles.stepButtonText, props.disabled && styles.disabledText]}>{props.label}</Text>
    </Pressable>
  );
}

function SecondaryButton(props: { label: string; destructive?: boolean; onPress: () => void }) {
  return (
    <Pressable
      accessibilityRole="button"
      onPress={props.onPress}
      style={({ pressed }) => [styles.secondary, pressed && styles.pressed]}>
      <Text style={[styles.secondaryText, props.destructive && styles.destructiveText]}>
        {props.label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  screen: {
    flex: 1,
    backgroundColor: colors.background,
    paddingHorizontal: space.screen,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingTop: space.sm,
    paddingBottom: space.md,
  },
  title: {
    color: colors.text,
    fontSize: 20,
    fontWeight: '700',
    letterSpacing: -0.3,
  },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: radius.pill,
    backgroundColor: colors.surface,
  },
  pillActive: { backgroundColor: colors.accentSoft },
  pillDot: { width: 6, height: 6, borderRadius: 3, backgroundColor: colors.textFaint },
  pillDotActive: { backgroundColor: colors.accent },
  pillText: { color: colors.textMuted, fontSize: 12, fontWeight: '600' },
  pillTextActive: { color: colors.accent },
  previewFrame: {
    borderRadius: radius.card,
    borderCurve: 'continuous',
    overflow: 'hidden',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: '#000',
  },
  preview: { width: '100%', aspectRatio: 3 },
  caption: {
    color: colors.textFaint,
    fontSize: 12,
    marginTop: space.xs,
    marginBottom: space.md,
  },
  settings: { flexDirection: 'row', gap: space.sm, marginBottom: space.sm },
  setting: {
    flex: 1,
    gap: space.xs,
    padding: space.sm,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    backgroundColor: colors.surface,
  },
  modeCard: {
    gap: space.xs,
    padding: space.sm,
    marginBottom: space.sm,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    backgroundColor: colors.surface,
  },
  heard: { color: colors.text, fontSize: 15, lineHeight: 36 },
  autoStart: {
    gap: space.xs,
    padding: space.sm,
    marginBottom: space.sm,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    backgroundColor: colors.surface,
  },
  settingLabel: {
    color: colors.textMuted,
    fontSize: 12,
    fontWeight: '600',
    letterSpacing: 0.4,
    textTransform: 'uppercase',
  },
  stepper: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  stepperValue: {
    color: colors.text,
    fontSize: 16,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
  stepButton: {
    width: 36,
    height: 36,
    borderRadius: radius.control,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.surfaceRaised,
  },
  stepButtonText: { color: colors.text, fontSize: 20, fontWeight: '500', lineHeight: 24 },
  disabledText: { color: colors.textFaint },
  segments: {
    flexDirection: 'row',
    height: 36,
    padding: 3,
    borderRadius: radius.control,
    backgroundColor: colors.surfaceRaised,
  },
  segment: { flex: 1, alignItems: 'center', justifyContent: 'center', borderRadius: 7 },
  segmentSelected: { backgroundColor: colors.segmentSelected },
  segmentText: { color: colors.textMuted, fontSize: 14, fontWeight: '600' },
  segmentTextSelected: { color: colors.text },
  scriptCard: {
    flex: 1,
    padding: space.sm,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    backgroundColor: colors.surface,
  },
  scriptCardEditing: { marginBottom: space.sm },
  scriptHeader: { flexDirection: 'row', alignItems: 'center', gap: space.sm },
  scriptMeta: {
    flex: 1,
    color: colors.textFaint,
    fontSize: 12,
    fontVariant: ['tabular-nums'],
  },
  done: { color: colors.accent, fontSize: 15, fontWeight: '600' },
  scriptInput: {
    flex: 1,
    marginTop: space.xs,
    color: colors.text,
    fontSize: 17,
    lineHeight: 25,
    padding: 0,
  },
  footer: { gap: space.sm, paddingTop: space.md, paddingBottom: space.xs },
  transport: { flexDirection: 'row', gap: space.sm },
  secondary: {
    flex: 1,
    height: 46,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.control,
    borderCurve: 'continuous',
    backgroundColor: colors.surface,
  },
  secondaryText: { color: colors.text, fontSize: 16, fontWeight: '600' },
  destructiveText: { color: colors.danger },
  primary: {
    height: 54,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.card,
    borderCurve: 'continuous',
    backgroundColor: colors.accent,
  },
  primaryPressed: { opacity: 0.85 },
  primaryDisabled: { opacity: 0.4 },
  primaryText: { color: '#fff', fontSize: 17, fontWeight: '700' },
  pressed: { opacity: 0.6 },
  hint: {
    color: colors.textMuted,
    fontSize: 15,
    lineHeight: 21,
    textAlign: 'center',
    paddingVertical: space.sm,
  },
  error: { color: colors.danger, fontSize: 14, textAlign: 'center' },
  logList: { maxHeight: 120 },
  logLine: { color: colors.textFaint, fontSize: 12, lineHeight: 17, textAlign: 'center' },
});
