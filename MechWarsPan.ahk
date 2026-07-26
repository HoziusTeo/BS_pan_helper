#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"

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

; On-screen status (TrayTip is silently suppressed by Focus Assist).
global StatusGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
StatusGui.BackColor := "202020"
StatusGui.SetFont("s10 cFFFFFF", "Segoe UI")
global StatusTxt := StatusGui.Add("Text", "w230 Center", "starting")
StatusGui.Show("x10 y10 w230 h26 NoActivate")
SetStatus("READY - " TOGGLE_KEY " toggles", "202020")

SetStatus(msg, colour) {
    global StatusGui, StatusTxt
    StatusGui.BackColor := colour
    StatusTxt.Value := msg
}

TogglePan() {
    global Active
    if Active
        StopPan()
    else
        StartPan()
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
    SendInput "{LButton down}"
    if HIDE_CURSOR
        HideSystemCursor()
    if SHOW_OVERLAY
        ShowOverlay()
    SetStatus("PAN ON - " TOGGLE_KEY " to stop", "006600")
    SetTimer Tick, POLL_MS
}

StopPan() {
    global Active
    if !Active
        return
    SetTimer Tick, 0
    SendInput "{LButton up}"          ; never leave the button stuck down
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
    MouseGetPos(&mx, &my)
    if (mx != LastMX || my != LastMY) {
        ; EMA-filtered velocity: single-poll deltas are noisy, and this feeds
        ; the slow-reset decision and warp-direction choice - not the player's
        ; input itself, so aiming stays direct.
        VelX := VelX * 0.7 + (mx - LastMX) * 0.3
        VelY := VelY * 0.7 + (my - LastMY) * 0.3
        LastMoveTick := A_TickCount
        IdleDone := false
    }
    LastMX := mx, LastMY := my

    ; --- forced reset at the travel boundary (directional warp) ------------
    ; Fixed safe warp points per exit direction. Never derive the warp Y from
    ; the current Y: a preserved-Y warp to x=80 could land on the Shift button
    ; at (81.8, 61.6) and fire it.
    exitL := mx < TLX,  exitR := mx > TRX
    exitT := my < TTY,  exitB := my > TBY
    if (exitL || exitR || exitT || exitB) {
        wp := exitL ? WARP_EXIT_L : exitR ? WARP_EXIT_R
            : exitT ? WARP_EXIT_T : WARP_EXIT_B
        DoReset(WinX + WinW * wp[1] / 100, WinY + WinH * wp[2] / 100)
        return
    }

    ; --- opportunistic resets: do them when they are invisible --------------
    speed := Sqrt(VelX * VelX + VelY * VelY)
    softOK := (A_TickCount - LastSoftReset > SOFT_RESET_GAP_MS)

    ; a) mouse paused entirely: recentre on the NEUTRAL point, which balances
    ;    runway in both horizontal directions for whatever comes next.
    if (!IdleDone && softOK && A_TickCount - LastMoveTick > IDLE_RESET_MS) {
        ntx := WinX + WinW * WARP_NEUTRAL[1] / 100
        nty := WinY + WinH * WARP_NEUTRAL[2] / 100
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
        Sleep RESET_PAUSE_MS
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
    RestoreSystemCursor(),
    DllCall("winmm\timeEndPeriod", "uint", 1)
))
