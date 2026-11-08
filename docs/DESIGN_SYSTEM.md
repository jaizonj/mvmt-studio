# MVMT Studio — Design System & UX Specification

Wave 1 · Agent Design · 2026-11-08 · Status: **specification for implementation**
Companion docs: `docs/IMPLEMENTATION.md` (programme, contracts, ownership),
`mvmt-media-architecture-audit.md` (baseline findings).

This document is the single source of truth for what MVMT Studio looks
like, how it is organised, and how every screen behaves after the
overhaul. It is written to be built from without follow-up questions:
where a behaviour is specified, build exactly that; where something is
marked **DEFERRED**, do not build a placeholder for it.

## How to read this spec

- **Tokens are referenced by NAME from `src/theme.ts`** (`colors.accent`,
  `spacing.lg`, `radius.md`, `type.headline`, …). Never hardcode a hex
  value, a raw rgba, or a font size in a screen. If a value you need is
  not in `theme.ts`, stop and flag it — do not improvise a literal.
  (Several current screens hardcode `#FFFFFF` button backgrounds and
  `#14141F` text from the retired palette; those are bugs under this
  spec, see §6.)
- **MUST** = acceptance criteria. **SHOULD** = build unless it conflicts
  with a MUST. **DEFERRED** = explicitly out of scope for this overhaul.
- **Data vocabulary**: the edit is the canonical EDL (`src/lib/edl.ts`,
  integer frames at the project fps, 30 by default). UI code speaks in
  frames when touching the EDL and in seconds only at display boundaries
  (`formatTime`). Preview and export both consume
  `edlToCompositeRequest(...)` via the native v2 API
  (`modules/mvmt-compositor/src/index.ts`): `createPreview`,
  `setPreviewPaused`, `seekPreview`, `releasePreview`,
  `addPreviewProgressListener`, `addPreviewStatusListener`,
  `renderVideo`, `cancelExport`, `addExportProgressListener`,
  `inspectAsset`. No screen may invent a second playback or render path.
- **Copy rule**: users never see engineering words. Banned in UI copy:
  *EDL, frame(s) as a unit, composition, render pipeline, offset in ms,
  sync drift, segment, canvas*. Approved vocabulary: *song, part, take,
  cut, video, in sync*. Numbers users see are times (`formatTime`),
  counts, and percentages only.

---

## 1. Product identity & principles

MVMT Studio is a premium, music-first video creation studio: pick a
song, perform it in takes, and get a cut that feels edited — then export
one finished video. It should feel like it was designed by one team, in
one pass, for one purpose.

**References, and what we take from each (we copy none of them):**

| Reference | What MVMT takes |
| --- | --- |
| Apple Camera | Capture clarity: the picture is the interface; controls are few, obvious, and where thumbs expect them. |
| Final Cut Pro | Editor gravity: a real timeline, a real playhead, selections that mean something. The editor is a workspace, not a form. |
| CapCut | Approachability: every action is one tap from obvious; nothing needs a manual; friendly defaults everywhere. |
| Premium music software | Identity: dark, confident, one signal colour, generous negative space, media first. |

**Design principles (in priority order when they conflict):**

1. **The media is the interface.** Previews and camera picture get the
   largest area on every screen. Chrome shrinks before media does.
2. **One accent, used sparingly.** `colors.accent` (acid lime) means
   *primary action, selection, or "this is live"*. If everything is
   lime, nothing is. Text is `colors.label`; structure is graphite.
3. **One way to do each thing.** Every capability has exactly one home
   (§2). If a control exists in two places, one of them is removed.
4. **Defaults do the work.** A first-time user goes song → record →
   cut → export without opening Settings or making a technical choice.
   Configuration exists, but it is never on the critical path.
5. **Honest UI.** Nothing is shown that does not work: no dead buttons,
   no decorative data (no fake waveforms, no scores), no progress that
   is not measured. Loading states say what is actually happening.
6. **Calm motion.** Animation explains state changes; it never decorates
   and never delays or jitters media playback (§4).
7. **The flow is self-explanatory.** There is no step indicator, no
   "you are here" banner, no status narration (standing product rule —
   the Record → Takes → Editor → Export stages are navigated by one
   obvious forward action per screen, §2.3).

**Explicitly avoided** (each maps to a cull item in §6):

- Gradients on surfaces. The only gradient in the product is
  `colors.iridescent` (the lime ramp), used in exactly two places: the
  record-button ring and the editor's brief "new cut" sweep (§3.5).
- Glassmorphism as a theme. Translucency (`colors.material`) exists
  only where UI floats over live camera/video, so the picture shows
  through. It is never used on plain screens.
- Card clutter. Grouped lists on `colors.card` are the default
  container; a screen has at most one level of container nesting.
- Competing accent colours. No violet/blue/pink/mint segment colours,
  no white primary buttons, no per-feature colour coding. Semantic
  colour is limited to `colors.danger` (destructive/recording) and
  `colors.success` (confirmation/sync OK), always paired with an icon
  or words, never colour alone.
- Duplicated controls (the same setting in a sheet, a screen, and a
  pill). Settings has one home (§3.7).
- Technical language and technical choices on the creation path (§3.2).

**Visual constants** (from `theme.ts`, restated for convenience — the
file wins if they ever differ):

- Surfaces: `colors.base` / `colors.groupedBackground` (#101114) page,
  `colors.card` (#17181D) grouped content, `colors.cardPressed` pressed
  state, `colors.elevated` (#1D1E24) sheets/popovers over content,
  hairline `colors.separator` between rows.
- Text: `colors.label` (#F4F1E9), `colors.labelSecondary` (supporting),
  `colors.labelTertiary` (captions/timestamps only — never interactive
  text, §7).
- Accent: `colors.accent` (#C9F36B) with `colors.onAccent` (#14160C)
  for anything drawn on it.
- Type: system font only. `type.largeTitle` screen titles,
  `type.title2` section titles, `type.headline` row titles/emphasis,
  `type.body` body, `type.subhead` subtitles, `type.footnote` hints,
  `type.caption` micro-labels. No other sizes.
- Spacing: `spacing.xs…xxxl` (4/8/12/16/20/28/40). Screen horizontal
  inset is `spacing.xl`; section gap is `spacing.xl`; row padding is
  `spacing.md` vertical / `spacing.lg` horizontal.
- Radius: `radius.sm` thumbnails/chips-in-editor, `radius.md` cards,
  buttons and tiles, `radius.lg` large cards/preview frames,
  `radius.sheet` sheets, `radius.pill` pills and primary buttons where
  specified.

---

## 2. Information architecture

### 2.1 Structure

Three primary tabs. One project workspace, entered from Studio or
Projects, which is a stack — **the workspace stages are NOT tabs** and
never appear in the tab bar.

```
TAB BAR (always visible outside the workspace)
├── Studio        (home: brand, New Project, Continue, Recent)
├── Projects      (all projects, manage)
└── Settings      (configuration only)

PROJECT WORKSPACE (stack, full-screen, tab bar hidden)
├── Record        (camera — the project's front door)
├── Takes         (review / manage takes)
├── Editor        (Auto Edit ⇄ Manual Edit — one screen, two modes)
└── Export        (finish: preview, render, save/share)
```

Modals/sheets (never routes in the tab bar): Song picker (system file
picker), Project options (rename/delete), Take preview, Take options
(rename/delete), Trim editor (in-place in Editor), Share sheet (system).

### 2.2 Navigation diagram

```
                        ┌─────────────┐
            ┌───────────│   STUDIO    │────────────┐
            │           └─────────────┘            │
     [New Project]                            [Recent project /
            │                                  Continue card]
            ▼                                         │
   ┌──────────────────┐                               │
   │ PROJECT CREATION │  song → part → start          │
   └────────┬─────────┘                               │
            │ creates project, lands in               ▼
            │                              ┌─────────────────────┐
            └─────────────────────────────▶│  WORKSPACE: RECORD  │◀──┐
                                           └─────────┬───────────┘   │
                                    Takes (bottom-left)│  Next        │ back
                                                     ▼              │
                                           ┌──────────────────┐     │
                                           │      TAKES       │─────┘
                                           └────────┬─────────┘
                                          "Make my cut"│
                                                     ▼
                                           ┌──────────────────┐
                                           │      EDITOR      │
                                           │  Auto ⇄ Manual   │
                                           └────────┬─────────┘
                                                Export│
                                                     ▼
                                           ┌──────────────────┐
                                           │      EXPORT      │
                                           └────────┬─────────┘
                                       Save/Share · Done│
                                                     ▼
                                          back to STUDIO/Projects

   PROJECTS tab ── tap project ──▶ workspace at the stage the project
                                   was last left in (Record if it has
                                   no takes, Editor if it has a cut)
   SETTINGS tab ── standalone; nothing in the workspace depends on it
                   being visited.
```

Navigation mechanics:

- Tabs: Expo Router tabs, crossfade on switch. Tab bar: `colors.base`
  background, hairline top border `colors.separator`, icons + labels,
  active tint `colors.accent`, inactive `colors.labelTertiary`. Icons:
  `home` (Studio), `folder` / `albums` (Projects), `settings` gear
  outline (Settings) — outline style when inactive, filled when active,
  matching the existing Ionicons usage.
- Entering a workspace pushes it over the tabs (tab bar hidden) so the
  camera and editor are full-bleed.
- Inside the workspace: forward = the one primary action at the bottom
  of each stage (§2.3); back = the header chevron, always available,
  never destructive. Stage transitions are native stack pushes
  (`slide_from_right`, iOS-standard) — this replaces the current
  `slide_from_bottom` stage animation. Sheets keep iOS page-sheet
  presentation.
- Exiting the workspace (back from Record) returns to whichever tab
  launched it, with the project saved (autosave, §3.7).

### 2.3 The workspace stage pattern (applies to all four stages)

Every stage screen is built from the same three bands:

1. **Header band**: back chevron (`colors.accent`, label = previous
   stage or "Studio"), then `type.largeTitle` stage title, then a
   `type.subhead` `colors.labelSecondary` subtitle carrying the one
   useful fact (song name on Record/Takes, "12 cuts · 0:30" on Editor,
   "Ready when you are" on Export). No gear icon in workspace headers —
   Settings lives in the tab (§3.7). No stage indicator, no progress
   dots, no locks on forward actions that are explained by an empty
   state instead (see gating below).
2. **Content band**: the stage's work (camera / list / preview+timeline
   / preview+options).
3. **Action band**: pinned above the bottom safe area, hairline top
   border `colors.separator`, `colors.groupedBackground` fill. Contains
   exactly ONE primary button (`PrimaryButton`, §5) — the stage's
   forward action — and optionally one `type.caption`
   `colors.labelTertiary` line under it. Nothing else competes with it.

Gating, restated as empty states rather than disabled chrome: a stage
whose precondition is missing shows its `EmptyState` (§5) with the one
action that fixes it (e.g. Takes with no takes → "Record a take first"
→ button back to Record). Export is unreachable with an empty cut
because Editor's Export action only exists once a cut exists. This
preserves the current gating behaviour; only the presentation changes.

### 2.4 The complete user journey (first launch → exported video)

1. **First launch** → Studio tab, empty state: wordmark, one line
   ("Make a music video to a song you love."), one primary action:
   **New Project**. No onboarding carousel, no account, no permissions
   ask up front (camera/mic are requested in context, at Record).
2. **New Project** → creation flow (§3.2): pick a song (system picker)
   → hear it, choose the part (15s / 30s / 1 min / 3 min / Full) →
   **Start recording**. Three screens, no choices a beginner can't
   understand. A project now exists (title = song name).
3. **Record** (§3.3): camera fills the screen, song loaded. Tap the
   record button; the song plays, the take records for exactly the
   chosen part and stops itself. Repeat for 2+ takes (the take counter
   makes "how many do I have" always visible). Tap **Next**.
4. **Takes** (§3.4): glance over the takes (thumbnails), delete any dud,
   tap **Make my cut**.
5. **Editor, Auto mode** (§3.5): one tap on **Shuffle my cut** → brief
   lime sweep → the cut plays in the big preview above the timeline.
   **Try another** re-rolls; **Cut pace** changes how often it cuts.
   Tap **Use this cut** (or just carry on — the latest cut is always
   the project's cut) → **Export**.
6. **Optional refine — Manual mode**: tap any cut in the timeline to
   swap its take, drag its edges to trim, split at the playhead, undo.
   The preview is the same native composition, so what plays is what
   exports.
7. **Export** (§3.6): final preview, quality choice (defaulted), **Save
   video** → real progress with Cancel → completion shows the actual
   measured length, **Save to Photos** done-for-you state + **Share**.
   **Done** returns to Studio, where the project now sits in Recent
   with its thumbnail.

Returning users: Studio shows **Continue** (most recent project, one
tap back into its workspace at the right stage) and **Recent
Projects**; Projects tab holds everything.

---

## 3. Screen specifications

### 3.1 Studio (home tab)

Purpose: say "this is where music videos get made" in one glance, and
put *starting* and *resuming* one tap away. No dashboards, no stats, no
tips carousel.

Layout (top → bottom, `spacing.xl` side insets, scrolls if needed):

1. **Brand block** (`spacing.xxxl` top padding below the safe area):
   - Wordmark "MVMT" in `type.largeTitle` `colors.label`, tight and
     plain — no logo lockup, no gradient text. Under it, `type.subhead`
     `colors.labelSecondary`: "Studio" is redundant — the line is the
     product promise: **"Your song. Your performance. One cut."**
     (Final copy may be tuned by the lead; keep it one line, music-first.)
2. **New Project** — `PrimaryButton` (§5), full width, label
   **"New Project"**, icon `add`. This is the loudest element on the
   screen after the wordmark.
3. **Continue** (only if a most-recent project exists): a wide card
   (`ProjectCard`, horizontal variant): 64×64 `radius.sm` thumbnail
   (the project's cover frame, §3.1.1), project title (`type.headline`,
   1 line), subtitle `type.footnote` `colors.labelSecondary`
   ("{song name} · {n} takes · {stage-aware state}"), trailing chevron.
   Stage-aware state copy: "Ready to record" / "Ready to edit" /
   "Ready to export" / "Exported". Tapping enters the workspace at
   that stage.
4. **Recent Projects** (if ≥2 projects): `type.title2` heading
   "Recent", then a vertical list of `ProjectCard`s (same component,
   list variant), most-recent first, maximum 5 + a "See all in
   Projects" text row if more exist.
5. Bottom breathing room `spacing.xxxl`. Nothing else on this screen.

Empty state (no projects at all): brand block, then `EmptyState`
(icon `musical-notes-outline`, title "Make your first music video",
body "Pick a song, record yourself performing it, and MVMT cuts the
takes together for you."), then the New Project button directly under
it. Continue/Recent sections are absent, not greyed.

#### 3.1.1 Project thumbnails

A project's thumbnail is a real frame: the cover clip's take at its
first frame (the project already tracks a cover clip), else the first
take's first frame, else — a project with a song but no takes — a flat
`colors.card` tile with a centred `musical-notes` icon in
`colors.labelTertiary`. Thumbnails load through the existing thumbnail
pipeline (`src/lib/thumbnails.ts`); placeholders are `colors.elevated`,
never coloured. Aspect: cards crop-fill (`contentFit="cover"`), never
stretch.

#### 3.1.2 Projects tab

The full library; Studio's Recent is a window into this list.

- Header: `type.largeTitle` "Projects", subtitle "{n} projects".
- List of `ProjectCard`s (list variant, 72×72 thumbnail), sorted by
  last opened, newest first. Row content: title (editable, §below),
  subtitle "{song} · {n} takes · {updated, relative — "Today", "Yesterday", or a date}".
- Row tap → workspace at the project's stage. Row long-press (and an
  iOS-style swipe-left) → destructive **Delete project** (confirm
  alert: "Delete {title}? Its takes and cut will be removed from
  MVMT. Videos you saved to Photos stay there."). Rename lives on the
  project itself: tapping the title in the workspace Record header's
  subtitle is NOT editable; rename is in the Projects row's context
  menu (`ellipsis-horizontal` button per row → Rename / Delete).
  Keep it to those two actions.
- Empty state: `EmptyState` (icon `folder-open-outline`, "No projects
  yet", "Projects you create will live here.") + New Project button.
- No search, no sort controls, no grid/list toggle — the library is
  personal and small; chrome would be clutter (revisit only if the
  lead sees evidence of large libraries).

### 3.2 Project creation flow

A three-step stack pushed over the tabs (header: close `×` top-left
which abandons creation with no project created; step title in
`type.headline`; NO step indicator — each screen's title says what it
is). Every step has exactly one primary action in the action band.

**Step 1 — Song.** Title: "Pick your song".
- `PrimaryButton` "Choose a song" opens the system audio file picker
  (existing `pickAudioTrack`). On selection the file is copied into
  the project (existing behaviour) and the step advances automatically.
- Under it, `type.footnote` `colors.labelSecondary`: "Use a song you
  have the rights to post. It stays on your phone — MVMT doesn't
  upload it."
- If the pick fails or is cancelled, stay on this step with an inline
  `type.footnote` `colors.danger` line — no modal alert for a cancel.

**Step 2 — Part.** Title: "Choose the part". Subtitle: song name.
- Song preview: one row — round play/pause button (`IconButton`,
  44pt, `colors.card` fill) + song name + total duration. Tapping
  plays the currently selected part and stops at its end (existing
  region-preview behaviour); the button flips to pause while playing.
- Part choices: the five existing length presets as full-width
  selectable rows OR the existing preset chips — implementer's choice
  is FIXED here: use the `AudioRegionPicker` as-is for geometry
  (preset chips 15s / 30s / 1 min / 3 min / Full + draggable window),
  because recording, region and editor already read that one
  component's value. Chips: selected = `colors.accent` fill /
  `colors.onAccent` text; unselected = `colors.card` fill /
  `colors.label` text. Selected window summary in words under the
  picker: "You'll record 0:15 to 0:45 of the song." (`formatTime`.)
- HONESTY RULE: the picker's bars are currently a stand-in pattern,
  not the song's real waveform (§6). Until real peaks exist, the bars
  render in `colors.elevated` with the window in `colors.accentDim` —
  a neutral selector graphic, not a fake waveform with fake detail.
  Do not label it "waveform".
- Primary action: **"Start recording"** → creates the project and
  lands on Record with the region set.
- Format: the project format is Portrait 9:16, 1080×1920 (the EDL
  canvas) — shown as a static info row on this step ("Format ·
  Portrait 9:16"), NOT a choice. The engine supports exactly one
  canvas today; offering formats that don't exist violates §1.5.
  (When the engine grows formats, this row becomes a selector —
  DEFERRED until then.)

**Step 3** does not exist: creation ends by entering Record (§3.3)
with the song and part set. Project title defaults to the song name
(minus extension); rename lives in Projects (§3.1.2).

What creation deliberately never asks: resolution, frame rate, quality,
offsets, formats. Those are Settings defaults (§3.7) or engine facts.

### 3.3 Record (workspace stage 1 — the camera)

The camera IS the screen. Full-bleed `CameraView`; everything else
floats over it in `colors.material` with `colors.materialBorder`
hairlines. Layout is the current, device-tested arrangement — this spec
ratifies and re-skins it; do not redesign the geometry.

```
┌──────────────────────────────────────────────┐
│ [⚙ →Settings]   ( song pill )    [⚡] [⟲]    │ top bar, below safe area
│                                              │
│                          ┌─────────┐         │
│                          │  zoom   │ right   │
│                          │  pill   │ column  │
│                          ├─────────┤ (top    │
│                          │ timers  │  36%)   │
│                          │  pill   │         │
│                          └─────────┘         │
│        ( countdown / count-in overlay )      │
│        ( ● elapsed pill — while recording )  │
│                                              │
│        [ 15s ][ 30s ][ 1m ][ 3m ][ Full ]    │ length row, bottom-centre
│  [ Takes · n ]      ( ● )       [ Next ]     │ bottom bar
└──────────────────────────────────────────────┘
```

- **Top bar** (current positions): left = settings gear `IconButton`
  — BEHAVIOUR CHANGE: it navigates to the Settings tab (§3.7), it no
  longer opens a duplicate settings sheet. Centre = track pill
  (`colors.material`, radius.pill): music-note icon + song name
  (1 line, truncated) + duration; tap = the track/part sheet
  (`TrackSheet` + `AudioRegionPicker`, reused as-is) for changing the
  song or part mid-project. Right = torch `IconButton` (active state
  `colors.accent` icon) and flip-camera `IconButton` (disabled while
  recording).
- **Right column** (top 36%, `spacing.md` from the right edge) — the
  established two collapsible pills, in this order, mutually exclusive
  (opening one closes the other):
  1. **Zoom pill**: collapsed shows current preset ("1×"); expands to
     1× / 2× / 3× / 5× options (existing presets). Selected option =
     `colors.accent`-tinted fill. Pinch-to-zoom also works and updates
     the pill.
  2. **Timers pill**: collapsed shows a timer icon + summary ("Timer"
     when both are off, else e.g. "3s · ♪4"). Expands to a
     `colors.material` panel (`radius.lg`) with two labelled rows —
     "Timer" chips Off / 3s / 5s / 10s and "Count-in" chips Off / 4 / 8
     — selected chip = near-white fill with dark text (existing
     pattern) or `colors.accent`; pick ONE: use the same selected style
     as the zoom pill for consistency. Timer and count-in both default
     OFF (standing rule). Changing a value shows the existing transient
     notice ("Timer 3s — beeps each second").
- **Length row** (bottom-centre, above the bottom bar; only when a
  song is loaded): the five part-length chips (15s / 30s / 1 min /
  3 min / Full) in one `colors.material` pill container — same value as
  creation Step 2 / track sheet (single source: `trackRegion`). A chip
  longer than the song is disabled at 35% opacity. These exist because
  changing the part shouldn't require leaving the camera.
- **Bottom bar**: three elements, `spacing.xxl` side insets.
  - Left: **Takes button** — `colors.material` rounded tile
    (`radius.lg`), film icon, label "Takes · {n}" — the take counter
    is part of this label, always current. With 0 takes it shows
    "Takes" and tapping shows the notice "Record a take first"
    (existing gating copy) instead of navigating.
  - Centre: **RecordButton** (76pt): `colors.iridescent` ring (the
    sanctioned gradient), inner white ring, centre dot. Idle → red
    dot is NOT used; the dot is white-ring/red-centre per the current
    component — restated precisely: idle centre = `colors.danger`
    filled circle inside the white ring; recording → centre becomes a
    `colors.danger` rounded square (stop affordance). Press feedback:
    scale 0.94 (existing). One haptic on start, one on stop (§4).
  - Right: **Next button** — same tile style as Takes, forward-arrow
    icon, label "Next"; with 0 takes, tapping shows "Record a take
    first". Next goes to Takes (the flow's next stage).
- **Overlays** (all `pointerEvents="none"`, centred):
  - Timer countdown: huge numeral (`countdownNumber` scale ~120pt,
    `colors.label`, soft shadow) + caption "GET READY" — the word
    TIMER is dropped; the beeps + numeral are self-explanatory.
  - Count-in: numeral in `colors.accent` + caption "COUNT-IN".
  - Recording: elapsed pill (`colors.material`): `colors.danger` dot
    (pulsing while recording, §4) + elapsed time in tabular numerals,
    e.g. "0:07". If a part length is set, show "0:07 / 0:15". This
    pill is information the performer needs mid-take; it is not a
    stage indicator.
  - Metronome beat dot (when enabled in Settings): small dot beside
    the elapsed pill, flashes `colors.accent` on the beat.
  - Notices: transient pill under the recording pill position for
    one-line feedback ("Timer 3s — beeps each second", "Saved to
    Photos", camera errors). Auto-dismiss ~2.2s. This is the camera's
    ONLY toast mechanism.
- **Framing guides** (Settings-driven, off by default): rule-of-thirds
  hairlines at 35% white; centre level line + dot in `colors.accent`
  at 65% opacity. Over the picture only, never over controls.
- **Recording behaviour** (unchanged mechanics, specified so the UI
  states are complete): record starts after timer + count-in (cued by
  the existing beep/click/go sounds); recording stops automatically
  at the part length — the song is the clock — or early on a second
  press. While recording: zoom/timers/length/flip hide; Takes/Next
  hide; only the elapsed pill and the stop button remain. When a take
  finishes: brief notice "Take {n} saved" — no navigation, no modal;
  the counter increments. The user records the next take or taps Next.
- **Permissions state**: if camera/mic not granted, the whole screen
  is the existing permission view re-skinned: `colors.base` bg,
  videocam icon, "Camera & microphone" (`type.title2`), one-line body
  (nothing is uploaded), `PrimaryButton` "Allow access". Denied-forever
  state adds a footnote: "You can turn these on later in iOS Settings
  → MVMT."
- **No song loaded state**: camera still fills the screen; the track
  pill reads "Add a song" with an `add` icon and tapping it opens the
  track sheet; the length row is hidden; pressing record with no song
  records a silent take? — NO: record is disabled (RecordButton
  `disabled` at 40% opacity) and its tap shows the notice "Add a song
  first — takes are recorded to the music." MVMT takes are defined by
  the song; a silent-take mode is DEFERRED (not in the directive's
  journey).

### 3.4 Takes (workspace stage 2)

Purpose: trust and housekeeping — see what you shot, drop the duds,
know it's all in sync — then move on. One list, one forward action.

- Header per §2.3: back label "Record", title "Your takes", subtitle
  "{song name} · {n} takes".
- **Take rows** (`TakeRow`, §5) in ONE grouped card (`colors.card`,
  `radius.lg`, hairline separators) — replaces the current icon-only
  rows. Each row, left → right:
  1. **Thumbnail** 54×72 (portrait crop of the take), `radius.sm`,
     cover-fit; placeholder `colors.elevated`. A small duration badge
     sits on its bottom-right corner: `colors.material` chip,
     `type.caption`, `formatTime(duration)`.
  2. **Title block**: "Take {n}" (`type.headline`; numbering is
     chronological — Take 1 is the first recorded, and numbers never
     change when another take is deleted) and, if renamed, the custom
     name replaces "Take {n}" with the number kept as a prefix in the
     subtitle. Subtitle (`type.footnote`, `colors.labelSecondary`):
     "{Front|Back} camera · {time recorded, e.g. 2:41 pm}".
  3. **Sync line** (own line under the subtitle, `type.caption`):
     sync status in human words, from the take's MEASURED sync data
     (the overhaul stores the song position at capture start/end and a
     drift estimate per take):
     - measured and within tolerance → `colors.success` dot +
       "In sync with the song"
     - measured but outside tolerance, auto-corrected by the EDL
       mapping → dot `colors.labelTertiary` + "In sync · adjusted
       automatically" — only show the second clause when a correction
       was actually applied beyond one frame; never show numbers.
     - not measured (legacy takes from before the overhaul) →
       "Recorded to the song" (neutral, no dot colour claim).
     Exact thresholds belong to the sync workstream; the UI consumes a
     per-take status enum (`synced | adjusted | unmeasured`) — it
     never formats raw offsets.
  4. **In-cut badge**: if the take appears in the current cut, a small
     pill at the row's trailing edge: `colors.accentDim` fill,
     `colors.accent` text, "In your cut" (or "In your cut ×3" when it
     fills several cuts). Absence of the badge = not used. This is the
     row's selection state.
  5. **Overflow button** (`ellipsis-horizontal`, 44pt target): menu
     with Rename, Save to Photos, Share, Delete (destructive, last,
     `colors.danger`). Row-level icon-button trios are REMOVED (§6) —
     one overflow per row, everything else is a tap.
  - **Row tap** → **Take preview sheet**: the take plays full-width
    (native player, song underneath at the take's sync position so it
    previews *as it will be used*), with play/pause, its sync line,
    and the same four overflow actions at the bottom. Swipe-down or
    Done dismisses.
  - **Delete**: confirmation alert ("Delete Take {n}? It will also be
    removed from your cut." when it's in the cut; without the second
    sentence otherwise). Deleting re-lays the cut (existing store
    behaviour). No undo for delete — the confirmation is the guard.
  - **Rename**: alert-style text prompt or inline sheet field;
    max ~40 chars; empty = revert to "Take {n}".
- Under the card, one `type.footnote` hint (current copy is right,
  keep it): "Next, MVMT arranges these takes into a cut — then tap any
  cut in the timeline to switch which take it uses. Deleting a take
  also removes it from your cut."
- Action band: `PrimaryButton` **"Make my cut"** (shuffle icon) →
  Editor. Caption under it: "Then fine-tune it, and export".
- Empty state: per §2.3 ("Record a take first" → back to Record).
- Takes stage does NOT contain: per-take save/share icon rows, "add
  to cut" buttons (building a cut by hand now lives in the Editor's
  Manual mode), energy/motion stats, file sizes, or any raw metadata.

---

### 3.5 Editor (workspace stage 3 — the centerpiece)

One screen, two modes, one timeline. The screen is named **Editor**;
"Shuffle" is the name of the Auto action inside it, not the screen.
(The current `/shuffle` screen is this screen's ancestor; the legacy
`/editor` redirect should land here too.)

**Fixed layout** (this screen does NOT scroll; it is a workspace):

```
┌────────────────────────────────────────────┐
│ ‹ Takes        Editor              ( ↩ )   │ header: back, title, undo
│                                            │
│         ┌────────────────────┐             │
│         │                    │             │
│         │   NATIVE PREVIEW   │  9:16,     │
│         │   (the cut plays   │  max area  │
│         │    exactly as it   │             │
│         │    will export)    │             │
│         └────────────────────┘             │
│      ▶  0:07 ━━━━━●───────── 0:15          │ transport row
│  [ Auto Edit │ Manual Edit ]               │ mode switch (segmented)
│   … mode panel (changes with mode) …       │
│  ┌──────────────────────────────────────┐  │
│  │ ruler ▏filmstrip cuts ▏filmstrip…    │  │ TIMELINE (both modes)
│  └──────────────────────────────────────┘  │
│  [            Export             ]         │ action band
└────────────────────────────────────────────┘
```

- **Preview**: the native composition player (`createPreview` on the
  EDL's composite request) in a 9:16 frame, `radius.lg`, black
  (`#000`) letterbox fill — the frame is as large as the width allows
  (on tall phones cap height so preview + transport + mode panel +
  timeline + action band all fit without scrolling; on small phones
  the preview shrinks first, §7). The preview is the SAME composition
  as export — one builder, one request (`edlToCompositeRequest`).
  Preview lifecycle states (from `PreviewStatus`): `loading` → centred
  spinner on black + caption "Preparing your cut…"; `error` → inline
  message + "Try again" button (rebuild the preview); `ready/paused/
  playing/ended` drive the transport only.
- **Transport row**: play/pause `IconButton` (44pt), current time
  (`formatTime`, tabular), a slim progress track (`colors.elevated`
  track, `colors.label` fill — informational; seeking happens on the
  timeline), total duration. Times come from preview progress events;
  they are display only — JS never drives playback position.
- **Mode switch**: `SegmentedControl` with two options, **Auto Edit**
  and **Manual Edit**, full width, directly under transport. Switching
  modes never changes the cut, the selection, or the playhead — only
  the panel under it. Default mode on entry: Auto if the user has
  never accepted a cut for this project, otherwise the last-used mode.
- **Timeline** (both modes, always visible): the existing
  `TimelineStrip` design, re-skinned (§5, `Timeline`): fixed
  30 px/sec scale, ruler with ticks each second and `formatTime`
  labels every 5s, horizontal scroll, filmstrip thumbnails per cut,
  playhead synced to preview progress, auto-scroll to follow the
  playhead while playing. Header row above it: "Your cut" +
  right-aligned "{n} cuts · {total}" (and while playing, current
  time replaces the left part of that readout — current behaviour,
  keep). RE-SKIN RULE: segment placeholder fills alternate
  `colors.cardPressed` / `colors.elevated` (graphite shades) — the
  rainbow `SEGMENT_COLORS` are deleted (§6). The thumbnails themselves
  carry the visual variety. Label chip per segment ("Take 2") stays:
  `colors.material` chip, `colors.label` text.

#### Auto Edit mode

The magic mode, kept magic: no scores, no percentages, no reasons,
ever (standing product rule — the engine scores internally; the UI
shows none of it).

Panel contents, top → bottom:

1. **Shuffle button** — `PrimaryButton`, full width, shuffle icon.
   Label by state: no cut yet → **"Shuffle my cut"**; a cut exists →
   **"Try another"**. Disabled with an explanatory caption when
   fewer than 2 takes exist ("Shuffle needs at least 2 takes —
   record one more to mix between takes."). While generating +
   preparing the new preview: button shows a spinner + "Cutting…",
   the timeline updates the moment the new EDL lands, the preview
   frame shows the lime sweep (a single `colors.iridescent` gradient
   pass across the frame, ~800ms, §4) and then the new cut auto-plays
   from the top.
2. **Cut pace** — `SegmentedControl`, 4 options: **Chill / Normal /
   Fast / Rapid**, with ONE caption line under it that follows the
   selection, in plain words (existing copy, kept): Chill "Longer
   clips — changes about every 4 seconds." Normal "…every 2
   seconds." Fast "…about every second." Rapid "A new clip almost
   every beat." Changing pace does not re-shuffle by itself; the
   caption's last sentence says so: "Applies to the next shuffle."
   (Pace maps to the engine's frequency lengths — chill ≈4s, normal
   ≈2s, fast ≈1s, rapid ≈0.5s minimum shot.)
3. **Acceptance**: there is no separate draft state — every shuffle
   replaces the project's cut (with undo available, below). Under
   the button, one `type.footnote` line after a shuffle: "Your cut,
   remixed." — and permanently: "Not feeling a cut? Switch to Manual
   Edit, or tap a cut below to swap its take." (Tapping a cut works
   in BOTH modes, §Manual.)
4. **Intensity**: DEFERRED. The directive's "editing intensity" has
   no engine parameter today (pace is the only user-facing dial the
   shuffle bridge exposes). Do not render a control for it. If/when
   the EDL bridge exposes an intensity parameter, it appears here as
   a 3-way segmented control (Smooth / Balanced / Wild) under Cut
   pace, using this same panel pattern.

#### Manual Edit mode

The same timeline, now fully editable. Selecting a cut is the hub:

- **Tap a cut** → it becomes selected: outline becomes 2pt
  `colors.accent` (replacing the old white outline), and a **cut
  action bar** appears between the mode panel and the timeline
  (in Manual mode the panel area IS this contextual bar; in Auto
  mode the same bar appears too when a cut is tapped — take
  switching is never more than one tap away):
  - "Cut {i} of {n}" label + its length.
  - **Take switcher**: horizontal chip row of the project's takes —
    chips labelled "Take 1…n" with 40×40 thumbnails; the current
    take's chip has the `colors.accent` outline + check. Tapping a
    chip swaps that cut's take (keeping its place and length —
    existing `assignClipTake` semantics, now an EDL operation).
    Disabled state: a take shorter than the cut from this position
    is still tappable — the EDL validation clamps; if clamping would
    empty the cut, the chip is disabled with the caption "Too short
    for this cut".
  - **Trim**: "Trim" button toggles trim handles on the selected
    segment: left/right edge handles (28pt wide grab zones,
    `colors.accent` grips) — drag to move the cut's in/out points
    in 1-frame steps (the EDL grid); the segment's filmstrip
    re-samples live, neighbours re-layout gaplessly, and the
    preview's composition is rebuilt on release (not per drag
    frame). Under the handles, a readout in words+time: "Starts
    0:03 into Take 2 · 0:02 long". Fine-adjust: two stepper pairs
    (−/+ at each end) in the action bar for 1-frame nudges when a
    drag is too coarse. Min cut length: 1 frame is legal in the
    EDL, but the UI floor is 3 frames (~0.1s) to prevent accidental
    slivers — flag any disagreement to the lead, don't fork the rule.
  - **Split**: "Split at playhead" button — enabled when the
    playhead is inside the selected cut and at least 3 frames from
    either edge; splits there (playhead position, not midpoint —
    the old midpoint split is superseded, §6).
  - **Delete cut**: destructive text button; removes the segment and
    re-lays the timeline; undo restores it.
  - **Lock** (where practical, per directive): a lock toggle on the
    action bar pins this cut so Auto shuffles keep it (same take,
    same place, same length); locked segments show a small lock
    glyph on their label chip. ENGINE-GATED: render this control
    ONLY if the shuffle bridge accepts pinned segments; if Wave 2
    does not deliver pinning, the control is absent entirely (§1.5).
- **Scrubbing**: dragging on the timeline moves the playhead
  (throttled seeks via `seekPreview` — seek on drag end + at most
  ~5/sec during drag); tapping the ruler seeks there and selects
  nothing; tapping a cut selects it AND seeks to its start.
  Playback position events remain informational only.
- **Undo / Redo**: header-right undo button (and redo beside it once
  an undo exists), disabled at 40% opacity when their stack is
  empty. Every EDL mutation — shuffle, swap, trim, split, delete —
  is one undo step (the store's existing snapshot undo is the model;
  redo is new and required by this spec). Undo restores the EDL and
  rebuilds the preview; it never touches takes or the song.
- **Empty/degenerate states**: 0 takes → §2.3 empty state. 1 take →
  timeline shows that take as one full-length cut (a valid EDL);
  Auto panel explains "Record one more take to shuffle between
  takes." and Manual works normally. No cut yet (≥2 takes, never
  shuffled) → timeline area shows `EmptyState` ("No cut yet", "Tap
  Shuffle my cut and MVMT arranges your takes.") and the action
  band's Export button is absent (not disabled — absent; §2.3).

**Action band (Editor)**: `PrimaryButton` **"Export"** (share icon),
present only when a cut exists. Under it, caption: "Your cut, ready
to export" is narration — DROP it; no caption in the Editor action
band.

### 3.6 Export (workspace stage 4)

The finishing screen. Reachable only with a non-empty cut (§2.3).

- Header: back label "Editor", title "Export", subtitle "{n} cuts ·
  {total length}".
- **Final preview**: the same native preview component as the Editor
  (same composition), 9:16 frame, transport row (play/pause + times).
  What plays here is byte-for-byte the edit that renders.
- **Options card** (one `colors.card` group, rows with hairline
  separators):
  - **Quality** row: segmented **High / Balanced / Small file**
    (the existing export-quality preference becomes this project's
    initial value; changing it here changes it for this export and
    updates the default). One caption under the card translates the
    choice into consequences, in words: e.g. Balanced → "1080 × 1920
    · a good size for sharing." High → "1080 × 1920 · best quality,
    bigger file." Small file → "Smaller file, softer picture."
    (Exact bitrates are engine facts; the copy names resolution +
    consequence only.)
  - **Format** row (static): "Portrait · 1080 × 1920 · 30 fps" —
    display only, the project's canvas/fps. Not a control (§3.2).
  - **Sound** row (static): "Song only — your takes' camera sound is
    off." Display only; it states the audio policy (§2.5 of the
    directive) so the user is never surprised. A take-audio control
    is DEFERRED (§6).
- **Render action**: `PrimaryButton` **"Save video"**. On tap:
  - Progress state replaces the button: determinate progress bar
    (`colors.accent` fill on `colors.elevated` track, height 6,
    `radius.pill`) driven by REAL export progress events
    (`addExportProgressListener`), a percentage in `type.caption`,
    and a **Cancel** text button (`cancelExport`). Progress copy:
    "Rendering your video…" — nothing more specific than the engine
    reports.
  - Failure state: inline card — `colors.danger` icon, the engine's
    human-readable error, **Try again** button. No alert modals.
  - **Completion state** (replaces the whole options/progress area):
    success icon in `colors.success`, "Your video is ready",
    and MEASURED facts from the render result — actual duration
    (`formatTime(result.durationSeconds)`) and canvas size. Never
    display the requested duration as the result (audit finding).
    Actions: `PrimaryButton` **"Save to Photos"** → on success
    becomes a confirmed state ("Saved to Photos ✓" with
    `colors.success`, button disabled); **Share** secondary button
    (system share sheet); text button **"Done"** → back to Studio
    (project marked Exported for the Continue card).
- If the cut changes after a render (user goes back, edits, returns),
  the completion state is stale: reset to the pre-render state
  whenever the EDL differs from the rendered one. (Compare EDL
  identity/version, not timestamps.)
- NOT on this screen (§6): per-take save/share rows, engine
  availability essays, "Expo Go can't…" copy — if the engine is
  genuinely unavailable (`isCompositorAvailable() === false`), the
  screen is a single honest `EmptyState`: "Export isn't available in
  this build." + back button. Nothing else.

### 3.7 Settings / Profile (tab 3)

Configuration only — the standing rule survives the overhaul intact:
**nothing creative lives here** (no trims, no text, no transitions, no
per-cut anything). One screen, grouped lists, no sheet duplication:
the gear buttons that used to open a settings sheet from every screen
are removed; the Record screen's gear navigates here instead (§3.3).

- Header: `type.largeTitle` "Settings". (There is no account/profile
  system; do not invent one. If a profile section ever exists it is a
  lead decision — today the tab is Settings, full stop.)
- **Group: Camera defaults** (applied to the Record screen):
  - Camera timer — segmented Off / 3s / 5s / 10s.
  - Count-in — segmented Off / 4 / 8 beats, caption "Clicks before
    the take starts, after the timer."
  - Recording quality — segmented 720p / 1080p / 4K.
  - Frame rate — segmented 30 / 60, caption "MVMT uses the closest
    rate your iPhone supports. Edits and exports are 30 fps."
  - Mirror front camera — switch (default on).
  - Grid — switch. Level guide — switch.
  - Beat flash while recording — switch.
- **Group: Sound**:
  - Bluetooth sync shift — stepper (− / + in 10 ms steps) with the
    value in words underneath: "Moves the song earlier/later if
    Bluetooth speakers make your takes land off the beat. Most
    people never need this." (This is the existing audio offset,
    renamed to human language; the word "offset" does not appear.)
- **Group: Exports**:
  - Default quality — segmented High / Balanced / Small file (same
    control as Export's, same stored default).
  - Autosave projects — switch (default on), caption "Projects save
    as you work, on this phone."
- **Group: About**: app name + version row (static), "Made for
  recording music videos" caption. Device row from the old sheet is
  dropped (it answered a question nobody asks, §6).
- Control styles: rows on `colors.card`, `radius.lg` group cards,
  segmented controls and iOS switches (`Switch` with
  `trackColor.true = colors.accent`) — the old 2-column tile grid in
  the settings sheet is replaced by these standard rows (§6): tiles
  mixed labels, values and controls inconsistently.
- The existing `SettingsSheet.tsx` tile internals are retired; the
  Settings TAB reuses the same store values and the same
  `SegmentedControl`/`SwitchRow` primitives. `SettingsSheetConnected`
  and per-screen sheet wiring are removed (§6).

---
