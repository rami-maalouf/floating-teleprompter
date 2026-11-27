import * as Clipboard from 'expo-clipboard';
import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { Keyboard, StyleSheet, Text, TextInput, View } from 'react-native';

import { GlassButton } from '../components/glass';
import { countWords, formatDuration, updateSettings, useSettings } from '../store';
import { colors, space } from '../theme';

// the script editor. the main screen stays behind it, so the frame shows each change.
export default function ScriptSheet() {
  const { script, wordsPerMinute } = useSettings();
  const words = countWords(script);

  // the sheet grows to full height when the keyboard opens, and its bottom edge is
  // then the bottom of the screen. keep the text and the buttons above the keyboard.
  const [keyboardHeight, setKeyboardHeight] = useState(0);
  useEffect(() => {
    const show = Keyboard.addListener('keyboardWillShow', (event) =>
      setKeyboardHeight(event.endCoordinates.height)
    );
    const hide = Keyboard.addListener('keyboardWillHide', () => setKeyboardHeight(0));
    return () => {
      show.remove();
      hide.remove();
    };
  }, []);

  const paste = async () => {
    const text = await Clipboard.getStringAsync();
    if (text.trim()) {
      updateSettings({ script: text });
    }
  };

  return (
    <View style={[styles.sheet, { paddingBottom: keyboardHeight }]}>
      <View style={styles.header}>
        <View>
          <Text style={styles.title}>Script</Text>
          <Text style={styles.meta}>
            {words} words · {formatDuration((words / wordsPerMinute) * 60)}
          </Text>
        </View>
      </View>

      <TextInput
        accessibilityLabel="Script"
        multiline
        value={script}
        onChangeText={(text) => updateSettings({ script: text })}
        placeholder="Paste your script here"
        placeholderTextColor={colors.textFaint}
        selectionColor={colors.accent}
        keyboardAppearance="dark"
        textAlignVertical="top"
        style={styles.input}
      />

      <View style={styles.actions}>
        <GlassButton label="Paste" symbol="doc.on.clipboard" onPress={paste} style={styles.action} />
        <GlassButton
          label="Clear"
          symbol="trash"
          destructive
          disabled={!script}
          onPress={() => updateSettings({ script: '' })}
          style={styles.action}
        />
        {/* done is at the bottom: the dev build's tools button covers the top right corner */}
        <GlassButton label="Done" prominent onPress={() => router.back()} style={styles.action} />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  sheet: { flex: 1, paddingHorizontal: space.screen, paddingTop: space.lg },
  header: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    marginBottom: space.sm,
  },
  title: { color: colors.text, fontSize: 20, fontWeight: '700' },
  meta: { color: colors.textFaint, fontSize: 13, marginTop: 2, fontVariant: ['tabular-nums'] },
  input: { flex: 1, color: colors.text, fontSize: 18, lineHeight: 27, padding: 0 },
  actions: { flexDirection: 'row', alignItems: 'center', gap: space.xs, paddingVertical: space.sm },
  action: { flex: 1 },
});
