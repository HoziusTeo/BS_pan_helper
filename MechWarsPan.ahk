#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"
CoordMode "Pixel", "Screen"

; =============================================================================
;  Mech Wars pan helper  -  v4 "seamless"
;
;  Replaces BlueStacks' broken "Pan" control with raw click-drags on the game
;  surface, driven by mouse movement, with release -> warp -> re-press resets.
;
;  Why v3 still jittered, and what v4 does about it:
;
;   1. FLING. Touch frameworks compute a release velocity; lifting a finger
;      mid-fast-drag makes the game fling the camera with momentum, which the
;      next touch-down then kills - a visible rubber-band jerk at every reset.
;      Fix: DECELERATE the touch to ~zero velocity over ~10 ms BEFORE lifting.
;      Zero velocity at release = no fling, in games with or without inertia.
;
;   2. LOST MOTION. Mouse movement during the release->press gap went nowhere.
;      Fix: measure cursor movement across the gap (and the decel steps) into a
;      carry buffer, then drain it over the next few polls after re-press. The
;      reset becomes a ~25 ms time-warp - slight slow-down, slight catch-up -
;      instead of a freeze-and-jump. No motion is ever discarded.
;
;   3. RESETS AT SPEED. A reset is only visible when the camera is moving fast.
;      Fix: predictive resets - whenever the mouse is slow or paused and the
;      finger is far from its ideal start, reset THEN, invisibly. Boundary
;      resets during a fast continuous turn become the rare case.
;
;   4. The v3 slop nudge added an 8 px artificial jump per reset if the game
;      has no touch slop. Now default 0 - the measured carry replaces it.
;
;  CapsLock toggles pan mode.   Ctrl+Alt+P quits.   Ctrl+Alt+R restores cursor.
; =============================================================================

; ------------------------------- CONFIG --------------------------------------
global TOGGLE_KEY     := "``"            ; backtick. ` is AHK's escape char,
                                         ; hence doubled inside the quotes.
                                         ; Alternatives: "CapsLock",
                                         ; "XButton1"/"XButton2" (thumb btns)
global PANIC_KEY      := "^!p"           ; stop + exit
global CURSOR_FIX_KEY := "^!r"           ; force-restore the cursor

; Travel boundary (percent of BlueStacks client area): how far the drag may
; range before a forced reset. X_MIN 52: the game's floating joystick owns the
; left half (x < 50) and reinterprets touches that wander in - confirmed as
; the left-pan jitter source. Buttons (x >= 66) only react to touch-DOWN, so
; ranging right/vertically is safe.
global TRAVEL_X_MIN := 52.0
global TRAVEL_X_MAX := 90.0
global TRAVEL_Y_MIN := 16.0
global TRAVEL_Y_MAX := 86.0

; Touch-down corridor (percent): where the finger may LAND on a reset.
; Must stay clear of the game's joystick (X < 50) and mapped buttons (X >= 66).
global WARP_X_MIN := 52.5
global WARP_X_MAX := 63.0
global WARP_Y_MIN := 40.0
global WARP_Y_MAX := 58.0

; --- reset mechanics ---
global FLING_KILL     := false   ; decel-before-lift: OFF - added visible wiggle
global DECEL_STEP_MS  := 4       ; duration of each of the 2 decel steps
global RESET_PAUSE_MS := 3       ; release -> re-press gap. Lower = shorter
                                 ; blink, but too low and the game merges the
                                 ; two touches - the warp then becomes a
                                 ; violent camera JUMP. If you ever see one,
                                 ; put this back to 5. That is the floor.
global SLOP_COMP_PX   := 0       ; extra px along travel dir after re-press.
global CATCHUP_RATE   := 1.0     ; carry applied at once - no rubber-banding
global CATCHUP_MAX_PX := 999     ; effectively uncapped

; --- when to reset ---
global IDLE_RESET_MS     := 40   ; mouse still for this long -> free recentre
global SLOW_RESET_SPEED  := 1.5  ; px/poll below which a reset is invisible
global SLOW_RESET_FRAC   := 0.5  ; how far off ideal start before a slow reset
global SOFT_RESET_GAP_MS := 150  ; min interval between opportunistic resets

; Direction-aware warp targets (percent). The warp happens while the finger is
; lifted, so it cannot move the camera - the target may be ANY safe touch-down
; spot, not just the narrow corridor. These sit in open screen areas, clear of
; the joystick (x<50) and every mapped button, and give ~28% of screen runway
; in the direction of travel - vs 11% leftward with the old corridor warp.
global WARP_EXIT_L := [88.0, 25.0]   ; exited left  -> respawn far right-top
global WARP_EXIT_R := [54.0, 45.0]   ; exited right -> respawn near-centre
global WARP_EXIT_T := [57.0, 75.0]   ; exited top   -> respawn low
global WARP_EXIT_B := [57.0, 30.0]   ; exited bottom-> respawn high
; Neutral respawn for idle resets: direction unknown, so sit where both
; horizontal runways are balanced (left 18%, right 20%). Clear of E (72,58)
; by 28% vertically. The old corridor-centre target left only ~6% leftward
; runway, so the first left flick after any pause reset almost immediately.
global WARP_NEUTRAL := [70.0, 30.0]

; --- fire on mouse button -----------------------------------------------
; Hold FIRE_BUTTON during pan mode = hold the game's fire key (like a
; normal shooter). Works even for LButton: the hotkey hook only catches
; PHYSICAL presses, so the script's own synthetic held-LButton that drives
; the camera drag is unaffected, and your physical press/release is
; swallowed before it can disturb the drag.
; While the fire touch is down, BlueStacks holds a second contact on the
; fire button at ~(81.6, 74.9). Protocol A matches touches by POSITION, so
; if the camera drag wanders near it the two contacts can swap identities -
; that is the "camera stops while firing" bug. Fix: while firing, the
; camera's travel band and warp targets keep >=11% horizontal distance
; from the fire button at all times.
global FIRE_ENABLED      := true
global FIRE_BUTTON       := "LButton"    ; "LButton" or "RButton"
global FIRE_SEND_KEY     := "Space"      ; key BlueStacks maps to the fire tap
; While firing, the camera drag lives in the UPPER band (y <= 55%): full
; horizontal runway, and >=20% vertical separation from the fire touch at
; (81.6, 74.9) no matter where x is. (The first attempt capped X instead -
; that gave only 11% separation AND shrank leftward runway to 16%, causing
; more resets exactly while firing.)
global FIRE_TRAVEL_Y_MAX := 55.0
global FIRE_WARP_EXIT_L  := [88.0, 22.0]
global FIRE_WARP_EXIT_R  := [54.0, 22.0]
global FIRE_WARP_EXIT_T  := [57.0, 46.0]
global FIRE_WARP_EXIT_B  := [57.0, 22.0]
global FIRE_WARP_NEUTRAL := [70.0, 26.0]
; Re-stack contacts at trigger pull: lift camera, land fire FIRST, re-touch
; camera SECOND. Camera resets during the burst then never reorder the
; contacts - many mobile games mis-handle pointer reordering mid-gesture,
; which showed up as "sometimes freezes at a reset while firing".
global FIRE_ORDER_FIX    := true
; Keep the reset gap SHORT while other touches are held: the residual stick
; is a newborn tap contact stealing the camera's pointer identity during
; the release->re-press gap, so every millisecond of gap is attack surface.
; (An earlier 14 ms value tested a BlueStacks-timing theory - disproven.)
global FIRE_RESET_PAUSE_MS := 3
; DISABLED after the repro was found (fire held -> WASD/keys join -> stuck):
; the freeze fires AT camera resets that happen while other contacts are
; held - identity reshuffle in the pointer roster. Forced periodic resets
; (this heartbeat) were adding stuck-lottery draws, not healing them.
global FIRE_HEARTBEAT_MS := 0
; Combat band likewise retired: proximity was never the mechanism (X-cap
; and Y-band both failed to fix it), and a tighter band = more resets =
; more reshuffle opportunities. Full runway while firing = fewest resets.
global FIRE_BAND := false
; The real mitigation: never do an OPTIONAL reset near a key transition.
; Tap/D-pad touches are born and die when these keys change state; a camera
; reset colliding with that window is when identities get scrambled.
; Boundary resets still run (unavoidable), but idle/slow resets hold off.
global TAP_KEYS := ["1","2","3","e","q","f","r","Tab","Shift"
                  , "w","a","s","d"]
global TAP_QUIET_MS := 300

; --- auto pan: engage/disengage with the battle HUD ---------------------
global AUTO_PAN     := true      ; auto-toggle pan when a battle starts/ends
global AUTO_POLL_MS := 400
; Battle-only HUD pixels (percent of client area, expected 0xRRGGBB).
; Anchored to LOADOUT-INDEPENDENT UI: the chat bubble and the minimap player
; arrow (always centred on the minimap). The first calibration used the
; weapon-slot column, whose icons change with the equipped mech - it broke
; the moment the loadout changed. These two matched across 10 battle frames
; spanning four battles and two loadouts, and neither appears on any menu,
; robot-select or fail screen. Both stay visible under the scoreboard (pan
; stays on) and are covered by the in-battle settings menu (pan yields the
; cursor). BOTH must match. Assumes the game area fills the client area
; (fullscreen / no BlueStacks sidebar) - recalibrate if playing windowed.
global AUTO_POINTS := [[97.20, 94.07, 0xCBEBFF]   ; chat bubble icon
                     , [ 7.81, 14.81, 0xFDE90A]]  ; minimap player arrow
global AUTO_TOL := 45            ; per-channel colour tolerance (scaling drift)

global POLL_MS      := 5
global HIDE_CURSOR  := true
global SHOW_OVERLAY := false     ; travel boundary - tuning aid only

global BS_EXE := "ahk_exe HD-Player.exe"
; -----------------------------------------------------------------------------

global Active := false, Resetting := false
global CursorHidden := false
global TLX:=0, TRX:=0, TTY:=0, TBY:=0            ; travel bounds, px
global WLX:=0, WRX:=0, WTY:=0, WBY:=0            ; warp corridor, px
global WCX:=0, WCY:=0                            ; corridor centre, px
global WinX:=0, WinY:=0, WinW:=0, WinH:=0        ; client rect, px
global BattleStreak:=0, MenuStreak:=0            ; auto-pan detection state
global AutoStarted:=false, ManualOff:=false
global FireHeld:=false                           ; fire button currently held
global TFY:=0                                    ; combat TRAVEL_Y_MAX, px
global LastResetTick:=0, MovedSinceReset:=0      ; fire-heartbeat state
global TapSig:="", TapQuietUntil:=0              ; key-transition quiet window
global LastMX:=0, LastMY:=0, LastMoveTick:=0, IdleDone:=false
global VelX:=0, VelY:=0
global CarryX:=0.0, CarryY:=0.0                  ; motion owed to the camera
global LastSoftReset := 0
global Bars := []

; Real 1 ms timers (Windows default granularity is ~15.6 ms) + high priority
; so polls and pauses are what the config says they are.
DllCall("winmm\timeBeginPeriod", "uint", 1)
ProcessSetPriority "High"

; BlueStacks installs its own low-level keyboard hook; force AHK's hooks on so
; the toggle key is caught reliably rather than being swallowed.
InstallKeybdHook()
InstallMouseHook()

Hotkey TOGGLE_KEY, (*) => TogglePan()
Hotkey PANIC_KEY, (*) => (StopPan(), RestoreSystemCursor(), ExitApp())
Hotkey CURSOR_FIX_KEY, (*) => (RestoreSystemCursor(), SetStatus("cursor restored", "202020"))

; Mouse button -> fire, only while pan mode is active. Suppresses the
; physical button (so BlueStacks' own mapping for it cannot double-act, and
; a physical LButton release cannot lift the synthetic camera drag) and
; holds the game's fire key instead. Outside pan mode the button is normal.
if FIRE_ENABLED {
    HotIf (*) => Active
    Hotkey "*" FIRE_BUTTON, (*) => FireDown()
    Hotkey "*" FIRE_BUTTON " Up", (*) => FireUp()
    HotIf
}

FireDown() {
    global
    if FireHeld
        return
    FireHeld := true
    if (FIRE_ORDER_FIX && Active) {
        ; Re-stack: camera up -> fire touch lands FIRST -> camera re-touches
        ; SECOND, inside the combat band. Later camera resets then never
        ; reorder the two contacts mid-burst.
        Resetting := true
        try {
            SendInput "{LButton up}"
            Sleep 8
            SendInput "{" FIRE_SEND_KEY " down}"
            Sleep 30
            nx := WinX + WinW * FIRE_WARP_NEUTRAL[1] / 100
            ny := WinY + WinH * FIRE_WARP_NEUTRAL[2] / 100
            DllCall("SetCursorPos", "int", Round(nx), "int", Round(ny))
            SendInput "{LButton down}"
            LastMX := nx, LastMY := ny
            LastResetTick := A_TickCount, MovedSinceReset := 0
        } finally {
            Resetting := false
        }
    } else {
        SendInput "{" FIRE_SEND_KEY " down}"
    }
}

FireUp() {
    global FireHeld
    if !FireHeld
        return
    FireHeld := false
    SendInput "{" FIRE_SEND_KEY " up}"
}

; On-screen status (TrayTip is silently suppressed by Focus Assist).
global StatusGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
StatusGui.BackColor := "202020"
StatusGui.SetFont("s10 cFFFFFF", "Segoe UI")
global StatusTxt := StatusGui.Add("Text", "w230 Center", "starting")
StatusGui.Show("x10 y10 w230 h26 NoActivate")
SetStatus("READY - " TOGGLE_KEY " toggles", "202020")

if AUTO_PAN
    SetTimer AutoTick, AUTO_POLL_MS

SetStatus(msg, colour) {
    global StatusGui, StatusTxt
    StatusGui.BackColor := colour
    StatusTxt.Value := msg
}

TogglePan() {
    global
    if Active {
        ; Manual stop during a detected battle means "leave me alone until
        ; this battle ends" - the auto-engager respects it.
        ManualOff := (BattleStreak > 0)
        AutoStarted := false
        StopPan()
    } else {
        ManualOff := false
        AutoStarted := false
        StartPan()
    }
}

; ---- battle detection: sample battle-only HUD pixels, vote 2-of-3 ----------
AutoTick() {
    global
    if (!AUTO_PAN || Resetting)
        return
    if !WinActive(BS_EXE) {
        BattleStreak := 0
        return
    }
    if !ComputeRect()
        return
    hits := 0
    for p in AUTO_POINTS {
        try {
            c := PixelGetColor(Round(WinX + WinW * p[1] / 100)
                             , Round(WinY + WinH * p[2] / 100))
            if ColorNear(c, p[3], AUTO_TOL)
                hits++
        }
    }
    if (hits >= 2) {
        BattleStreak++
        MenuStreak := 0
    } else {
        MenuStreak++
        BattleStreak := 0
    }
    ; act only on state TRANSITIONS (streak exactly 2 = debounced edge)
    if (BattleStreak = 2 && !Active && !ManualOff) {
        StartPan()
        AutoStarted := Active
        if Active
            SetStatus("PAN ON (auto) - " TOGGLE_KEY " to stop", "006600")
    } else if (MenuStreak = 2) {
        ManualOff := false
        if (Active && AutoStarted) {
            AutoStarted := false
            StopPan()
        }
    }
}

ColorNear(c, ref, tol) {
    return Abs((c >> 16 & 0xFF) - (ref >> 16 & 0xFF)) <= tol
        && Abs((c >> 8 & 0xFF) - (ref >> 8 & 0xFF)) <= tol
        && Abs((c & 0xFF) - (ref & 0xFF)) <= tol
}

; Recompute everything in screen px at every activation, so moving/resizing
; the BlueStacks window never requires a script restart.
ComputeRect() {
    global
    if !WinExist(BS_EXE)
        return false
    WinGetClientPos(&cx, &cy, &cw, &ch, BS_EXE)
    if (cw <= 0 || ch <= 0)
        return false
    WinX := cx, WinY := cy, WinW := cw, WinH := ch
    TFY := cy + ch * FIRE_TRAVEL_Y_MAX / 100
    TLX := cx + cw * TRAVEL_X_MIN / 100
    TRX := cx + cw * TRAVEL_X_MAX / 100
    TTY := cy + ch * TRAVEL_Y_MIN / 100
    TBY := cy + ch * TRAVEL_Y_MAX / 100
    WLX := cx + cw * WARP_X_MIN / 100
    WRX := cx + cw * WARP_X_MAX / 100
    WTY := cy + ch * WARP_Y_MIN / 100
    WBY := cy + ch * WARP_Y_MAX / 100
    WCX := (WLX + WRX) / 2
    WCY := (WTY + WBY) / 2
    return true
}

StartPan() {
    global
    if !ComputeRect() {
        SetStatus("BlueStacks not found", "AA0000")
        return
    }
    Active := true
    Resetting := false
    CarryX := 0.0, CarryY := 0.0
    VelX := 0, VelY := 0
    DllCall("SetCursorPos", "int", Round(WCX), "int", Round(WCY))
    LastMX := WCX, LastMY := WCY
    LastMoveTick := A_TickCount, IdleDone := false
    LastResetTick := A_TickCount, MovedSinceReset := 0
    SendInput "{LButton down}"
    if HIDE_CURSOR
        HideSystemCursor()
    if SHOW_OVERLAY
        ShowOverlay()
    SetStatus("PAN ON - " TOGGLE_KEY " to stop", "006600")
    SetTimer Tick, POLL_MS
}

StopPan() {
    global Active, FireHeld
    if !Active
        return
    SetTimer Tick, 0
    SendInput "{LButton up}"          ; never leave the button stuck down
    if FireHeld {                     ; nor the fire key
        SendInput "{" FIRE_SEND_KEY " up}"
        FireHeld := false
    }
    Active := false
    RestoreSystemCursor()
    HideOverlay()
    SetStatus("PAN OFF", "202020")
}

Tick() {
    global
    if (!Active || Resetting)
        return
    ; If BlueStacks loses focus, stop rather than click-dragging the desktop.
    if !WinActive(BS_EXE) {
        StopPan()
        return
    }
    ; Watchdog: SendInput briefly removes AHK's hooks while sending, so a
    ; physical trigger release can slip through mid-reset and lift the
    ; camera drag. If the logical button is ever up while pan is on,
    ; re-press within one poll - any lifted drag self-heals in milliseconds.
    if !GetKeyState("LButton") {
        SendInput "{LButton down}"
        return
    }
    MouseGetPos(&mx, &my)
    if (mx != LastMX || my != LastMY) {
        ; EMA-filtered velocity: single-poll deltas are noisy, and this feeds
        ; the slow-reset decision and warp-direction choice - not the player's
        ; input itself, so aiming stays direct.
        VelX := VelX * 0.7 + (mx - LastMX) * 0.3
        VelY := VelY * 0.7 + (my - LastMY) * 0.3
        MovedSinceReset += Abs(mx - LastMX) + Abs(my - LastMY)
        LastMoveTick := A_TickCount
        IdleDone := false
    }
    LastMX := mx, LastMY := my

    ; --- forced reset at the travel boundary (directional warp) ------------
    ; Fixed safe warp points per exit direction. Never derive the warp Y from
    ; the current Y: a preserved-Y warp to x=80 could land on the Shift button
    ; at (81.8, 61.6) and fire it.
    ; While ANY held tap-touch is down (fire key, or a physically held RMB
    ; feeding BlueStacks' own tap), confine the drag to the upper band and
    ; use combat warp targets - the camera contact stays >=20% away from
    ; the held touch at all times.
    fireActive := FireHeld || GetKeyState(FIRE_SEND_KEY, "P")
               || GetKeyState("RButton", "P")

    ; Key-transition tracker: any tap/D-pad key changing state means a
    ; BlueStacks contact is being born or dying - hold off on optional
    ; resets so the camera's identity is never reshuffled mid-transition.
    sig := ""
    for k in TAP_KEYS
        sig .= GetKeyState(k, "P") ? "1" : "0"
    if (sig != TapSig) {
        TapSig := sig
        TapQuietUntil := A_TickCount + TAP_QUIET_MS
    }
    quiet := (A_TickCount < TapQuietUntil)

    exitL := mx < TLX,  exitR := mx > TRX
    exitT := my < TTY,  exitB := my > ((fireActive && FIRE_BAND) ? TFY : TBY)
    if (exitL || exitR || exitT || exitB) {
        ; Defer even boundary resets inside a key-transition quiet window -
        ; the boundary is our own trigger, not a wall, so letting the drag
        ; run a little long for <=300 ms is free. Exception: the LEFT
        ; boundary resets immediately (beyond it lies the joystick zone).
        if (quiet && !exitL)
            return
        if (fireActive && FIRE_BAND)
            wp := exitL ? FIRE_WARP_EXIT_L : exitR ? FIRE_WARP_EXIT_R
                : exitT ? FIRE_WARP_EXIT_T : FIRE_WARP_EXIT_B
        else
            wp := exitL ? WARP_EXIT_L : exitR ? WARP_EXIT_R
                : exitT ? WARP_EXIT_T : WARP_EXIT_B
        DoReset(WinX + WinW * wp[1] / 100, WinY + WinH * wp[2] / 100)
        return
    }

    ; Fire heartbeat: while firing and actively moving the camera, guarantee
    ; a fresh camera touch at least every FIRE_HEARTBEAT_MS - a fresh touch
    ; is what un-sticks a game-side freeze, capping it at ~0.7 s.
    if (fireActive && FIRE_HEARTBEAT_MS && !quiet
        && A_TickCount - LastResetTick > FIRE_HEARTBEAT_MS
        && MovedSinceReset > 25) {
        wp := (VelX < 0) ? FIRE_WARP_EXIT_L : FIRE_WARP_EXIT_R
        DoReset(WinX + WinW * wp[1] / 100, WinY + WinH * wp[2] / 100)
        return
    }

    ; --- opportunistic resets: do them when they are invisible --------------
    ; ...and never inside a key-transition quiet window.
    speed := Sqrt(VelX * VelX + VelY * VelY)
    softOK := (A_TickCount - LastSoftReset > SOFT_RESET_GAP_MS) && !quiet

    ; a) mouse paused entirely: recentre on the NEUTRAL point, which balances
    ;    runway in both horizontal directions for whatever comes next.
    if (!IdleDone && softOK && A_TickCount - LastMoveTick > IDLE_RESET_MS) {
        np := fireActive ? FIRE_WARP_NEUTRAL : WARP_NEUTRAL
        ntx := WinX + WinW * np[1] / 100
        nty := WinY + WinH * np[2] / 100
        if (Abs(mx - ntx) > WinW * 0.06 || Abs(my - nty) > WinH * 0.10) {
            DoReset(ntx, nty)
            LastSoftReset := A_TickCount
        }
        IdleDone := true
        return
    }

    ; b) mouse moving slowly and finger far from ideal start: reset now,
    ;    while it cannot be seen, instead of later at full turn speed.
    if (softOK && speed > 0 && speed < SLOW_RESET_SPEED) {
        runX := (WRX - WLX) + (TRX - TLX)
        farX := (mx < WLX - (WLX - TLX) * SLOW_RESET_FRAC)
             || (mx > WRX + (TRX - WRX) * SLOW_RESET_FRAC)
        farY := (my < WTY - (WTY - TTY) * SLOW_RESET_FRAC)
             || (my > WBY + (TBY - WBY) * SLOW_RESET_FRAC)
        if (farX || farY) {
            ; Warp to the direction-appropriate exit target - maximum runway
            ; in the direction of travel, same as forced resets.
            if fireActive
                wp := farX ? (VelX < 0 ? FIRE_WARP_EXIT_L : FIRE_WARP_EXIT_R)
                           : (VelY < 0 ? FIRE_WARP_EXIT_T : FIRE_WARP_EXIT_B)
            else
                wp := farX ? (VelX < 0 ? WARP_EXIT_L : WARP_EXIT_R)
                           : (VelY < 0 ? WARP_EXIT_T : WARP_EXIT_B)
            DoReset(WinX + WinW * wp[1] / 100, WinY + WinH * wp[2] / 100)
            LastSoftReset := A_TickCount
            return
        }
    }

    ; --- drain the carry buffer: motion owed from previous resets ----------
    if (Abs(CarryX) > 0.5 || Abs(CarryY) > 0.5) {
        dx := CarryX * CATCHUP_RATE
        dy := CarryY * CATCHUP_RATE
        dx := (dx >  CATCHUP_MAX_PX) ?  CATCHUP_MAX_PX
            : (dx < -CATCHUP_MAX_PX) ? -CATCHUP_MAX_PX : dx
        dy := (dy >  CATCHUP_MAX_PX) ?  CATCHUP_MAX_PX
            : (dy < -CATCHUP_MAX_PX) ? -CATCHUP_MAX_PX : dy
        DllCall("SetCursorPos", "int", Round(mx + dx), "int", Round(my + dy))
        CarryX -= dx, CarryY -= dy
        LastMX := mx + dx, LastMY := my + dy
    }
}

DoReset(nx, ny) {
    global
    Resetting := true
    try {
        ; 1) Kill the fling: walk the touch to ~zero velocity before lifting.
        ;    User motion overridden during these steps goes into the carry.
        if (FLING_KILL && (VelX != 0 || VelY != 0)) {
            MouseGetPos(&lsx, &lsy)
            f := 0.5
            Loop 2 {
                tx := lsx + VelX * f
                ty := lsy + VelY * f
                DllCall("SetCursorPos", "int", Round(tx), "int", Round(ty))
                Sleep DECEL_STEP_MS
                MouseGetPos(&cx2, &cy2)
                CarryX += cx2 - tx
                CarryY += cy2 - ty
                lsx := tx, lsy := ty
                f := f * 0.4
            }
        }
        ; 2) Lift, and measure every px the mouse moves while the finger is up.
        SendInput "{LButton up}"
        MouseGetPos(&u0x, &u0y)
        pauseMs := (FireHeld || GetKeyState(FIRE_SEND_KEY, "P")
                 || GetKeyState("RButton", "P"))
                 ? FIRE_RESET_PAUSE_MS : RESET_PAUSE_MS
        Sleep pauseMs
        MouseGetPos(&u1x, &u1y)
        CarryX += u1x - u0x
        CarryY += u1y - u0y
        ; 3) Fresh touch at the warp target; carry drains over the next polls.
        DllCall("SetCursorPos", "int", Round(nx), "int", Round(ny))
        SendInput "{LButton down}"
        if (SLOP_COMP_PX > 0) {
            m := Sqrt(VelX * VelX + VelY * VelY)
            if (m > 0.5) {
                Sleep 1
                nx := nx + SLOP_COMP_PX * VelX / m
                ny := ny + SLOP_COMP_PX * VelY / m
                DllCall("SetCursorPos", "int", Round(nx), "int", Round(ny))
            }
        }
        LastMX := nx, LastMY := ny
        LastResetTick := A_TickCount, MovedSinceReset := 0
    } finally {
        Resetting := false
    }
}

; --- cursor hiding ----------------------------------------------------------
; SetSystemCursor swaps the cursor globally, so it MUST be restored. Restored
; on toggle-off, on exit, and by CURSOR_FIX_KEY.
HideSystemCursor() {
    global CursorHidden
    if CursorHidden
        return
    static ids := [32512, 32513, 32514, 32515, 32516, 32631, 32642, 32643
                 , 32644, 32645, 32646, 32648, 32649, 32650, 32651]
    for id in ids {
        andMask := Buffer(128, 0xFF)      ; opaque AND + zero XOR = invisible
        xorMask := Buffer(128, 0x00)
        hCur := DllCall("CreateCursor", "ptr", 0, "int", 0, "int", 0
                      , "int", 32, "int", 32, "ptr", andMask, "ptr", xorMask, "ptr")
        if hCur
            DllCall("SetSystemCursor", "ptr", hCur, "int", id)
    }
    CursorHidden := true
}

RestoreSystemCursor() {
    global CursorHidden
    DllCall("SystemParametersInfo", "uint", 0x0057, "uint", 0, "ptr", 0, "uint", 0)
    CursorHidden := false
}
; ----------------------------------------------------------------------------

ShowOverlay() {
    global Bars
    HideOverlay()
    t := 2
    edges := [[TLX, TTY, TRX - TLX, t]
            , [TLX, TBY - t, TRX - TLX, t]
            , [TLX, TTY, t, TBY - TTY]
            , [TRX - t, TTY, t, TBY - TTY]]
    for e in edges {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")   ; click-through
        g.BackColor := "FF3300"
        g.Show(Format("x{1} y{2} w{3} h{4} NoActivate"
            , Round(e[1]), Round(e[2]), Round(e[3]), Round(e[4])))
        Bars.Push(g)
    }
}

HideOverlay() {
    global Bars
    for g in Bars {
        try g.Destroy()
    }
    Bars := []
}

; Safety net: release the button, restore cursor and timer however we exit.
OnExit((*) => (
    Active ? SendInput("{LButton up}") : 0,
    FireHeld ? SendInput("{" FIRE_SEND_KEY " up}") : 0,
    RestoreSystemCursor(),
    DllCall("winmm\timeEndPeriod", "uint", 1)
))
