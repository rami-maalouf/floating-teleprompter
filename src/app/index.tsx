import { useEvent, useEventListener } from 'expo';
import { router } from 'expo-router';
import { SymbolView } from 'expo-symbols';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Switch, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { FloatingPrompter, PrompterPreview, type PrompterState } from '../../modules/floating-prompter';
import { Segments, SettingRow, Stepper } from '../components/controls';
import { GlassButton, GlassCard, GlassIconButton } from '../components/glass';
import {
  SAMPLE_SCRIPT,
  addLog,
  countWords,
  formatDuration,
  getSettings,
  updateSettings,
  useSettings,
} from '../store';
import { colors, radius, space } from '../theme';

const SIZES = [
  { label: 'S', value: 96 },
  { label: 'M', value: 120 },
  { label: 'L', value: 144 },
] as const;

// seconds between "the app left the front" and "the scroll starts"
const DELAYS = [
  { label: 'Off', value: 0 },
  { label: '5 s', value: 5 },
  { label: '10 s', value: 10 },
  { label: '15 s', value: 15 },
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

export default function PrompterScreen() {
  const settings = useSettings();
  const { script, wordsPerMinute, fontSize, autoStartDelay, voice } = settings;
  const [error, setError] = useState<string | null>(null);

  const state = useEvent(FloatingPrompter, 'onStateChange', IDLE_STATE);

  useEventListener(FloatingPrompter, 'onLog', ({ message }) => {
    addLog(message);
    if (message.startsWith('error:')) {
      setError(message.replace('error: ', ''));
    }
  });

  // the native frame follows every change to the script and the settings
  useEffect(() => {
    const handle = setTimeout(() => {
      FloatingPrompter.configure({ text: script, wordsPerMinute, fontSize, autoStartDelay, voice });
      FloatingPrompter.saveDraft(script);
    }, 150);
    return () => clearTimeout(handle);
  }, [script, wordsPerMinute, fontSize, autoStartDelay, voice]);

  // the voice mode needs the microphone and speech recognition
  const chooseVoice = useCallback(async (next: boolean) => {
    setError(null);
    if (next && !FloatingPrompter.voicePermissionsGranted()) {
      const granted = await FloatingPrompter.requestVoicePermissions();
      if (!granted) {
        setError('Allow the microphone and speech recognition in Settings to follow your voice.');
        return;
      }
    }
    updateSettings({ voice: next });
  }, []);

  const float = useCallback(async () => {
    setError(null);
    try {
      const current = getSettings();
      await FloatingPrompter.configure({
        text: current.script,
        wordsPerMinute: current.wordsPerMinute,
        fontSize: current.fontSize,
        autoStartDelay: current.autoStartDelay,
        voice: current.voice,
      });
      await FloatingPrompter.start();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  }, []);

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

  // simulator and terminal checks: feed the words of a read, three words a second
  useEffect(() => {
    if (!FloatingPrompter.shouldSimulateVoice()) {
      return;
    }
    updateSettings({ script: SAMPLE_SCRIPT, voice: true });
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

  const supported = FloatingPrompter.isSupported();
  const words = countWords(script);
  const excerpt = script.trim().replace(/\s+/g, ' ');

  // one line under the frame says what the prompt does now
  let status = voice ? 'Follows your voice' : `${formatDuration((words / wordsPerMinute) * 60)} at ${wordsPerMinute} wpm`;
  if (state.playing && voice) {
    status = state.listening
      ? state.heard
        ? `Heard "${state.heard}"`
        : 'Listening'
      : 'No microphone. The timer scrolls.';
  }

  let hint: string | null = null;
  if (state.floating) {
    hint = voice
      ? 'Open Camera and record. The prompt follows your voice.'
      : autoStartDelay > 0
        ? `Open Camera and record. The prompt starts ${autoStartDelay} s after you leave this app.`
        : 'Open Camera and record. Start the prompt here before you leave.';
  }

  return (
    <SafeAreaView style={styles.screen} edges={['top', 'bottom']}>
      <View style={styles.header}>
        <Text style={styles.title}>Teleprompter</Text>
      </View>

      {/* the frame that floats, with its transport */}
      <View style={styles.previewFrame}>
        <PrompterPreview style={styles.preview} />
      </View>
      <View style={styles.transport}>
        <View style={styles.statusRow}>
          <View style={[styles.statusDot, state.floating && styles.statusDotOn]} />
          <Text numberOfLines={1} style={styles.status}>
            {state.floating ? `Floating · ${status}` : status}
          </Text>
        </View>
        <GlassIconButton
          symbol="arrow.counterclockwise"
          accessibilityLabel="Restart"
          onPress={() => FloatingPrompter.restart()}
        />
        <GlassIconButton
          symbol={state.playing ? 'pause.fill' : 'play.fill'}
          accessibilityLabel={state.playing ? 'Pause' : 'Play'}
          onPress={() => FloatingPrompter.setPlaying(!state.playing)}
        />
      </View>

      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Edit script"
        onPress={() => router.push('/script')}>
        <GlassCard style={styles.scriptCard}>
          <View style={styles.scriptText}>
            <Text style={styles.cardLabel}>Script · {words} words</Text>
            <Text numberOfLines={2} style={[styles.excerpt, !excerpt && styles.excerptEmpty]}>
              {excerpt || 'Tap to paste your script'}
            </Text>
          </View>
          <SymbolView name="chevron.up" size={15} tintColor={colors.textFaint} />
        </GlassCard>
      </Pressable>

      <GlassCard>
        <SettingRow label="Follow my voice" first>
          <View style={styles.switchBox}>
            <Switch
              accessibilityLabel="Follow my voice"
              value={voice}
              onValueChange={chooseVoice}
              trackColor={{ true: colors.accent }}
            />
          </View>
        </SettingRow>
        <SettingRow label="Text size">
          <Segments
            label="Text size"
            options={SIZES}
            value={fontSize}
            onChange={(value) => updateSettings({ fontSize: value })}
          />
        </SettingRow>
        {voice ? null : (
          <>
            <SettingRow label="Speed">
              <Stepper
                value={`${wordsPerMinute} wpm`}
                canDecrease={wordsPerMinute > MIN_WPM}
                canIncrease={wordsPerMinute < MAX_WPM}
                onDecrease={() => updateSettings({ wordsPerMinute: wordsPerMinute - WPM_STEP })}
                onIncrease={() => updateSettings({ wordsPerMinute: wordsPerMinute + WPM_STEP })}
              />
            </SettingRow>
            <SettingRow label="Start delay">
              <Segments
                label="Start delay"
                options={DELAYS}
                value={autoStartDelay}
                onChange={(value) => updateSettings({ autoStartDelay: value })}
              />
            </SettingRow>
          </>
        )}
      </GlassCard>

      <View style={styles.footer}>
        {error ? <Text style={styles.error}>{error}</Text> : null}
        {hint && !error ? <Text style={styles.hint}>{hint}</Text> : null}

        {state.floating ? (
          <GlassButton
            label="Stop"
            symbol="stop.fill"
            destructive
            onPress={() => FloatingPrompter.stop()}
          />
        ) : (
          <View style={styles.actions}>
            {state.armed ? (
              <GlassButton label="Stop" destructive onPress={() => FloatingPrompter.stop()} />
            ) : null}
            <GlassButton
              label={supported ? 'Float the prompt' : 'Picture in Picture is not available'}
              symbol={supported ? 'pip.enter' : undefined}
              prominent
              disabled={!supported || words === 0}
              onPress={float}
              style={styles.primary}
            />
          </View>
        )}

        {/* diagnostics for checks on a real phone. low emphasis on purpose. */}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Session log"
          hitSlop={8}
          onPress={() => router.push('/log')}>
          <Text style={styles.logLink}>Session log</Text>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: colors.background,
    paddingHorizontal: space.screen,
    gap: space.sm,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingTop: space.xs,
  },
  title: { color: colors.text, fontSize: 30, fontWeight: '800', letterSpacing: -0.6 },
  previewFrame: {
    borderRadius: radius.card,
    borderCurve: 'continuous',
    overflow: 'hidden',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.separator,
    backgroundColor: '#000',
  },
  preview: { width: '100%', aspectRatio: 3 },
  transport: { flexDirection: 'row', alignItems: 'center', gap: space.sm, marginBottom: space.xs },
  statusRow: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: 8 },
  statusDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: colors.textFaint },
  statusDotOn: { backgroundColor: colors.accent },
  status: { flex: 1, color: colors.textMuted, fontSize: 14, fontVariant: ['tabular-nums'] },
  scriptCard: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    padding: space.md,
  },
  scriptText: { flex: 1, gap: 4 },
  cardLabel: { color: colors.textMuted, fontSize: 13, fontWeight: '600' },
  excerpt: { color: colors.text, fontSize: 16, lineHeight: 22 },
  excerptEmpty: { color: colors.textFaint },
  footer: { flex: 1, justifyContent: 'flex-end', gap: space.sm, paddingBottom: space.xs },
  actions: { flexDirection: 'row', gap: space.sm },
  primary: { flex: 1 },
  // the ios 26 switch is wider and lower than the size react native reserves for it
  switchBox: { width: 64, height: 32, alignItems: 'flex-end', justifyContent: 'center' },
  logLink: { color: colors.textFaint, fontSize: 13, textAlign: 'center' },
  hint: { color: colors.textMuted, fontSize: 14, lineHeight: 20, textAlign: 'center' },
  error: { color: colors.danger, fontSize: 14, lineHeight: 20, textAlign: 'center' },
});
