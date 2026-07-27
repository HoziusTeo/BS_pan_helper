# BS Pan Helper

An emulator helper that uses AutoHotkey to make some games playable — initially
built for **Mech Wars Online** on **BlueStacks 5**.

## The problem it solves

BlueStacks' built-in *Aim / Pan* control funnels every input source (mouse
**and** gamepad) into a single virtual touch finger that drags from a fixed
anchor — and its internal reset never fires. The camera hits an invisible wall
mid-turn, worst when turning left. No control-scheme setting fixes it: anchor
position, bounds, sensitivity, Tweaks, cursor lock, fullscreen and EdgeScroll
were all tested and ruled out.

This tool replaces the Pan control entirely. It holds a left-button touch-drag
on the game surface and, when the drag nears its travel limit, resets it
(release → warp → re-press) at moments chosen to be invisible: while your
mouse is idle or moving slowly, with direction-aware warp targets that
maximise clean runway in the direction you are turning. After tuning, it
feels smoother than the native control.

## Controls

| Key | Action |
|---|---|
| `` ` `` (backtick) | Toggle pan mode — cursor hides, mouse steers the camera |
| `Ctrl+Alt+P` | Panic: release the button, restore the cursor, exit |
| `Ctrl+Alt+R` | Force-restore the system cursor if it ever sticks |

A small status box in the top-left corner shows `READY` / `PAN ON` / `PAN OFF`.

### Changing the hotkeys

All three hotkeys are plain strings in the CONFIG block at the top of
`MechWarsPan.ahk` — edit with any text editor, save, and double-click the
script to reload (`#SingleInstance Force` replaces the running copy):

```ahk
global TOGGLE_KEY     := "``"    ; pan toggle
global PANIC_KEY      := "^!p"   ; Ctrl+Alt+P
global CURSOR_FIX_KEY := "^!r"   ; Ctrl+Alt+R
```

| You want | Write | Note |
|---|---|---|
| Backtick | `"``"` | doubled — `` ` `` is AHK's escape character |
| CapsLock | `"CapsLock"` | toggles the Caps state as a side effect |
| Mouse thumb buttons | `"XButton1"` / `"XButton2"` | best feel — hand never leaves the mouse |
| Middle mouse | `"MButton"` | |
| Function keys / letters | `"F2"`, `"V"`, ... | |

Modifier prefixes for the panic/cursor keys: `^` Ctrl, `!` Alt, `+` Shift,
`#` Win — so `"^!p"` means Ctrl+Alt+P. Full key-name reference:
[AutoHotkey v2 key list](https://www.autohotkey.com/docs/v2/KeyList.htm).

**Avoid keys your game scheme already binds** (here: `1 2 3 E Q F Space
Shift Tab`, right-click) plus `F11` (BlueStacks fullscreen) and `F1`
(BlueStacks shooting mode) — the script won't warn about conflicts, it will
just fire both actions at once.

## Automatic battle detection

With `AUTO_PAN := true` (the default), the script detects battle state by
sampling two battle-only HUD pixels every 400 ms and toggles pan for you:

- **Spawn into battle** → pan engages within ~1 s (`PAN ON (auto)`)
- **Die / finish / return to menus** → pan releases, cursor comes back for
  the UI
- **Open the in-battle settings menu** → pan yields the cursor; re-engages
  when you close it
- **Scoreboard** → pan stays on (the HUD anchors remain visible)
- **Manual override always wins**: toggling pan off mid-battle keeps it off
  for that battle; a manually started session is never auto-stopped

Detection is a 2-of-2 colour match with debounce (two consecutive polls),
anchored to **loadout-independent** UI — the chat bubble and the minimap
player arrow. Do not anchor to weapon/consumable slot icons: they change
with the equipped mech (that mistake was made and paid for during
development).

Caveats:

- Calibrated for **fullscreen** (game area = window client area). Playing
  windowed with the BlueStacks sidebar shifts the corner percentages —
  re-measure `AUTO_POINTS` if you do.
- For another game (or after a HUD redesign), recalibrate: take screenshots
  in and out of battle, find two pixels that are stable across battles and
  absent in menus, and put their percent coordinates + colours in
  `AUTO_POINTS`. Set `AUTO_PAN := false` to disable the feature entirely.

## Minimum system requirements

The script itself is essentially free (≈0.5 % CPU, <10 MB RAM). Requirements
are driven by BlueStacks and the game:

- **Windows 10 (1809+) or Windows 11** — needed by AutoHotkey v2 and the
  Win32 calls the script uses
- **[AutoHotkey v2](https://www.autohotkey.com/)** (v2.0 or later — v1 will not run this script)
- **BlueStacks 5** (developed and tested on 5.22, 1920×1080 instance)
- Any CPU/GPU/RAM that runs BlueStacks 5 and your game comfortably
  (BlueStacks' own minimum is 4 GB RAM + virtualization enabled; if the game
  already runs well, this script adds nothing noticeable)

## Tech stack

- **AutoHotkey v2** — hotkeys, input simulation (`SendInput`), and Win32 via
  `DllCall`: `SetCursorPos` park-and-measure, `SetSystemCursor` cursor hiding,
  `timeBeginPeriod(1)` for real 1 ms timing, high process priority
- **`experimental/mwpan.py`** (optional, Python 3.9+) — an alternative
  architecture that injects multi-touch protocol-A events directly into the
  emulator's Android input device over ADB (`/dev/input/event4`). Fully
  functional and documented in-file; shelved because Mech Wars' camera
  hiccups on multi-touch handoffs. Kept as a fallback if a BlueStacks update
  ever breaks the AHK approach. If you revive it: the adb pipe **must** use
  `dd bs=24` — the default block size silently corrupts the 24-byte event
  stream under load.

## Setup

1. Install [AutoHotkey v2](https://www.autohotkey.com/)
2. Download or clone this repository
3. **Whitelist the folder in your antivirus.** A script that installs
   keyboard hooks and simulates clicks legitimately matches keylogger
   heuristics — Avast and 360 Total Security are both confirmed to silently
   delete it otherwise. Read the script first (it's ~300 commented lines, no
   network access, no file writes), then add the folder as an exception.
4. Double-click `MechWarsPan.ahk`
5. *(Optional)* Auto-start at login: `Win+R` → `shell:startup` → create a
   shortcut to the script there
6. In BlueStacks, open the game, press `` ` `` and move the mouse

## Included BlueStacks control config

`config/com.momend.mechwars.cfg` is a ready-made Mech Wars control scheme
file with two schemes:

**`MechWars`** (selected) — key bindings only, no Pan/EdgeScroll controls,
exactly the clean base this tool wants. Coordinates are screen percentages,
so they scale with the instance resolution (built on 1920×1080 against the
default Mech Wars HUD):

| Key | Taps HUD position (x%, y%) |
|---|---|
| `1` / `2` / `3` | 96.5, 40 / 51 / 61.5 — right-edge column |
| `Right mouse` | 81.6, 89.9 |
| `E` | 72.5, 57.7 |
| `Q` | 66.5, 69.5 |
| `F` | 66.6, 87.2 |
| `Space` | 81.6, 74.9 |
| `Shift` | 74.5, 91.8 |
| `Tab` | 81.2, 61.3 |
| `R` | 50.1, 60.0 |
| `F1` | 90.8, 6.3 |

**`MechWars - Script Pan`** (fallback) — the same bindings plus two
BlueStacks Script controls: **hold `Z` to pan left, `X` to pan right**, via
looped fixed-coordinate swipes. Coarser than the AHK helper, but needs
nothing installed on the host — useful if you can't run AutoHotkey.

### Installing the config

1. **Close BlueStacks completely first** — it rewrites this file from memory
   on exit and will silently overwrite your copy otherwise.
2. Find your BlueStacks data directory (registry key
   `HKLM\SOFTWARE\BlueStacks_nxt` → `UserDefinedDir`, e.g. `D:\BlueStacks_nxt`).
3. Copy the file to
   `<data dir>\Engine\UserData\InputMapper\UserFiles\com.momend.mechwars.cfg`
   (back up the existing one if you have custom bindings).
4. Start BlueStacks — the `MechWars` scheme will be active; switch schemes
   any time from the in-game controls menu.

## Recommendations for optimal gameplay

- **Turn ON the game's auto-fire.** Pan mode holds the left mouse button for
  the camera drag, so you cannot click to shoot while panning — with
  auto-fire enabled you aim with the crosshair and the game fires for you.
  This is the intended way to play with this tool.
- **Max out the in-game camera sensitivity.** More rotation per drag distance
  means the resets happen far less often per degree turned — the single
  biggest smoothness multiplier available, confirmed by testing.
- **Use a plain BlueStacks control scheme** — just your tap/key bindings.
  The included `config/com.momend.mechwars.cfg` is exactly that (see above).
  Never enable BlueStacks' shooting mode (F1) while this tool is active: its
  touch injection fights the script's drag on the same touch pipeline.
- Keep BlueStacks **windowed at a consistent size**. The script re-measures
  the window every time you toggle pan mode, so resizing is fine — just
  toggle off/on afterwards.

## Tuning (CONFIG block at the top of the script)

The defaults are **measured for Mech Wars**, not guessed:

| Setting | Default | Meaning |
|---|---|---|
| `TRAVEL_X_MIN` | `52.0` | Left travel limit (%). The game's floating joystick owns x<50 % and corrupts any touch that wanders in — this bound is what killed the left-side jitter |
| `TRAVEL_X_MAX` | `90.0` | Right travel limit. On-screen buttons only react to touch-*down*, so dragging across them is safe |
| `WARP_EXIT_*` | various | Where the drag respawns per exit direction — open screen areas clear of all HUD buttons |
| `RESET_PAUSE_MS` | `3` | Release→re-press gap. If you ever see a violent camera *jump* at a reset, raise to `5` — below that the game merges the touches |
| `IDLE_RESET_MS` | `40` | Mouse stillness before a free invisible recentre |
| `TOGGLE_KEY` | `` "``" `` | Doubled because backtick is AHK's escape character |

**Porting to another game:** find your game's joystick zone and button
positions, then adjust `TRAVEL_*` and the `WARP_*` targets so the drag never
enters the joystick zone and every warp target lands on empty screen.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Cursor invisible after a crash | `Ctrl+Alt+R`, or restart the script |
| Cursor still visible during pan mode | Disable BlueStacks' **custom mouse cursor** setting (Settings → Preferences). The script blanks the shared Windows system cursors; BlueStacks' custom cursor is a private app cursor and bypasses that mechanism |
| Camera jumps violently at reset points | `RESET_PAUSE_MS := 5` |
| `` ` `` does nothing | BlueStacks must be the foreground window; check the status box exists at all (if not, the AV ate the script — see Setup step 3) |
| Mech walks while panning | Your travel band overlaps the joystick zone — raise `TRAVEL_X_MIN` |
| Auto-pan never engages | You're windowed (sidebar shifts the sample points), or the HUD moved — recalibrate `AUTO_POINTS`, or set `AUTO_PAN := false` and use the manual toggle |

## License

No license file yet — all rights reserved by default. Open an issue if you
want to use this in your own project.
