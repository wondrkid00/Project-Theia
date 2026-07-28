# Theia Viewer UI Redesign — Plan

**Reference:** QuadSpinner GAEA 2 (docs.quadspinner.com / docs.gaea.app)
**Status:** plan, pending approval
**Date:** 2026-07-28

---

## 1. What the reference actually does

Grounded in GAEA's own interface documentation, not from memory:

| GAEA behaviour | Source |
|---|---|
| "The Gaea interface is split into 3 main parts: the viewport, the graph, and the properties panel." | Getting around |
| Properties **full-height right edge**; viewport **top-left**; graph **across the bottom**, full width beneath the viewport | product screenshot |
| A category icon palette (Toolbox) is pinned down the **left edge of the graph**; tool rails run down the right edge of both viewport and graph | product screenshot |
| Bottom status bar carries build state (`Idle`) and memory use | product screenshot |
| "the main toolbar is shared with the title bar to give you maximum workspace area" | Main Menu |
| Graph "can be split into multiple tabs, which are shown above the nodes" | Getting around |
| Viewport has its **own** toolbar carrying viewport + lighting options | Viewport |
| Properties: numeric fields with right-click entry, sliders showing **default vs modified** state, toggles, dropdowns | Properties |
| Right-click a numeric property → *microincrements* panel: Halve, Double, Minimum, Maximum, Reset | Properties |
| Properties menu: Reset, Save/Load State, Copy/Paste Settings, Presets | Properties |
| Drag a wire into empty space → search menu, type to find a node, click to create **and connect** | Toolbox |
| Build tab houses the Build Manager + Terrain Definition | Build Manager |

Two of these Theia already has in some form (wire-drag-to-create, per-parameter
reset). The rest is the gap.

### Where Theia legitimately differs

GAEA has features Theia doesn't (Build Manager queue, post-process stack, multiple
graph tabs, 2D editor viewport, presets library). Theia has features GAEA doesn't
(mask erase brush painted directly on the 3D terrain, live hot-reload of the graph
file, an inline diagnostics log). The redesign copies GAEA's **structure and
density**, not its feature list.

---

## 2. Feature inventory — the no-loss contract

Every item below exists today and **must still be reachable after the redesign**.
This list is the acceptance checklist, verified item-by-item at the end.

### Top toolbar (`ContentView.swift`)
- [ ] File › Load graph (NSOpenPanel, .json)
- [ ] File › Save graph (saves in place, else NSSavePanel)
- [ ] Camera › Reset (`F`)
- [ ] Camera › Orbit tool (`O`) — active state
- [ ] Camera › Pan tool (`H`) — active state
- [ ] Camera › Zoom tool (`Z`) — active state
- [ ] Mask › Erase brush (`E`) — **conditional group**, only when `canEditActiveMask`
- [ ] Display › Grid toggle
- [ ] Display › Axes toggle
- [ ] Display › Wireframe toggle
- [ ] Hover hint overlay (bottom-right capsule showing each control's help text)

### Viewport overlays (`ViewportSurface`)
- [ ] Projection menu: Perspective / Orthographic + Reset Camera + Top
- [ ] Display-mode menu: auto, terrain, height, mask, slope, normal, material, data
- [ ] Material-preset menu with colour swatch: natural, alpine, arid, analysis
- [ ] Viewport-settings popover (`ViewportSettingsPopover`):
      mask opacity · erase toggle · clear erase · brush radius · light azimuth ·
      light elevation · wireframe · reset camera
- [ ] Axis gizmo: 6 clickable axis dots (±X ±Y ±Z → camera presets) + hub = reset,
      with depth-based dimming
- [ ] Status badge: dirty/saved, expands to show last-saved relative timestamp

### Node graph (`NodeEditorCanvas`, `CanvasToolbar`, `NodeEditorComponents`)
- [ ] Add node — popover palette, grouped (Terrain / Noise / Shape / Combine /
      Filter / Mask / Erosion / …), with recents and search
- [ ] Delete selection (nodes and edges) — disabled when nothing selected
- [ ] Duplicate selection — disabled when nothing selected
- [ ] Auto-layout
- [ ] Undo / Redo (also `⌘Z` / `⇧⌘Z`)
- [ ] Canvas zoom slider
- [ ] Marquee (rubber-band) multi-select
- [ ] Node drag, node context menu (delete, duplicate, select upstream/downstream)
- [ ] Input ports: type-coloured, missing-input warning, drag-compat highlighting,
      right-click → Disconnect
- [ ] Output ports: type-coloured, **tap to preview that port**, drag to connect
- [ ] Wire drag into empty space → compatible-node search window
- [ ] Empty-graph quick-add starters (Rolling Hills, Mountain Range, Fluvial
      Erosion, River Carve, Slope Mask, …) with one-line descriptions
- [ ] Node badges: mask-output marker, export marker, error/warning marker
- [ ] Canvas status readout: node count / dangling-wire type hint / error+warning
      counts
- [ ] `Delete`/`Backspace` deletes selection; `A` opens add-node

### Output tab (`GraphOutputPanel`)
- [ ] Diagnostics list with All / Errors / Warnings / Info filters
- [ ] Free-text message filter
- [ ] "Graph is healthy" / "No messages" empty states
- [ ] Error+warning count badge on the tab

### Inspector (`NodeParameterInspector`, `ExportControls`)
- [ ] Node header + NODE SETTINGS section
- [ ] Bounded slider per parameter (every range finite, and each range contains
      its own default — regression-tested)
- [ ] Typed numeric entry (`InspectorValueField`, clamp → snap → re-clamp)
- [ ] ADVANCED disclosure group
- [ ] Per-parameter reset
- [ ] "Reset node parameters and mask edits"
- [ ] PREVIEW OUTPUT port picker
- [ ] "Set as Graph Output" (persists the previewed port as CLI/export output)
- [ ] Enum/dropdown and toggle parameters
- [ ] Export controls when an `export` node is selected: destination folder,
      heightmap format, mesh toggle, mesh stride, vertical scale, Export button,
      progress, Reset Export Settings
- [ ] "No node selected" / "No parameters" empty states

### Non-visual behaviour to preserve
- [ ] Hot-reload controller (external edits to the graph file)
- [ ] Autosave controller
- [ ] `⌘S` save shortcut, suppressed while a text field has focus
- [ ] `--smoke` launch mode (CI smoke test asserts a clean window launch)
- [ ] `ViewerSelfTests` continue to pass

---

## 3. Target layout

**Correction (during execution).** This section originally specified a three-column
split (viewport | graph | properties), read off the documentation's phrase "split
into 3 main parts". A screenshot of the running product showed that is wrong:
Gaea puts **properties full-height on the right**, the **viewport top-left**, and
the **graph across the bottom** beneath it. That is structurally what Theia
already had, so the panel geometry stays stacked and the redesign is carried by
density, chrome and the node/parameter styling instead.

Node cards: **category colour, no thumbnails** (as approved).

```
┌──────────────────────────────────────────────────────────────┐
│ ▸ File  Camera  Display  Mask           Theia — fluvial.json │  unified titlebar
├───────────────────────────────────────────┬──────────────────┤
│                                           │  ColorErosion    │
│                                           │ ──────────────── │
│              3D VIEWPORT           ⬡gizmo │  Transport  2.00 │
│                                           │  Sediment   1.00 │
│  ◐ Persp ⬒ Natural ⚙                      │  Blend      1.00 │
├───────────────────────────────────────────┤  Color Hold 0.50 │
│ ▸ fluvial                                 │  Seed      18136 │
│ + 🗑 ⧉ ▦ ⟲ ⟳ ──▊── 38%                    │  ▸ ADVANCED      │
│   ┌──────┐   ┌──────┐   ┌──────┐          │ ──────────────── │
│   │ Base │──▶│ Carve│──▶│ Scree│          │  PREVIEW OUTPUT  │
│   └──────┘   └──────┘   └──────┘          │  ○ height        │
│ ▸ OUTPUT  Graph is healthy                │  ● flow          │
└───────────────────────────────────────────┴──────────────────┘
        viewport ~60% / graph ~40%              300–460pt
```

Concretely:

1. **Unified title/toolbar.** Set `window.titlebarAppearsTransparent` +
   `.unifiedCompact` toolbar style and move the File/Camera/Display/Mask clusters
   into it. Reclaims the 68pt strip currently sitting on top of the viewport —
   this is GAEA's stated reason for doing it.
2. **Viewport column** keeps its floating overlay menus (projection, display mode,
   material, settings), the gizmo and the status badge. It gets taller and the
   overlays stop competing with a toolbar directly above them.
3. **Graph column** becomes full-height with a header row (graph title + tab strip
   placeholder for future multi-graph support, matching GAEA's "tabs above the
   nodes"), the node canvas, and a bottom action bar. The Output panel becomes a
   **collapsible tray** at the bottom of this column — collapsed to a one-line
   summary chip by default, expanded on click or automatically when an error
   appears. Nothing from the Output tab is removed; it stops costing a tab switch.
4. **Inspector column** unchanged in content, restyled for density: tighter row
   height, label-left / value-right alignment, a modified-vs-default dot on each
   slider (GAEA does exactly this), and section rules instead of the current
   generous spacing.

### Node card

```
┌─────────────────────┐   ┌─────────────────────┐
│▉ TERRAIN            │   │▉ EROSION         ⚠  │
│  Mountain      #3   │   │  Fluvial       #7   │
├─────────────────────┤   ├─────────────────────┤
│ ●in           out ● │   │ ●terrain     out ●  │
│                     │   │ ●mask       flow ●  │
└─────────────────────┘   └─────────────────────┘
```

Category stripe colours derive from the existing `NodeTypeCatalog` groups, so the
palette in the Add popover and the stripe on the card agree. Port dot colours
already come from `GraphPortPalette` and stay as-is.

---

## 4. Phases

Each phase builds and runs `swift run theia-viewer --smoke` plus the self-tests
before the next one starts. No phase leaves the app unlaunchable.

| # | Phase | Files | Risk |
|---|---|---|---|
| 1 | Extract `ViewportSurface`'s toolbar into a reusable `TheiaToolbar`, move to the unified titlebar, delete the 68pt strip | `ContentView.swift`, `main.swift` | med — NSToolbar/SwiftUI bridging |
| 2 | ~~Three columns~~ → keep the stacked geometry (viewport over graph, inspector right); graph pane gains a tab strip + action bar | `ContentView.swift`, `GraphColumn.swift` | low |
| 3 | Output panel → collapsible tray inside the graph column; retire `AuthoringDockTab` | `ContentView.swift`, `GraphOutputPanel.swift` | low |
| 4 | Node card restyle: category stripe, header/port separation, larger hit targets, badge repositioning | `NodeEditorComponents.swift` | low |
| 5 | Inspector density pass: row rhythm, modified-vs-default indicator, section rules | `NodeParameterInspector.swift` | low |
| 6 | Graph action bar: compact icon buttons + zoom control, matching GAEA's corner-menu density | `NodeEditorCanvas.swift` | low |
| 7 | Walk the §2 checklist item by item in the running app; fix anything unreachable | — | — |

Phases 4–6 are independent of 1–3 and can be reordered if something in the layout
work turns out to be harder than expected.

## 4a. Verification results (2026-07-28)

All seven phases landed. Every §2 item was confirmed present, by one of:

- **Live** — seen working in the running app.
- **Test** — covered by an automated check.
- **Code** — the implementing code is unchanged by this work.

| Area | How confirmed |
|---|---|
| Title bar: load, save, reset camera, orbit, pan, zoom, grid, axes, wireframe | Live (`fluvial.json`) — active states render |
| Title bar: conditional Mask eraser group | Live (`rivers.json`) — appears only with an editable mask previewed |
| Viewport: projection / display-mode / material menus, settings popover | Code — `floatingViewportMenus` and `ViewportSettingsPopover` untouched |
| Viewport: axis gizmo, status badge, hover hint | Live |
| Graph: add palette with search + all 10 categories | Live (popover open, Output → Export) |
| Graph: delete, duplicate, layout, undo, redo, zoom | Live — all fit the bar; disabled states honoured |
| Graph: node cards, ports, badges, category colours | Live — terrain / noise / combine / shape / mask / river / output all distinct |
| Graph: empty state + Quick Add starters | Live (no graph argument) |
| Output tray: counts, "Graph is healthy", auto-expand on error | Live — 2-warning badge on the empty graph |
| Inspector: bounded sliders, typed entry | Test — `theia-viewer --self-test` |
| Inspector: modified-vs-default marker + per-parameter reset | Live (`masks.json`: Gamma / Input High / Input Low) **and** Test |
| Inspector: node header, preview-output ports, Set as Graph Output, advanced group | Live |
| Export controls (destination, formats, mesh, scale, reset, export) | Live — export node selected |
| Keyboard shortcuts, hot reload, autosave, `--smoke` | Code — `main.swift` shortcut monitor untouched; smoke passes |

### Changes beyond the original plan

- **Canvas framing.** The graph now frames itself on load and after auto-layout,
  and stops doing so once the user pans or zooms. Without it the graph could sit
  entirely off-screen after a pane resize.
- **Dead code removed.** `GraphActions` and `ViewportControls` had no call sites
  at `HEAD` and duplicated the title bar and the settings popover respectively.
- **New regression test.** `inspector detects modified parameters against their
  defaults` — it fails loudly if `defaultParams` ever returns empty for a node
  type, which would otherwise hide every per-parameter reset control silently.

## 5. Verification

1. `swift build` clean.
2. `swift run theia-tests` — `ViewerSelfTests` green, including the parameter-range
   assertions (every range finite, every range contains its default).
3. `swift run theia-viewer --smoke` — window launches clean.
4. Manual pass over the §2 checklist with `examples/fluvial.json` loaded and a node
   selected, plus one pass with an `export` node selected and one with a mask node
   selected (to exercise the conditional Mask toolbar group and the brush controls).
5. Screenshot before/after for the record.

## 6. Known unknowns

- **Unified titlebar under SwiftUI + a hosting view.** `main.swift` builds the
  window manually and installs an `NSHostingView`. If `.unifiedCompact` fights the
  hosting view, phase 1 falls back to a slim custom 36pt header bar inside the
  SwiftUI tree — same reclaimed space, less platform integration.
- **Three-way `HSplitView` minimums.** Current mins are viewport 560 and inspector
  340. Three columns at those mins need ≥ ~1200pt of width. The viewer already
  opens near-fullscreen (`windowedFullscreenFrame`), so this should hold, but the
  graph column will get a low minimum (~280pt) and the layout will be checked at
  1280×800.
