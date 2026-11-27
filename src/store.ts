import { useSyncExternalStore } from 'react';

import { FloatingPrompter } from '../modules/floating-prompter';

export const SAMPLE_SCRIPT = `This prompt floats on top of every app on my iPhone.

I pasted my script, and I started Picture in Picture. Then I opened the Camera app.

The words scroll next to the lens, so I look at you and not at my notes.

[demo]

It is one Expo app with one small Swift module. That is the whole trick.`;

export type Settings = {
  script: string;
  wordsPerMinute: number;
  // points on the 1200 x 400 frame
  fontSize: number;
  // seconds between "the app left the front" and "the scroll starts". timer mode only.
  autoStartDelay: number;
  // true: the scroll follows the voice. false: it follows a timer.
  voice: boolean;
};

// one small store, so the main screen and the script sheet share the same values
let settings: Settings = {
  script: FloatingPrompter.loadDraft() ?? SAMPLE_SCRIPT,
  wordsPerMinute: 140,
  fontSize: 120,
  autoStartDelay: 10,
  voice: FloatingPrompter.voicePermissionsGranted() || FloatingPrompter.shouldSimulateVoice(),
};
let logs: string[] = [];
const listeners = new Set<() => void>();

function emit() {
  listeners.forEach((listener) => listener());
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function updateSettings(patch: Partial<Settings>) {
  settings = { ...settings, ...patch };
  emit();
}

export function getSettings() {
  return settings;
}

export function useSettings() {
  return useSyncExternalStore(subscribe, () => settings);
}

export function addLog(message: string) {
  logs = [message, ...logs].slice(0, 40);
  emit();
}

export function useLogs() {
  return useSyncExternalStore(subscribe, () => logs);
}

export function countWords(text: string) {
  const trimmed = text.trim();
  return trimmed ? trimmed.split(/\s+/).length : 0;
}

export function formatDuration(seconds: number) {
  const total = Math.round(seconds);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}
