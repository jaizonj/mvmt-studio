/* eslint-disable react-hooks/immutability --
   expo-video's player is an imperative native object: play(), pause(),
   replaceAsync() and assigning currentTime ARE its documented API, called
   from playback events/controls — never during render. The React Compiler
   immutability rule cannot model that, so it is disabled for this file. */
import { Ionicons } from '@expo/vector-icons';
import { useAudioPlayer } from 'expo-audio';
import { useVideoPlayer, VideoView } from 'expo-video';
import { useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing } from '../theme';

export interface PreviewClip {
  id: string;
  uri: string;
  trimStartSeconds: number;
  /** Undefined = end of the file. */
  trimEndSeconds?: number;
  durationSeconds?: number;
  /** The clip's own (microphone) audio level from Edit — honoured in preview. */
  volume?: number;
  muted?: boolean;
}

interface TimelinePreviewProps {
  clips: PreviewClip[];
  trackUri?: string | null;
  /** Absolute track time the selected region starts at (default 0). */
  trackStartSeconds?: number;
  /**
   * Playback position within the EDIT (seconds from the cut's start),
   * reported while playing and whenever the position jumps — drives the
   * timeline editor's playhead.
   */
  onProgress?: (editSeconds: number, playing: boolean) => void;
}

/**
 * Sequential preview: plays each timeline clip's trimmed range in order,
 * with the track restarted from the top alongside it (the same sync-at-
 * capture trick used when recording). Poll-based segment ends keep this
 * simple and predictable for a scaffold; a production version would use
 * a single composition player instead (see README TODO).
 *
 * Mount it with a `key` that changes when the edit changes, so it always
 * starts from a clean player.
 */
export function TimelinePreview({ clips, trackUri, trackStartSeconds = 0, onProgress }: TimelinePreviewProps) {
  const [index, setIndex] = useState(0);
  const [playing, setPlaying] = useState(false);
  const indexRef = useRef(0);
  const playingRef = useRef(false);
  const onProgressRef = useRef(onProgress);
  useEffect(() => {
    onProgressRef.current = onProgress;
  }, [onProgress]);

  const clipLength = (clip: PreviewClip) =>
    Math.max(0, (clip.trimEndSeconds ?? clip.durationSeconds ?? 0) - clip.trimStartSeconds);
  const editOffsetOf = (i: number) => clips.slice(0, i).reduce((sum, c) => sum + clipLength(c), 0);

  /** Current position inside the whole edit, for the timeline playhead. */
  const reportProgress = useCallback(() => {
    const clip = clips[indexRef.current];
    if (!clip || !onProgressRef.current) return;
    const within = Math.min(
      Math.max(0, videoPlayer.currentTime - clip.trimStartSeconds),
      clipLength(clip),
    );
    onProgressRef.current(editOffsetOf(indexRef.current) + within, playingRef.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clips]);

  const videoPlayer = useVideoPlayer(clips[0]?.uri ?? null, (player) => {
    player.loop = false;
  });
  const audioPlayer = useAudioPlayer(trackUri ?? null);

  // Stop ALL playback the moment this screen loses focus or unmounts.
  // Stack screens stay mounted in Expo Router, so without this the track
  // kept playing after navigating (e.g. preview in Edit → Export window,
  // Jaizon's device test 2026-11-08). Blur and unmount both pause.
  const stopPlayback = useCallback(() => {
    try {
      videoPlayer.pause();
    } catch {
      /* player already released */
    }
    try {
      audioPlayer.pause();
    } catch {
      /* player already released */
    }
    playingRef.current = false;
    setPlaying(false);
  }, [videoPlayer, audioPlayer]);

  useFocusEffect(
    useCallback(() => {
      return () => stopPlayback();
    }, [stopPlayback]),
  );

  useEffect(() => {
    return () => {
      try {
        videoPlayer.pause();
        audioPlayer.pause();
      } catch {
        /* players already released */
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const clipEnd = (clip: PreviewClip) =>
    clip.trimEndSeconds ?? clip.durationSeconds ?? Number.POSITIVE_INFINITY;

  const startClip = async (i: number, autoplay: boolean) => {
    const clip = clips[i];
    if (!clip) return;
    indexRef.current = i;
    setIndex(i);
    await videoPlayer.replaceAsync(clip.uri);
    // Honour the clip's Edit-stage audio settings: Mute must actually
    // mute, and the volume slider must actually change the level
    // (Jaizon's device test: a muted clip still played its audio).
    videoPlayer.volume = clip.muted ? 0 : Math.max(0, Math.min(1, clip.volume ?? 1));
    // expo-video seeks by assigning currentTime (documented API).
    videoPlayer.currentTime = clip.trimStartSeconds;
    if (autoplay) videoPlayer.play();
    reportProgress();
  };

  // Poll for trim-out points / natural ends.
  useEffect(() => {
    if (!playing) return;
    const timer = setInterval(() => {
      const clip = clips[indexRef.current];
      if (!clip) return;
      reportProgress();
      if (videoPlayer.currentTime >= clipEnd(clip) - 0.05) {
        const next = indexRef.current + 1;
        if (next < clips.length) {
          void startClip(next, true);
        } else {
          videoPlayer.pause();
          audioPlayer.pause();
          playingRef.current = false;
          setPlaying(false);
          void startClip(0, false);
        }
      }
    }, 200);
    return () => clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playing, clips]);

  const togglePlay = async () => {
    if (playing) {
      videoPlayer.pause();
      audioPlayer.pause();
      playingRef.current = false;
      setPlaying(false);
      reportProgress();
      return;
    }
    await startClip(indexRef.current, false);
    if (trackUri) {
      // Preview position in the edit = sum of earlier clips' lengths.
      const offset = clips
        .slice(0, indexRef.current)
        .reduce((sum, c) => sum + ((c.trimEndSeconds ?? c.durationSeconds ?? 0) - c.trimStartSeconds), 0);
      await audioPlayer.seekTo(Math.max(0, trackStartSeconds + offset));
      audioPlayer.play();
    }
    videoPlayer.play();
    playingRef.current = true;
    setPlaying(true);
    reportProgress();
  };

  if (clips.length === 0) return null;

  return (
    <View>
      <VideoView
        player={videoPlayer}
        style={styles.video}
        nativeControls={false}
        contentFit="cover"
      />
      <View style={styles.controls}>
        <Pressable style={styles.playButton} onPress={togglePlay} accessibilityRole="button" accessibilityLabel={playing ? 'Pause preview' : 'Play preview'}>
          <Ionicons name={playing ? 'pause' : 'play'} size={20} color="#14141F" />
          <Text style={styles.playButtonText}>{playing ? 'Pause' : 'Preview'}</Text>
        </Pressable>
        <Text style={styles.position}>
          Clip {index + 1} of {clips.length}
          {trackUri ? ' · track in sync' : ' · no track'}
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  video: {
    width: '100%',
    aspectRatio: 9 / 14,
    maxHeight: 460,
    borderRadius: radius.lg,
    backgroundColor: '#111118',
  },
  controls: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    marginTop: spacing.md,
  },
  playButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: '#FFFFFF',
    borderRadius: radius.pill,
    paddingHorizontal: 16,
    paddingVertical: 9,
  },
  playButtonText: { color: '#14141F', fontSize: 15, fontWeight: '600' },
  position: { color: colors.labelSecondary, fontSize: 13, fontWeight: '500' },
});
