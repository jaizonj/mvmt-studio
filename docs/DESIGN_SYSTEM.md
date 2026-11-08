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

## 4. Interaction & motion principles

Motion budget (hard rules):

- Durations: micro-feedback 100–150ms; panel/segment changes
  200–250ms; screen transitions = the native stack/tab defaults
  (do not customise durations). Nothing animated exceeds 350ms
  except the shuffle sweep (~800ms, below).
- All animations run on the native driver / Reanimated worklets
  (Reanimated is already in the project). No JS-thread layout
  animation during media playback. If an animation and playback
  contend, the animation loses: cancel it.
- Animations are state explanations only: things slide because they
  came from somewhere, fade because they appeared. No idle motion,
  no looping decoration, no parallax.
- `prefers-reduced-motion` (AccessibilityInfo): disable the shuffle
  sweep and pill expand/collapse animations; keep instant state
  changes and the recording-dot pulse (reduced to a static dot).

Per-interaction specs:

- **Buttons**: pressed state = `colors.cardPressed` (cards/rows) or
  0.92 scale + slight dim (primary/pills over camera). Feedback is
  immediate (<100ms). No ripples (Android pattern), no shadows added
  on press.
- **Segmented controls**: selection slides (150ms) or crossfades;
  caption text swaps instantly with the selection.
- **Pills over camera** (zoom/timers): expand/collapse = 200ms
  height/opacity on the native driver; the camera picture never
  moves. Opening one pill collapses the other instantly.
- **Sheets**: iOS page-sheet slide + dim (existing `Sheet`
  behaviour). Blur backdrop is capped at the sheet's own surface
  (`BlurView` dark) — not a global glass theme.
- **Recording feedback**: on record start — haptic (medium impact)
  + go-tone + elapsed pill appears (150ms fade). The recording dot
  pulses opacity 1↔0.35 at 1s period while recording. On stop —
  haptic (light) + notice "Take {n} saved".
- **Count-in/timer**: numerals swap instantly per beat/second (no
  scale animations — the beeps/clicks carry the rhythm; a bouncing
  numeral fights it).
- **Shuffle sweep**: when a new cut lands, a `colors.iridescent`
  gradient layer sweeps diagonally across the preview frame once
  (~800ms, ease-out) at ≤45% opacity, then the preview auto-plays.
  This replaces the old violet/pink shimmer + "✦" glyph (§6). It is
  the only decorative animation in the product, and it marks a real
  event (a new edit exists). If preview preparation outlasts the
  sweep, the `loading` state (§3.5) takes over — never loop the sweep.
- **Timeline gestures**: horizontal scroll = native momentum;
  playhead auto-follows during playback (scroll only when the
  playhead would leave the viewport, current behaviour); trim drags
  = direct manipulation (the segment edge tracks the finger 1:1);
  no gesture may trigger a composition rebuild mid-drag — rebuilds
  happen on release (§3.5).
- **Loading / preparation states** (one pattern everywhere): black or
  `colors.card` surface + centred spinner in `colors.label` + ONE
  `type.footnote` caption naming the real activity ("Preparing your
  cut…", "Rendering your video…", "Loading your song…"). Skeleton
  screens are not used — media apps show the media or a spinner.
- **Haptics** (`expo-haptics` — NOT currently a dependency; adding it
  is a lead-approved install, flagged in Appendix A): record
  start/stop (above), successful export render (success
  notification), delete confirmation is the alert itself (no
  haptic). No haptics on ordinary navigation or list taps.
- **Errors**: inline, in place, with the recovery action beside the
  message (§3.6 pattern). `Alert` is reserved for destructive
  confirmations and permission dead-ends only.

## 5. Component inventory

Build/reuse exactly these shared components. Each lists its token
surface — a component that needs a colour not listed here is a spec
violation; flag it instead of adding a literal.

| Component | Status | Used on | Spec |
| --- | --- | --- | --- |
| `PrimaryButton` | NEW (extract from the three near-identical white buttons in takes/shuffle/export) | All action bands, Studio, creation | Full-width (in its band), `colors.accent` bg, `colors.onAccent` text `type.headline` 600, `radius.md`, vertical padding 14, optional leading icon 18pt `colors.onAccent`. Disabled: `colors.elevated` bg, `colors.labelTertiary` text. Loading: spinner `colors.onAccent` + label swap. |
| `SecondaryButton` | NEW | Export (Share), preview error retry | `colors.card` bg, `colors.label` text, `radius.md`, same metrics as Primary. |
| `IconButton` | EXISTS — keep | Camera top bar, transport, headers | 44×44 target, `colors.material` circular fill over media / transparent on plain screens, icon 22–24 `colors.label`, `active` state icon `colors.accent`, disabled 40% opacity. |
| `Header` (workspace) | NEW (formalise the repeated pattern) | All workspace stages | Back chevron + label (`colors.accent`, 17pt), `type.largeTitle` title, optional `type.subhead` subtitle `colors.labelSecondary`, optional trailing actions (Editor undo/redo). Padding `spacing.xl` sides, `insets.top + spacing.md` top. |
| `ActionBand` | NEW (formalise nextBar/exportBar) | Takes, Editor, Export, creation steps | Hairline top `colors.separator`, `colors.groupedBackground`, padding `spacing.xl` / top `spacing.md` / bottom `max(insets.bottom, spacing.md)`. Holds one `PrimaryButton` + ≤1 caption. |
| `SegmentedControl` | EXISTS — keep, re-skin check | Pace, timer, count-in, quality, fps, modes | Track `colors.elevated`, thumb `colors.cardPressed` with hairline `colors.separator`, selected text `colors.label`, unselected `colors.labelSecondary`. Editor mode switch uses the same component. |
| `Sheet` | EXISTS — keep | Track sheet, take preview | iOS page sheet, `radius.sheet`, `colors.elevated`/blur-dark surface, grab handle, title `type.headline`, Done in `colors.accent`. |
| `SettingsSheet` / `SettingsSheetConnected` | REMOVE (§6) | — | Replaced by the Settings tab (§3.7) built from `SettingsRow` primitives. |
| `SettingsRow` + `SwitchRow` | NEW (from SettingsSheet internals) | Settings tab | Row: label `type.body` `colors.label`, control trailing (segmented full-width variant for multi-choice = label above control). Group card `colors.card` `radius.lg`, hairlines `colors.separator`, group titles = `type.caption` uppercase `colors.labelSecondary` letter-spaced. |
| `ProjectCard` | NEW | Studio (Continue/Recent), Projects | Variants: hero (Continue, horizontal, 64px thumb) and list (72px thumb). `colors.card` bg, `radius.lg`, pressed `colors.cardPressed`. Title `type.headline` 1 line, subtitle `type.footnote` `colors.labelSecondary` 1–2 lines, chevron or overflow trailing. |
| `TakeRow` | NEW (replaces takes.tsx inline rows) | Takes | §3.4 anatomy: 54×72 thumb `radius.sm`, duration badge (`colors.material`, `type.caption`), title/subtitle/sync line, in-cut badge (`colors.accentDim`/`colors.accent`), overflow button. |
| `RecordButton` | EXISTS — keep, verify tokens | Record | 76pt, `colors.iridescent` ring (only sanctioned gradient #1), white inner ring, `colors.danger` centre (circle idle / rounded square recording), press scale 0.94, disabled 40%. |
| `CameraPill` (zoom / timers) | EXISTS as inline JSX — extract | Record right column | `colors.material` fill, `colors.materialBorder` hairline, `radius.pill`; collapsed = icon + summary; expanded panel = `radius.lg` material card with chip rows; chip selected = light fill/dark text (match across both pills). |
| `LengthChips` | EXISTS inline — extract | Record bottom-centre, creation (inside region picker) | Container `colors.material` `radius.pill` padding 4; chip min-width 38, height 30, selected = light fill + dark text (same selected language as camera pills — NOT the accent, these sit on camera where the accent is reserved for record-adjacent signals). |
| `TrackSheet` + `AudioRegionPicker` | EXIST — keep, honesty fix §3.2 | Record (via track pill), creation Step 2 | Unchanged mechanics; neutral bar rendering until real peaks exist. |
| `Timeline` (`TimelineStrip`) | EXISTS — re-skin + extend | Editor (both modes) | Keep: 30px/s, ruler (tick 1s, label 5s), filmstrip via `src/lib/thumbnails.ts`, playhead + auto-scroll, tap-to-select. Change: segment fills → `colors.cardPressed`/`colors.elevated` alternation (delete `SEGMENT_COLORS`); selected outline → 2pt `colors.accent`; playing underline already `colors.accent` (now lime — verify no hardcoded violet remains); label chip `colors.material`. Extend: trim handles + lock glyph + split affordances per §3.5. The component consumes EDL-derived view data (frames→seconds at the boundary), never `TimelineClip` creative fields. |
| `NativePreview` | NEW (replaces `TimelinePreview`) | Editor, Export, Take preview (single-take variant) | Wraps the native v2 preview API: creates from a `CompositeRequest`, renders the native view 9:16 `radius.lg` on black, exposes play/pause/seek + status/progress events. Owns NO playback logic — position is display-only. States: loading/error/ready per §3.5. `TimelinePreview` (JS polling, dual players) is deleted, not wrapped (§6). |
| `TransportRow` | NEW | Editor, Export | Play/pause `IconButton`, current time, slim progress track (`colors.elevated` track, `colors.label` fill), total time; tabular numerals. |
| `ProgressBar` | NEW | Export render | Track `colors.elevated`, fill `colors.accent`, height 6, `radius.pill`, driven by real progress events only. |
| `EmptyState` | EXISTS as repeated inline JSX — extract | Studio, Projects, Takes, Editor, Export-unavailable | Centred: icon 30pt `colors.labelSecondary`, title `type.headline` `colors.label`, body `type.subhead` `colors.labelSecondary` (centred, ≤3 lines), optional one `PrimaryButton`. On plain screens it sits in a `colors.card` `radius.lg` card (current pattern); in the Editor timeline area it renders without the card. |
| `NoticePill` (toast) | EXISTS inline on camera — extract | Record (and only Record) | `colors.material` pill, `type` footnote text `colors.label`, auto-dismiss ~2.2s, `pointerEvents="none"`. Other screens use inline states, not toasts. |

State ownership rule for implementers: components receive the EDL (or
view data derived from it) and playback *display* state as props;
they never own media state. The store owns projects/takes/EDL; the
native engine owns playback/render state; components own only local
UI state (open/closed, selection, drag positions).

## 6. Feature cull list

REMOVE or DEFER, with reasons. "Remove" = delete UI and, where the
lead agrees, the code path; "Defer" = no UI now, data/engine hooks may
remain untouched.

| # | Item | Verdict | Reason (one line) |
| --- | --- | --- | --- |
| 1 | Per-clip **speed** (`TimelineClip.speed`) | DEFER | No preview/export support; a control that lies about the output violates §1.5. |
| 2 | **Fades** (`fadeInSeconds/fadeOutSeconds`) | DEFER | Same — not rendered anywhere today. |
| 3 | **Looks / colour filters** (`look`) | DEFER | Not implemented in the engine; would need the custom-compositing path the audit says is unnecessary for v1. |
| 4 | **Text overlays** (`textOverlay/textPosition`) | DEFER | Not rendered; text belongs to a later creative wave with real preview support. |
| 5 | **Transitions** (`transitionType/transitionDurationSeconds`, crossfade/dip) | DEFER | Hard cuts only in the composition engine; showing transition UI promises what export can't do. |
| 6 | Per-clip **volume/mute UI** (take audio controls) | DEFER | Audio policy is song-only by default; the engine flag (`includeTakeAudio`) stays, the UI waits for a deliberate mixed-audio feature. |
| 7 | `TimelinePreview` JS preview (200ms polling, dual players, per-clip replaceAsync) | REMOVE | The audit's #1 problem; replaced by `NativePreview` on the shared composition — two preview paths must not coexist. |
| 8 | Rainbow timeline segment colours (`SEGMENT_COLORS`, violet/blue/pink/mint) | REMOVE | Competing accents retired with the iridescent scheme; thumbnails carry variety, graphite carries structure. |
| 9 | Shuffle shimmer (violet/blue/pink `LinearGradient` + "✦") and "Your cut, remixed ✦" | REMOVE → replaced | Old palette + decorative glyph; replaced by the single lime sweep (§4) and plain "Your cut, remixed." |
| 10 | Hardcoded `#FFFFFF` primary buttons / `#14141F` text (takes, shuffle, export, sheets) | REMOVE | Retired palette literals; `PrimaryButton` on `colors.accent`/`colors.onAccent` replaces all of them. |
| 11 | `SettingsSheet` + `SettingsSheetConnected` + gear buttons on Takes/Editor/Export headers | REMOVE | Settings duplicated in every screen; one home (Settings tab) per §1.3. Record's gear becomes navigation, not a sheet. |
| 12 | Settings sheet 2-column **tile grid** | REMOVE | Tiles mixed labels/values/controls inconsistently; standard grouped rows replace them. |
| 13 | Per-take **Save/Share icon rows** on Takes | REMOVE → moved | Three competing icon buttons per row; both actions move into the take overflow menu / preview sheet (§3.4). |
| 14 | Per-take **Save/Share list** on Export (`takes.slice(0,3)` rows) | REMOVE | Export is about the finished video; raw-take distribution belongs to Takes. |
| 15 | Export screen's engine-availability essay + Expo Go fallback copy | REMOVE | One honest unavailable state (§3.6); the shipped build has the engine. |
| 16 | Midpoint **split** (`splitTimelineClip` at trim midpoint) | REMOVE → replaced | Superseded by split-at-playhead (§3.5), which is where the user is actually looking. |
| 17 | `swapTimelineClips` / `moveTimelineClip` as user features | DEFER (no UI) | Reordering cuts fights the sync model (cuts are positions in the song); no UI exposes them — take switching is the supported rearrangement. |
| 18 | `addToTimeline` hand-built cut from Takes | REMOVE (UI) | Manual building lives in the Editor now; a second construction path in Takes duplicates the Editor. |
| 19 | **Cover-frame picker** (`coverClipId` UI) | DEFER | Project thumbnails auto-derive (§3.1.1); a picker is polish without a user problem yet. (Store field may stay.) |
| 20 | Fake waveform bars presented as the song's waveform | REMOVE (the claim) | Bars are a name-seeded pattern today; render neutrally (§3.2) until real peaks are decoded — honesty rule §1.5. |
| 21 | Shuffle **score / "Best of N"** anything | REMOVE (already hidden — keep it gone) | Standing rule: shuffle is magic, not a report card. `ShuffleResultInfo` stays internal. |
| 22 | "Device" info row in old Settings ("iPhone · 1179×2556") | REMOVE | Answers no user question; About keeps name + version only. |
| 23 | `editor.tsx` legacy redirect as a *destination* | KEEP (redirect only) | It must land on the Editor (§3.5); it is not a screen and gets no design. |
| 24 | Autosave **preference without persistence** | RESOLVE, don't ship dark | The current switch controls nothing (persistence is a noted TODO). The projects model (Wave 2) makes it real; if persistence slips, the switch is removed from Settings until it works (§1.5). |
| 25 | Recording **frame-rate 60** presented as an editing rate | KEEP with corrected copy | It's a capture preference only; Settings copy now says edits/exports are 30 fps (§3.7) so the UI stops implying 60 fps exports. |
| 26 | Energy/motion stats, file sizes, take "quality" data in UI | REMOVE (never ship) | `Take.energy` is an engine input, not user information; no screen displays it. |

## 7. Accessibility & layout rules

Layout:

- **Safe areas everywhere**: screens inset content by
  `insets.top + spacing.md` (headers) and action bands pad
  `max(insets.bottom, spacing.md)` — the existing pattern, now
  mandatory. Camera overlays additionally respect the top safe area
  for the top bar and the bottom safe area for the bottom bar.
- **Small iPhones** (≤667pt tall, e.g. SE): the Editor is the tight
  screen — shrink order is fixed: (1) preview height, (2) mode-panel
  vertical padding, (3) timeline strip height 58→48. The action band
  and transport NEVER shrink or scroll away. Takes/Studio/Projects/
  Settings scroll normally.
- **Large iPhones** (≥852pt): preview caps at the width-driven 9:16
  height or 460pt, whichever is smaller (existing cap pattern);
  leftover space goes to section spacing, not bigger controls.
- **Landscape**: unsupported for workspace stages (portrait lock, as
  today); tabs render but the product is portrait — takes recorded
  landscape are normalised by the engine's canvas, displayed
  cover-fit, never stretched.
- **One-handed reach**: primary actions live in bottom action bands;
  destructive actions live in overflow menus, never at the top.

Touch & interaction:

- **Minimum touch target 44×44pt** for every interactive element
  (icon buttons may draw 22pt glyphs inside a 44pt hit area —
  existing `hitSlop` patterns count toward the 44). Timeline trim
  grab zones are 28pt wide × full segment height and are the single
  documented exception (they sit between two larger tap targets and
  have stepper alternatives, §3.5).
- Segmented controls, chips and switches are all ≥32pt tall with
  ≥44pt effective targets via padding/hitSlop.
- No gesture-only critical actions: every drag (trim, region window,
  scrub) has a button/stepper alternative.

Vision & hearing:

- **Contrast on graphite**: `colors.label` on `colors.base`/`card`
  is the default text pairing (high contrast, ~13:1). 
  `colors.labelSecondary` (≈68% warm white) is the floor for any
  text a user must read. `colors.labelTertiary` (≈42%) is restricted
  to captions, timestamps and disabled states — never body copy,
  never interactive labels. `colors.accent` on graphite is for
  large/bold text, icons and fills only; small accent text must be
  `type.caption` semibold or larger. Text on accent is always
  `colors.onAccent`. `colors.danger`/`colors.success` are always
  paired with an icon or words (never colour-only meaning).
- **Dynamic Type**: all text uses the `type` scale with system font;
  rows must grow rather than truncate at large sizes — titles may
  wrap to 2 lines; buttons never truncate (shorten the copy
  instead). Test at the largest accessibility size: action bands
  and the Editor layout must still fit (preview shrink order, §7).
- **VoiceOver**: every icon-only control has an
  `accessibilityLabel` (existing codebase habit — keep it, extend it
  to the new components); selection states use
  `accessibilityState.selected`; the timeline exposes each cut as a
  button labelled "Take 2, cut 3 of 12, 0:02 long. Tap to switch its
  take." (existing label pattern); progress bars expose value text
  ("Rendering, 45 percent"); the recording state is announced via
  the elapsed pill's label ("Recording, 0:07 of 0:15").
- **Audio cues**: timer beeps, count-in clicks and the go tone are
  product features, not decoration (§3.3) — they are never the ONLY
  signal: numerals and the recording pill mirror them visually.
- **Reduced motion**: see §4.

---

## Appendix A — Conflicts found, and how this spec resolved them

1. **"Opens straight into the camera" (standing preference) vs the
   directive's tab IA (Studio home first).** The directive and
   `IMPLEMENTATION.md` win for the overhaul: the app opens on Studio.
   Mitigation inside the spec: Continue is one tap from launch, and
   New Project is three taps from the camera. Flagged for the lead —
   if Jaizon vetoes, Studio can become a lightweight launcher while
   keeping the tabs.
2. **"No status narration" (Jaizon removed the stage indicator)
   vs the directive's recording-screen requirements ("clear recording
   state", "song playback indicator").** Resolved by kind: stage
   *narration* stays banned (no step indicator, no "you are
   shuffling" text — §1.7, §2.3). Recording *state* (elapsed pill,
   pulsing dot, song pill) is functional information a performer
   needs mid-take and is specified (§3.3).
3. **Iridescent identity (previous MEMORY) vs graphite/lime tokens.**
   The overhaul supersedes it; `theme.ts` already renamed the ramp
   to lime values under the `iridescent` token name. This spec uses
   the token name as-is and culls the remaining violet/pink/blue
   literals in components (§6 #8–#10). No new palette invented.
4. **Directive asks for an "intensity" control; the engine exposes
   only frequency.** Spec defers intensity rather than shipping a
   dead control (§3.5), with the exact panel pattern to add it later.
5. **Directive's project-creation format step vs the engine's single
   canvas (1080×1920).** Format is shown as information, not a
   choice (§3.2). Same resolution applied to Export's fps row (§3.6).
6. **Directive: "Lock preferred moments"; engine pinning unconfirmed.**
   Spec'd fully but engine-gated: absent UI beats broken UI (§3.5).
7. **Projects don't exist in code yet** (single in-memory project;
   autosave is a preference without persistence). Studio/Projects
   specs (§3.1) therefore define the data the UI needs (title, song
   name, take count, cover thumbnail source, last-stage, updated
   time, exported flag) for the lead's Wave-2 projects store — the
   design is ahead of the store by one wave, deliberately, and §6 #24
   forbids shipping the autosave switch dark.
8. **Haptics are specified but `expo-haptics` is not installed.**
   Spec keeps haptics minimal (3 moments, §4) so the dependency is
   trivial to add; the lead owns the install decision.
9. **Settings as a sheet (current product) vs Settings as a tab
   (directive IA).** Tab wins; the sheet components are culled
   (§6 #11) and Record's gear becomes a navigation shortcut so the
   muscle memory from the camera still works.
10. **Takes screen "selection state" (directive)**: the current Takes
    screen has no selection concept. Spec interprets it as the
    *in-cut badge* (§3.4) — the only selection that means something
    for a take — rather than inventing multi-select checkboxes with
    no bulk action to serve.

## Appendix B — Data the UI requires (for store/engine implementers)

- **Project**: id, title (default = song name), song {name, uri,
  duration}, region (existing `AudioRegion`), takes[], EDL
  (existing `src/lib/edl.ts`), lastStage ('record'|'takes'|'editor'|
  'export'), updatedAt, exported flag, cover source (cover clip →
  take + frame). Persistence: autosave on change (Wave 2).
- **Take**: existing fields + display name (rename, nullable) +
  measured sync status enum (`synced | adjusted | unmeasured`) +
  measured duration (already the plan in `IMPLEMENTATION.md`).
  Chronological numbering is derived from `createdAt` order and is
  stable across deletions.
- **Editor**: EDL + undo AND redo stacks (redo is new), selected
  segment id, mode (auto/manual, per project), pace (existing
  `shuffleFrequency`), pinned segment ids (iff engine supports
  locking).
- **Export**: per-render state machine (idle → rendering(progress) →
  done(measured result) | failed(error)), keyed to the EDL identity
  so edits invalidate stale results (§3.6).
