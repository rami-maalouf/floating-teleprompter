import { NativeModule, requireNativeModule, requireNativeView } from 'expo';
import type { ComponentType } from 'react';
import type { ViewProps } from 'react-native';

export type PrompterState = {
  // the audio session and the picture in picture controller are live
  armed: boolean;
  // the prompt is in a picture in picture window
  floating: boolean;
  playing: boolean;
  // 0 to 1
  progress: number;
  // seconds for the whole script at the current speed
  duration: number;
  rowCount: number;
  wordCount: number;
  // the voice mode is on
  voice: boolean;
  // the microphone gives audio and the scroll follows the voice
  listening: boolean;
  // the last words that the recognizer heard
  heard: string;
  // the number of script words already said
  wordIndex: number;
};

export type PrompterConfig = {
  text: string;
  wordsPerMinute: number;
  // points on the 1200 x 400 frame. one row is 200 points high.
  fontSize: number;
  // seconds between "the app left the front" and "the scroll starts". 0 is off.
  // ios pauses the floating window when the camera app opens, so this timer
  // starts the scroll with no tap on the floating window.
  autoStartDelay: number;
  // true: the microphone and speech recognition move the scroll.
  // false: the timer moves it at wordsPerMinute.
  voice: boolean;
};

type PrompterEvents = {
  onStateChange: (state: PrompterState) => void;
  onLog: (event: { message: string }) => void;
};

declare class FloatingPrompterModule extends NativeModule<PrompterEvents> {
  isSupported(): boolean;
  shouldAutostart(): boolean;
  shouldSimulateVoice(): boolean;
  voicePermissionsGranted(): boolean;
  requestVoicePermissions(): Promise<boolean>;
  setSimulatedVoice(simulated: boolean): Promise<void>;
  debugHear(text: string): Promise<void>;
  loadDraft(): string | null;
  saveDraft(text: string): void;
  configure(config: PrompterConfig): Promise<void>;
  start(): Promise<void>;
  setPlaying(playing: boolean): Promise<void>;
  restart(): Promise<void>;
  stop(): Promise<void>;
  getState(): Promise<PrompterState>;
}

export const FloatingPrompter = requireNativeModule<FloatingPrompterModule>('FloatingPrompter');

// the frame that floats. keep the 3:1 shape: width = 3 x height.
export const PrompterPreview: ComponentType<ViewProps> = requireNativeView('FloatingPrompter');
