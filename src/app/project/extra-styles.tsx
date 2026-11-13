/**
 * Extra Styles 2.0 — catalog screen (Phase 3, §12).
 *
 * A dedicated screen, separate from Traditional Lyrics (the
 * Lyrics panel is untouched): categories, search, favorites,
 * recently used, featured, and one card per style. Each card
 * shows an ANIMATED preview — the actual composition over the
 * bundled sample clip, rendered on demand when the card becomes
 * visible and cached on disk (cardPreviews.ts) — played looping
 * with expo-video.
 *
 * Tapping a card selects the style (defaults for its params),
 * records it as recently used, and expands the schema-generated
 * controls (sliders / toggles / colours / segmented / select /
 * number / asset) plus its presets — the Editor preview behind
 * this screen shows the style over the user's own video. There
 * is no per-style UI code: every control is generated from the
 * parameter schema (§8.1).
 *
 * Layer editing (§8.3) is NOT here yet: the catalog metadata
 * carries no layer schema in Phase 3, so no style declares
 * editable layers — a Phase 4 item (see the Phase 3 doc).
 */

import { Ionicons } from '@expo/vector-icons';
import Slider from '@react-native-community/slider';
import { router } from 'expo-router';
import { VideoView, useVideoPlayer } from 'expo-video';
import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { DropdownPicker } from '../../components/DropdownPicker';
import { SegmentedControl } from '../../components/SegmentedControl';
import { getExtraStyleCardPreview } from '../../lib/extra-styles/cardPreviews';
import {
  STYLE_CAPABILITY_MAP,
  filterExtraStylesByCategory,
  searchExtraStyleCatalog,
  sortExtraStylesWithFavoritesFirst,
  userVisibleStyles,
} from '../../lib/extra-styles/catalog';
import { applyExtraStylePreset, defaultParams } from '../../lib/extra-styles/params';
import { getCachedExtraStyleCatalog } from '../../lib/extra-styles/prepare';
import { resolveSampleClipUri } from '../../lib/extra-styles/sampleClip';
import type {
  ExtraStyleCatalog,
  ExtraStyleCategory,
  ExtraStyleMetadata,
  ExtraStyleParameter,
  ExtraStyleParamValue,
} from '../../lib/extra-styles/types';
import { EXTRA_STYLE_CATEGORIES } from '../../lib/extra-styles/types';
import { useStudio } from '../../store/StudioContext';
import { colors, radius, spacing, type as typeScale } from '../../theme';

/** Colour swatches for `color` params (no free-form picker in
 *  Phase 3 — the styles' palettes live in this set). */
const COLOR_SWATCHES = [
  '#C9F36B',
  '#F4F1E9',
  '#0CA6B5',
  '#FF4D4D',
  '#FF9F1C',
  '#FFD60A',
  '#4D7CFE',
  '#FF5DA2',
  '#9B5DE5',
  '#FFFFFF',
  '#101114',
];

function formatParamValue(param: ExtraStyleParameter, value: ExtraStyleParamValue): string {
  if (typeof value === 'number') {
    const text = param.step !== undefined && param.step < 1 ? value.toFixed(2) : String(Math.round(value * 100) / 100);
    return param.unit ? `${text}${param.unit}` : text;
  }
  if (typeof value === 'boolean') return value ? 'On' : 'Off';
  return String(value);
}

function ParamControl({
  param,
  value,
  onChange,
}: {
  param: ExtraStyleParameter;
  value: ExtraStyleParamValue;
  onChange: (value: ExtraStyleParamValue) => void;
}) {
  const [sliderValue, setSliderValue] = useState(typeof value === 'number' ? value : param.min ?? 0);
  // The value changed from outside (e.g. a preset was applied):
  // adopt it. Adjusted during render — the pattern React endorses
  // instead of syncing state in an effect.
  const [lastSyncedValue, setLastSyncedValue] = useState(value);
  if (value !== lastSyncedValue) {
    setLastSyncedValue(value);
    if (typeof value === 'number') setSliderValue(value);
  }

  switch (param.kind) {
    case 'slider':
      return (
        <View style={styles.paramBlock}>
          <View style={styles.paramLabelRow}>
            <Text style={styles.paramLabel}>{param.label}</Text>
            <Text style={styles.paramValue}>{formatParamValue(param, sliderValue)}</Text>
          </View>
          <Slider
            value={sliderValue}
            minimumValue={param.min ?? 0}
            maximumValue={param.max ?? 1}
            step={param.step ?? 1}
            onValueChange={setSliderValue}
            onSlidingComplete={(v) => onChange(v)}
            minimumTrackTintColor={colors.accent}
            maximumTrackTintColor={colors.elevated}
            thumbTintColor={colors.label}
            accessibilityLabel={param.label}
          />
        </View>
      );
    case 'number': {
      const numeric = typeof value === 'number' ? value : (param.default as number);
      const step = param.step ?? 1;
      const dec = () => onChange(Math.max(param.min ?? -Infinity, numeric - step));
      const inc = () => onChange(Math.min(param.max ?? Infinity, numeric + step));
      return (
        <View style={styles.paramBlock}>
          <View style={styles.paramLabelRow}>
            <Text style={styles.paramLabel}>{param.label}</Text>
            <View style={styles.stepper}>
              <Pressable style={styles.stepperButton} onPress={dec} accessibilityLabel={`Decrease ${param.label}`}>
                <Ionicons name="remove" size={18} color={colors.label} />
              </Pressable>
              <Text style={styles.paramValue}>{formatParamValue(param, numeric)}</Text>
              <Pressable style={styles.stepperButton} onPress={inc} accessibilityLabel={`Increase ${param.label}`}>
                <Ionicons name="add" size={18} color={colors.label} />
              </Pressable>
            </View>
          </View>
        </View>
      );
    }
    case 'toggle':
      return (
        <View style={styles.paramBlock}>
          <View style={styles.paramLabelRow}>
            <Text style={styles.paramLabel}>{param.label}</Text>
            <Switch
              value={value === true}
              onValueChange={(v) => onChange(v)}
              trackColor={{ true: colors.accent, false: colors.elevated }}
              thumbColor={value === true ? colors.onAccent : colors.label}
              accessibilityLabel={param.label}
            />
          </View>
        </View>
      );
    case 'color':
      return (
        <View style={styles.paramBlock}>
          <View style={styles.paramLabelRow}>
            <Text style={styles.paramLabel}>{param.label}</Text>
            <Text style={styles.paramValue}>{String(value)}</Text>
          </View>
          <View style={styles.swatches}>
            {COLOR_SWATCHES.map((swatch) => (
              <Pressable
                key={swatch}
                style={[
                  styles.swatch,
                  { backgroundColor: swatch },
                  value === swatch && styles.swatchSelected,
                ]}
                onPress={() => onChange(swatch)}
                accessibilityRole="button"
                accessibilityLabel={`${param.label} ${swatch}`}
              />
            ))}
          </View>
        </View>
      );
    case 'segmented': {
      const options = (param.options ?? []).map((o) => ({ value: o.value, label: o.label }));
      if (options.length === 0) return null;
      return (
        <View style={styles.paramBlock}>
          <Text style={styles.paramLabel}>{param.label}</Text>
          <SegmentedControl
            options={options}
            value={typeof value === 'string' ? value : (param.default as string)}
            onChange={(v) => onChange(v)}
            accessibilityLabel={param.label}
          />
        </View>
      );
    }
    case 'select': {
      const options = (param.options ?? []).map((o) => ({ value: o.value, label: o.label }));
      if (options.length === 0) return null;
      return (
        <View style={styles.paramBlock}>
          <Text style={styles.paramLabel}>{param.label}</Text>
          <DropdownPicker
            value={typeof value === 'string' ? value : null}
            placeholder={param.label}
            options={options}
            onChange={(v) => onChange(v)}
            accessibilityLabel={param.label}
          />
        </View>
      );
    }
    case 'asset': {
      const options = (param.options ?? []).map((o) => o.value);
      if (options.length === 0) return null;
      return (
        <View style={styles.paramBlock}>
          <Text style={styles.paramLabel}>{param.label}</Text>
          <View style={styles.chips}>
            {options.map((option) => {
              const selected = value === option;
              return (
                <Pressable
                  key={option}
                  style={[styles.chip, selected && styles.chipSelected]}
                  onPress={() => onChange(option)}
                  accessibilityRole="button"
                  accessibilityLabel={`${param.label} ${option}`}>
                  <Text style={[styles.chipText, selected && styles.chipTextSelected]}>{option}</Text>
                </Pressable>
              );
            })}
          </View>
        </View>
      );
    }
    default:
      return null;
  }
}

function StyleCard({
  meta,
  isSelected,
  isExpanded,
  isFavorite,
  isVisible,
  clipUri,
  liveParams,
  onSelect,
  onToggleExpand,
  onToggleFavorite,
  onRemove,
  onPreset,
  onParam,
}: {
  meta: ExtraStyleMetadata;
  isSelected: boolean;
  isExpanded: boolean;
  isFavorite: boolean;
  isVisible: boolean;
  clipUri: string | null;
  liveParams: Record<string, ExtraStyleParamValue> | null;
  onSelect: (meta: ExtraStyleMetadata) => void;
  onToggleExpand: (meta: ExtraStyleMetadata) => void;
  onToggleFavorite: (meta: ExtraStyleMetadata) => void;
  onRemove: () => void;
  onPreset: (meta: ExtraStyleMetadata, presetId: string) => void;
  onParam: (meta: ExtraStyleMetadata, patch: Record<string, ExtraStyleParamValue>) => void;
}) {
  const [previewUri, setPreviewUri] = useState<string | null>(null);
  const paramsKey = isSelected && liveParams ? JSON.stringify(liveParams) : '';
  const player = useVideoPlayer(previewUri, (p) => {
    p.loop = true;
    p.muted = true;
  });

  // Render the looping preview when the card becomes visible
  // (cached on disk after the first render). The selected card
  // re-renders on param change so its preview matches the editor.
  useEffect(() => {
    if (!isVisible || !clipUri) return;
    let alive = true;
    const params = isSelected && liveParams ? liveParams : undefined;
    void getExtraStyleCardPreview(meta, clipUri, params).then((uri) => {
      if (alive) setPreviewUri(uri);
    });
    return () => {
      alive = false;
    };
    // paramsKey carries the live params; meta/clipUri/isVisible
    // are the other inputs. (liveParams itself is intentionally
    // not a dep — its serialisation is.)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isVisible, clipUri, meta, isSelected, paramsKey]);

  useEffect(() => {
    if (previewUri && isVisible) player.play();
    else player.pause();
  }, [previewUri, isVisible, player]);

  const params = isSelected && liveParams ? liveParams : defaultParams(meta.parameters);
  return (
    <View style={[styles.card, isSelected && styles.cardSelected]}>
      <Pressable
        style={styles.cardRow}
        onPress={() => (isSelected ? onToggleExpand(meta) : onSelect(meta))}
        accessibilityRole="button"
        accessibilityLabel={`${meta.name} — ${meta.tagline}`}>
        <View style={styles.previewBox}>
          {previewUri ? (
            <VideoView player={player} style={styles.previewVideo} contentFit="cover" nativeControls={false} />
          ) : (
            <View style={styles.previewPlaceholder}>
              <Ionicons name="sparkles" size={22} color={colors.labelTertiary} />
            </View>
          )}
          {isSelected ? (
            <View style={styles.selectedBadge}>
              <Ionicons name="checkmark" size={12} color={colors.onAccent} />
            </View>
          ) : null}
        </View>
        <View style={styles.cardText}>
          <Text style={styles.cardName} numberOfLines={1}>
            {meta.name}
          </Text>
          <Text style={styles.cardTagline} numberOfLines={2}>
            {meta.tagline}
          </Text>
          <Text style={styles.cardCategory}>{meta.category}</Text>
        </View>
        <Pressable
          style={styles.heart}
          onPress={() => onToggleFavorite(meta)}
          accessibilityRole="button"
          accessibilityLabel={isFavorite ? `Unfavorite ${meta.name}` : `Favorite ${meta.name}`}>
          <Ionicons
            name={isFavorite ? 'heart' : 'heart-outline'}
            size={22}
            color={isFavorite ? colors.accent : colors.labelSecondary}
          />
        </Pressable>
      </Pressable>
      {isSelected && isExpanded ? (
        <View style={styles.controls}>
          {meta.presets && meta.presets.length > 0 ? (
            <View style={styles.chips}>
              {meta.presets.map((preset) => (
                <Pressable
                  key={preset.id}
                  style={styles.chip}
                  onPress={() => onPreset(meta, preset.id)}
                  accessibilityRole="button"
                  accessibilityLabel={`Preset ${preset.label}`}>
                  <Text style={styles.chipText}>{preset.label}</Text>
                </Pressable>
              ))}
            </View>
          ) : null}
          {meta.parameters.map((param) => (
            <ParamControl
              key={param.id}
              param={param}
              value={params[param.id] ?? param.default}
              onChange={(value) => onParam(meta, { [param.id]: value })}
            />
          ))}
          <Pressable style={styles.removeButton} onPress={onRemove} accessibilityRole="button" accessibilityLabel="Remove Extra Style">
            <Text style={styles.removeButtonText}>Remove style — back to classic lyrics</Text>
          </Pressable>
        </View>
      ) : null}
    </View>
  );
}

type CategoryFilter = 'all' | ExtraStyleCategory;

export default function ExtraStylesScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const [catalog, setCatalog] = useState<ExtraStyleCatalog | null | undefined>(undefined);
  const [clipUri, setClipUri] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [category, setCategory] = useState<CategoryFilter>('all');
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [visibleIds, setVisibleIds] = useState<ReadonlySet<string>>(new Set());

  useEffect(() => {
    let alive = true;
    void getCachedExtraStyleCatalog().then((fetched) => {
      if (alive) setCatalog(fetched);
    });
    void resolveSampleClipUri().then((uri) => {
      if (alive) setClipUri(uri);
    });
    return () => {
      alive = false;
    };
  }, []);

  const selectedStyleId = studio.extraStyle?.styleId ?? '';
  const favoriteIds = useMemo(
    () => studio.extraStyle?.favoriteStyleIds ?? [],
    [studio.extraStyle?.favoriteStyleIds],
  );

  // Selection expands its card: selectStyle sets expandedId, and
  // the remove handler clears it — no effect needed here.

  const allStyles = useMemo(
    () => (catalog ? userVisibleStyles(catalog) : []),
    [catalog],
  );

  const filtered = useMemo(() => {
    let list = allStyles;
    if (category !== 'all') list = filterExtraStylesByCategory({ styles: list, bridgeVersion: 1, registryVersion: 1 }, category);
    if (query.trim().length > 0) {
      list = searchExtraStyleCatalog({ styles: list, bridgeVersion: 1, registryVersion: 1 }, query);
    }
    return sortExtraStylesWithFavoritesFirst(list, favoriteIds);
  }, [allStyles, category, query, favoriteIds]);

  const featured = useMemo(() => {
    const demoIds = new Set(STYLE_CAPABILITY_MAP.filter((s) => s.demo).map((s) => s.id));
    return allStyles.filter((s) => demoIds.has(s.id));
  }, [allStyles]);

  const recent = useMemo(() => {
    const byId = new Map(allStyles.map((s) => [s.id, s]));
    return studio.recentExtraStyleIds
      .map((id) => byId.get(id))
      .filter((s): s is ExtraStyleMetadata => !!s);
  }, [allStyles, studio.recentExtraStyleIds]);

  const onViewableItemsChanged = useCallback(
    ({ viewableItems }: { viewableItems: { item: ExtraStyleMetadata }[] }) => {
      setVisibleIds(new Set(viewableItems.map((v) => v.item.id)));
    },
    [],
  );

  const selectStyle = useCallback(
    (meta: ExtraStyleMetadata) => {
      studio.setExtraStyle({
        styleId: meta.id,
        styleVersion: meta.version,
        params: defaultParams(meta.parameters),
      });
      studio.recordRecentExtraStyle(meta.id);
      setExpandedId(meta.id);
    },
    [studio],
  );

  const toggleExpand = useCallback((meta: ExtraStyleMetadata) => {
    setExpandedId((current) => (current === meta.id ? null : meta.id));
  }, []);

  const applyPreset = useCallback(
    (meta: ExtraStyleMetadata, presetId: string) => {
      const preset = meta.presets?.find((p) => p.id === presetId);
      if (!preset) return;
      studio.updateExtraStyleParams(applyExtraStylePreset(meta.parameters, preset).params);
    },
    [studio],
  );

  const onParam = useCallback(
    (_meta: ExtraStyleMetadata, patch: Record<string, ExtraStyleParamValue>) => {
      studio.updateExtraStyleParams(patch);
    },
    [studio],
  );

  const renderCard = useCallback(
    ({ item }: { item: ExtraStyleMetadata }) => (
      <StyleCard
        meta={item}
        isSelected={item.id === selectedStyleId}
        isExpanded={expandedId === item.id}
        isFavorite={favoriteIds.includes(item.id)}
        isVisible={visibleIds.has(item.id)}
        clipUri={clipUri}
        liveParams={item.id === selectedStyleId ? (studio.extraStyle?.params ?? null) : null}
        onSelect={selectStyle}
        onToggleExpand={toggleExpand}
        onToggleFavorite={(meta) => studio.toggleFavoriteExtraStyle(meta.id)}
        onRemove={() => {
          studio.setExtraStyle(null);
          setExpandedId(null);
        }}
        onPreset={applyPreset}
        onParam={onParam}
      />
    ),
    [selectedStyleId, expandedId, favoriteIds, visibleIds, clipUri, studio, selectStyle, toggleExpand, applyPreset, onParam],
  );

  const listHeader = useMemo(
    () => (
      <View>
        {studio.extraStyleNotices.length > 0 ? (
          <View style={styles.noticeBox}>
            {studio.extraStyleNotices.map((notice, i) => (
              <Text key={`${i}-${notice.slice(0, 24)}`} style={styles.noticeText}>
                {notice}
              </Text>
            ))}
            <Pressable onPress={studio.clearExtraStyleNotices} accessibilityRole="button" accessibilityLabel="Dismiss notices">
              <Text style={styles.noticeDismiss}>Dismiss</Text>
            </Pressable>
          </View>
        ) : null}
        <Text style={styles.intro}>
          Animated scenes over your video — not subtitles. Pick one and it shows up in the editor
          preview and your export. Your lyrics stay exactly as they are.
        </Text>
        <TextInput
          style={styles.search}
          value={query}
          onChangeText={setQuery}
          placeholder="Search styles…"
          placeholderTextColor={colors.labelTertiary}
          accessibilityLabel="Search Extra Styles"
        />
        <View style={styles.chips}>
          <Pressable
            style={[styles.chip, category === 'all' && styles.chipSelected]}
            onPress={() => setCategory('all')}
            accessibilityRole="button"
            accessibilityLabel="All categories">
            <Text style={[styles.chipText, category === 'all' && styles.chipTextSelected]}>All</Text>
          </Pressable>
          {EXTRA_STYLE_CATEGORIES.map((c) => (
            <Pressable
              key={c.id}
              style={[styles.chip, category === c.id && styles.chipSelected]}
              onPress={() => setCategory(c.id)}
              accessibilityRole="button"
              accessibilityLabel={`Category ${c.label}`}>
              <Text style={[styles.chipText, category === c.id && styles.chipTextSelected]}>{c.label}</Text>
            </Pressable>
          ))}
        </View>
        {query.trim().length === 0 && category === 'all' && featured.length > 0 ? (
          <View>
            <Text style={styles.sectionTitle}>Featured</Text>
            {featured.map((meta) => (
              <StyleCard
                key={meta.id}
                meta={meta}
                isSelected={meta.id === selectedStyleId}
                isExpanded={expandedId === meta.id}
                isFavorite={favoriteIds.includes(meta.id)}
                isVisible={visibleIds.has(meta.id)}
                clipUri={clipUri}
                liveParams={meta.id === selectedStyleId ? (studio.extraStyle?.params ?? null) : null}
                onSelect={selectStyle}
                onToggleExpand={toggleExpand}
                onToggleFavorite={(m) => studio.toggleFavoriteExtraStyle(m.id)}
                onRemove={() => {
                  studio.setExtraStyle(null);
                  setExpandedId(null);
                }}
                onPreset={applyPreset}
                onParam={onParam}
              />
            ))}
          </View>
        ) : null}
        {query.trim().length === 0 && category === 'all' && recent.length > 0 ? (
          <View>
            <Text style={styles.sectionTitle}>Recently used</Text>
            <View style={styles.chips}>
              {recent.map((meta) => (
                <Pressable
                  key={meta.id}
                  style={styles.chip}
                  onPress={() => selectStyle(meta)}
                  accessibilityRole="button"
                  accessibilityLabel={`Use ${meta.name} again`}>
                  <Text style={styles.chipText}>{meta.name}</Text>
                </Pressable>
              ))}
            </View>
          </View>
        ) : null}
        <Text style={styles.sectionTitle}>
          {category === 'all' ? 'All styles' : EXTRA_STYLE_CATEGORIES.find((c) => c.id === category)?.label ?? 'Styles'}
          {filtered.length > 0 ? ` · ${filtered.length}` : ''}
        </Text>
      </View>
    ),
    [
      query,
      category,
      featured,
      recent,
      filtered.length,
      selectedStyleId,
      expandedId,
      favoriteIds,
      visibleIds,
      clipUri,
      selectStyle,
      toggleExpand,
      applyPreset,
      onParam,
      studio,
    ],
  );

  return (
    <View style={[styles.root, { paddingTop: insets.top }]}>
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} accessibilityRole="button" accessibilityLabel="Back to editor">
          <Ionicons name="chevron-back" size={26} color={colors.label} />
        </Pressable>
        <Text style={styles.title}>Extra Styles</Text>
        <Pressable onPress={() => router.back()} accessibilityRole="button" accessibilityLabel="Done">
          <Text style={styles.done}>Done</Text>
        </Pressable>
      </View>
      {catalog === undefined ? (
        <View style={styles.center}>
          <ActivityIndicator color={colors.accent} />
          <Text style={styles.centerText}>Loading styles…</Text>
        </View>
      ) : catalog === null ? (
        <View style={styles.center}>
          <Text style={styles.centerText}>
            Extra Styles need the native engine — this preview build can&apos;t render them yet.
            Install the device build and they&apos;ll be here.
          </Text>
        </View>
      ) : (
        <FlatList
          data={filtered}
          keyExtractor={(item) => item.id}
          renderItem={renderCard}
          ListHeaderComponent={listHeader}
          onViewableItemsChanged={onViewableItemsChanged}
          viewabilityConfig={{ itemVisiblePercentThreshold: 50 }}
          contentContainerStyle={[styles.list, { paddingBottom: insets.bottom + spacing.lg }]}
          ListEmptyComponent={
            <Text style={styles.centerText}>No styles match that search.</Text>
          }
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.base },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  title: { ...typeScale.title2, color: colors.label },
  done: { ...typeScale.body, color: colors.accent, fontWeight: '600' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.lg },
  centerText: { ...typeScale.body, color: colors.labelSecondary, textAlign: 'center', marginTop: spacing.sm },
  list: { paddingHorizontal: spacing.md },
  intro: { ...typeScale.body, color: colors.labelSecondary, marginBottom: spacing.md },
  noticeBox: {
    backgroundColor: colors.elevated,
    borderRadius: radius.md,
    padding: spacing.md,
    marginBottom: spacing.md,
  },
  noticeText: { ...typeScale.body, color: colors.label, marginBottom: spacing.xs },
  noticeDismiss: { ...typeScale.body, color: colors.accent, fontWeight: '600' },
  search: {
    backgroundColor: colors.elevated,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    color: colors.label,
    ...typeScale.body,
    marginBottom: spacing.sm,
  },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xs, marginBottom: spacing.sm },
  chip: {
    backgroundColor: colors.elevated,
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs,
  },
  chipSelected: { backgroundColor: colors.accent },
  chipText: { ...typeScale.body, color: colors.label },
  chipTextSelected: { color: colors.onAccent, fontWeight: '600' },
  sectionTitle: { ...typeScale.headline, color: colors.label, marginTop: spacing.md, marginBottom: spacing.sm },
  card: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    marginBottom: spacing.sm,
    overflow: 'hidden',
  },
  cardSelected: { borderWidth: 1, borderColor: colors.accent },
  cardRow: { flexDirection: 'row', alignItems: 'center', padding: spacing.sm },
  previewBox: {
    width: 96,
    height: 170,
    borderRadius: radius.md,
    overflow: 'hidden',
    backgroundColor: colors.elevated,
  },
  previewVideo: { width: '100%', height: '100%' },
  previewPlaceholder: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  selectedBadge: {
    position: 'absolute',
    top: spacing.xs,
    right: spacing.xs,
    width: 20,
    height: 20,
    borderRadius: 10,
    backgroundColor: colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
  cardText: { flex: 1, marginLeft: spacing.md },
  cardName: { ...typeScale.headline, color: colors.label },
  cardTagline: { ...typeScale.body, color: colors.labelSecondary, marginTop: 2 },
  cardCategory: { ...typeScale.caption, color: colors.labelTertiary, marginTop: spacing.xs, textTransform: 'capitalize' },
  heart: { padding: spacing.xs },
  controls: { padding: spacing.md, paddingTop: 0 },
  paramBlock: { marginBottom: spacing.md },
  paramLabelRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: spacing.xs },
  paramLabel: { ...typeScale.body, color: colors.label },
  paramValue: { ...typeScale.body, color: colors.labelSecondary },
  swatches: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xs, marginTop: spacing.xs },
  swatch: { width: 32, height: 32, borderRadius: 16, borderWidth: 1, borderColor: colors.separator },
  swatchSelected: { borderWidth: 2, borderColor: colors.label },
  stepper: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  stepperButton: {
    width: 32,
    height: 32,
    borderRadius: 16,
    backgroundColor: colors.elevated,
    alignItems: 'center',
    justifyContent: 'center',
  },
  removeButton: { paddingVertical: spacing.sm, alignItems: 'center' },
  removeButtonText: { ...typeScale.body, color: colors.danger },
});
