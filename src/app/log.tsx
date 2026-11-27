import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { useLogs } from '../store';
import { colors, space } from '../theme';

// what ios did, newest first. this is for checks on a real phone.
export default function LogSheet() {
  const logs = useLogs();
  return (
    <View style={styles.sheet}>
      <Text style={styles.title}>Session log</Text>
      <ScrollView contentContainerStyle={styles.list}>
        {logs.length === 0 ? <Text style={styles.empty}>No events yet.</Text> : null}
        {logs.map((line, index) => (
          <Text key={`${logs.length - index}`} style={styles.line}>
            {line}
          </Text>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  sheet: { flex: 1, paddingHorizontal: space.screen, paddingTop: space.lg },
  title: { color: colors.text, fontSize: 20, fontWeight: '700', marginBottom: space.sm },
  list: { gap: space.xs, paddingBottom: space.lg },
  line: { color: colors.textMuted, fontSize: 13, lineHeight: 18 },
  empty: { color: colors.textFaint, fontSize: 14 },
});
