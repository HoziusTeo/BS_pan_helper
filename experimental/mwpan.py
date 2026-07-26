"""Mech Wars pan injector v1.1 - touch injection inside Android via ADB.

Injects multi-touch protocol-A frames directly into BlueStacks' touch device
(/dev/input/event4). The camera finger hands off to a fresh finger in
back-to-back frames when it nears its travel limit - the touch never ends,
so there is no gap and no fling. Proven in-battle: injected drags rotate the
Mech Wars camera (verified via screencap 2026-07-27).

v1.1:
  - Focus guard accepts both BlueStacks processes and debounces 1.5 s
    (BlueStacksAppplayerWeb.exe takes foreground during normal play).
  - WASD walks the mech: a second injected finger drives the game's on-screen
    joystick. Both fingers ride in the same frames - no conflicts.
  - Telemetry: logs frames/deltas once per second to mwpan.log.

Controls:
  CapsLock    toggle pan mode (mouse = camera, WASD = walk)
  Ctrl+Alt+P  quit (restores everything)

Known limit: while an ability key (1/2/3/E/Q/F/Space/Shift) or mouse button is
held, injection pauses ~150 ms - BlueStacks' own tap-injection shares this
protocol-A device and two writers overwrite each other's contact lists.
"""
import ctypes
import struct
import subprocess
import time
from ctypes import wintypes

# ------------------------------- CONFIG --------------------------------------
ADB = r"C:\Program Files\BlueStacks_nxt\HD-Adb.exe"
SERIAL = "emulator-5554"
DEV = "/dev/input/event4"
BS_EXES = {"hd-player.exe", "bluestacksappplayerweb.exe"}
FOCUS_GRACE_S = 1.5        # foreground may flap this long before pan stops

SENS = 1.4                 # camera speed multiplier
SENS_Y = 1.0               # extra vertical multiplier on top of SENS

# Travel band (fraction of guest screen) for the camera finger. x_min 0.52
# keeps the finger strictly OUT of the game's floating-joystick half (x<0.50),
# which was the source of left-pan jitter.
TRAVEL = (0.52, 0.90, 0.12, 0.88)
# Initial touch-down point: clear of joystick (x<0.50) and buttons (x>=0.66).
CORRIDOR = (0.525, 0.63, 0.40, 0.58)
# Direction-aware respawn points. Only deltas move the camera, so a handoff
# may land anywhere safe - these sit in wide-open screen areas and give
# ~0.35 screen of clean runway in the direction of travel.
RESPAWN_LEFT = (0.88, 0.22)     # exited left edge  -> respawn far right-top
RESPAWN_RIGHT = (0.55, 0.22)    # exited right edge -> respawn centre-top
RESPAWN_UP = (0.575, 0.75)      # exited top edge   -> respawn centre-low
RESPAWN_DOWN = (0.575, 0.25)    # exited bottom     -> respawn centre-high

# The game's on-screen movement joystick (fractions of guest screen).
JOY_CENTER = (0.15, 0.71)
JOY_RADIUS = 0.055         # deflection, fraction of guest width/height

TOGGLE_VK = 0x14           # CapsLock
LOOP_S = 0.004             # ~250 Hz input poll
EMIT_HZ = 240              # touch frame rate. Well above the game's ~60 fps
                           # sampling so each game frame integrates several
                           # small events - eliminates beat-frequency judder
                           # (90 Hz vs 60 Hz alternated 1-and-2 events per
                           # frame and read as constant micro frame-drops).

VK_W, VK_A, VK_S, VK_D = 0x57, 0x41, 0x53, 0x44

# Keys whose BlueStacks tap-injection conflicts with ours.
PAUSE_VKS = {
    0x31: "1", 0x32: "2", 0x33: "3",
    0x45: "E", 0x51: "Q", 0x46: "F",
    0x20: "Space", 0x10: "Shift",
    0x01: "LButton", 0x02: "RButton",
}
PAUSE_TAIL_S = 0.15
# -----------------------------------------------------------------------------

EV_SYN, EV_ABS = 0x00, 0x03
SYN_REPORT, SYN_MT_REPORT = 0x00, 0x02
ABS_X, ABS_Y = 0x35, 0x36
RANGE = 32767

LOG_PATH = r"D:\AI_lab\Bluestacks\mwpan.log"

# One persistent line-buffered handle. Opening/closing per line made the AV
# scan the file on every close - a 10-50 ms stall injected straight into the
# emission loop, i.e. self-inflicted frame drops.
try:
    _logf = open(LOG_PATH, "a", buffering=1, encoding="utf-8")
except OSError:
    _logf = None


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line)
    if _logf is not None:
        try:
            _logf.write(line + "\n")
        except OSError:
            pass


u32 = ctypes.windll.user32
k32 = ctypes.windll.kernel32
winmm = ctypes.windll.winmm

u32.SetProcessDPIAware()
winmm.timeBeginPeriod(1)


def ev(etype, code, value):
    return struct.pack("<qqHHi", 0, 0, etype, code, value)


def frame(contacts):
    """Protocol-A frame declaring the complete current contact list."""
    out = b""
    for x, y in contacts:
        out += ev(EV_ABS, ABS_X, int(x)) + ev(EV_ABS, ABS_Y, int(y))
        out += ev(EV_SYN, SYN_MT_REPORT, 0)
    if not contacts:
        out += ev(EV_SYN, SYN_MT_REPORT, 0)
    return out + ev(EV_SYN, SYN_REPORT, 0)


class Injector:
    def __init__(self):
        self.proc = None
        self.sent = 0
        self.respawns = 0

    def _ensure(self):
        if self.proc is None or self.proc.poll() is not None:
            if self.proc is not None:
                self.respawns += 1
                log(f"  adb pipe respawn #{self.respawns}")
            # bs=24 = exactly one input_event per block. The default bs=512 is
            # NOT a multiple of 24: under sustained rates the stream coalesces,
            # dd writes a 21-and-a-third-event block, the kernel rejects the
            # fragment and the stream dies silently. This was the live-session
            # killer while every slow hands-off test passed.
            self.proc = subprocess.Popen(
                [ADB, "-s", SERIAL, "exec-in", "dd", f"of={DEV}", "bs=24"],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    def send(self, data):
        try:
            self._ensure()
            self.proc.stdin.write(data)
            self.proc.stdin.flush()
            self.sent += 1
            return True
        except OSError:
            try:
                self.proc.kill()
            except OSError:
                pass
            self.proc = None
            return False

    def close(self):
        if self.proc is not None:
            try:
                self.proc.stdin.close()
                self.proc.kill()
            except OSError:
                pass
            self.proc = None


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


class RECT(ctypes.Structure):
    _fields_ = [("l", ctypes.c_long), ("t", ctypes.c_long),
                ("r", ctypes.c_long), ("b", ctypes.c_long)]


def cursor_pos():
    p = POINT()
    u32.GetCursorPos(ctypes.byref(p))
    return p.x, p.y


def pressed(vk):
    return bool(u32.GetAsyncKeyState(vk) & 0x8000)


def foreground_exe():
    hwnd = u32.GetForegroundWindow()
    pid = wintypes.DWORD()
    u32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    h = k32.OpenProcess(0x1000, False, pid.value)
    if not h:
        return hwnd, ""
    buf = ctypes.create_unicode_buffer(512)
    size = wintypes.DWORD(512)
    ok = k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size))
    k32.CloseHandle(h)
    return hwnd, (buf.value.rsplit("\\", 1)[-1].lower() if ok else "")


def client_rect(hwnd):
    r = RECT()
    u32.GetClientRect(hwnd, ctypes.byref(r))
    p = POINT(0, 0)
    u32.ClientToScreen(hwnd, ctypes.byref(p))
    return p.x, p.y, r.r - r.l, r.b - r.t


CURSOR_IDS = [32512, 32513, 32514, 32515, 32516, 32631, 32642, 32643,
              32644, 32645, 32646, 32648, 32649, 32650, 32651]
_cursor_hidden = False


def hide_cursor():
    global _cursor_hidden
    if _cursor_hidden:
        return
    for cid in CURSOR_IDS:
        and_mask = (ctypes.c_ubyte * 128)(*([0xFF] * 128))
        xor_mask = (ctypes.c_ubyte * 128)()
        h = u32.CreateCursor(None, 0, 0, 32, 32, and_mask, xor_mask)
        if h:
            u32.SetSystemCursor(h, cid)
    _cursor_hidden = True


def show_cursor():
    global _cursor_hidden
    u32.SystemParametersInfoW(0x0057, 0, None, 0)
    _cursor_hidden = False


def selftest(inj):
    """Drive the camera through the live pipeline with no human input:
    persistent dd pipe, 60 fps emission, handoffs, joystick joining mid-stream.
    """
    import sys as _s
    tx0 = TRAVEL[0] * RANGE
    cx0, cx1 = CORRIDOR[0] * RANGE, CORRIDOR[1] * RANGE
    cy0, cy1 = CORRIDOR[2] * RANGE, CORRIDOR[3] * RANGE
    cxm, cym = (cx0 + cx1) / 2, (cy0 + cy1) / 2
    jc = (JOY_CENTER[0] * RANGE, JOY_CENTER[1] * RANGE)
    upx = RANGE / 1920.0 * SENS
    finger = [cxm, cym]
    log("SELFTEST: 4 s leftward sweep, joystick joins at t=1..2s")
    if not inj.send(frame([tuple(finger)])):
        log("SELFTEST: pipe failed on first frame")
        return
    t0 = time.time()
    handoffs = 0
    frames = 0
    while time.time() - t0 < 4.0:
        time.sleep(1 / 60)
        t = time.time() - t0
        joy = jc if 1.0 < t < 2.0 else None
        base = [joy] if joy else []
        finger[0] -= 5 * upx           # ~300 px/s of mouse leftward
        if finger[0] < tx0:
            old = (max(finger[0], 0.0), finger[1])
            nx = cx1
            ny = min(max(finger[1], cy0), cy1)
            ok = inj.send(frame(base + [old, (nx, ny)])
                          + frame(base + [(nx, ny)]))
            finger = [nx, ny]
            handoffs += 1
        else:
            ok = inj.send(frame(base + [tuple(finger)]))
        frames += 1
        if not ok:
            log("SELFTEST: pipe lost")
            return
    inj.send(frame([]))
    log(f"SELFTEST done: {frames} frames, {handoffs} handoffs")


def main():
    inj = Injector()
    import sys as _sys
    if "--selftest" in _sys.argv:
        selftest(inj)
        inj.close()
        return
    active = False
    park = (0, 0)
    finger = [0.0, 0.0]
    upx = upy = 1.0
    finger_down = False
    joy = None                   # current joystick contact or None
    prev_toggle = False
    pause_until = 0.0
    paused_logged = False
    fg_check = 0.0
    last_bs_fg = 0.0
    telemetry_at = 0.0
    moved_px = [0, 0]
    acc_dx = acc_dy = 0
    next_emit = 0.0
    joy_dirty = False
    handoffs = 0

    tx0, tx1 = TRAVEL[0] * RANGE, TRAVEL[1] * RANGE
    ty0, ty1 = TRAVEL[2] * RANGE, TRAVEL[3] * RANGE
    cx0, cx1 = CORRIDOR[0] * RANGE, CORRIDOR[1] * RANGE
    cy0, cy1 = CORRIDOR[2] * RANGE, CORRIDOR[3] * RANGE
    cxm, cym = (cx0 + cx1) / 2, (cy0 + cy1) / 2
    jcx, jcy = JOY_CENTER[0] * RANGE, JOY_CENTER[1] * RANGE
    jr = JOY_RADIUS * RANGE

    def contacts():
        out = []
        if joy is not None:
            out.append(joy)
        if finger_down:
            out.append((finger[0], finger[1]))
        return out

    def emit():
        return inj.send(frame(contacts()))

    def stop_pan(msg):
        nonlocal active, finger_down, joy
        finger_down = False
        joy = None
        inj.send(frame([]))
        active = False
        show_cursor()
        log(f"PAN OFF  ({msg})")

    log("v1.1 ready - CapsLock toggles pan, WASD walks, Ctrl+Alt+P quits")
    try:
        while True:
            time.sleep(LOOP_S)
            now = time.monotonic()

            if pressed(0x11) and pressed(0x12) and pressed(0x50):
                break

            tog = pressed(TOGGLE_VK)
            if tog and not prev_toggle:
                if active:
                    stop_pan("toggled")
                else:
                    hwnd, exe = foreground_exe()
                    if exe not in BS_EXES:
                        log(f"not starting: foreground is '{exe}'")
                    else:
                        wx, wy, ww, wh = client_rect(hwnd)
                        if ww < 100 or wh < 100:
                            log("not starting: window too small")
                        else:
                            park = (wx + ww // 2, wy + wh // 2)
                            upx = RANGE / ww * SENS
                            upy = RANGE / wh * SENS * SENS_Y
                            finger = [cxm, cym]
                            u32.SetCursorPos(*park)
                            hide_cursor()
                            finger_down = True
                            if emit():
                                active = True
                                last_bs_fg = now
                                moved_px = [0, 0]
                                log(f"PAN ON  (window {ww}x{wh}, park {park})")
                            else:
                                finger_down = False
                                show_cursor()
                                log("adb pipe failed - is BlueStacks running?")
            prev_toggle = tog

            if not active:
                continue

            # Focus guard with grace period - the BlueStacks web shell takes
            # foreground during normal play, and brief flaps are normal.
            if now > fg_check:
                fg_check = now + 0.2
                _, exe = foreground_exe()
                if exe in BS_EXES:
                    last_bs_fg = now
                elif now - last_bs_fg > FOCUS_GRACE_S:
                    stop_pan(f"focus lost to '{exe}'")
                    continue

            # Telemetry every 2 s - out of the hot path's way.
            if now > telemetry_at:
                telemetry_at = now + 2.0
                log(f"  tick: frames={inj.sent} moved={moved_px} "
                    f"finger=({finger[0]/RANGE:.2f},{finger[1]/RANGE:.2f}) "
                    f"joy={'on' if joy else 'off'} handoffs={handoffs} "
                    f"paused={'yes' if now < pause_until else 'no'}")

            # Ability-key conflict pause.
            pk = [name for vk, name in PAUSE_VKS.items() if pressed(vk)]
            if pk:
                pause_until = now + PAUSE_TAIL_S
                if not paused_logged:
                    paused_logged = True
                    log(f"  pause: {'+'.join(pk)} held")
            if now < pause_until:
                finger_down = False
                joy = None
                continue
            paused_logged = False

            # WASD -> injected joystick finger.
            jx = (1 if pressed(VK_D) else 0) - (1 if pressed(VK_A) else 0)
            jy = (1 if pressed(VK_S) else 0) - (1 if pressed(VK_W) else 0)
            new_joy = None
            if jx or jy:
                m = (jx * jx + jy * jy) ** 0.5
                new_joy = (jcx + jr * jx / m, jcy + jr * jy / m)
            if new_joy != joy:
                joy_dirty = True
            joy = new_joy

            # Mouse deltas via park-and-measure - accumulated between emissions.
            mx, my = cursor_pos()
            dx, dy = mx - park[0], my - park[1]
            if dx or dy:
                u32.SetCursorPos(*park)
                acc_dx += dx
                acc_dy += dy
                moved_px[0] += dx
                moved_px[1] += dy

            # Emit at most EMIT_HZ frames/s - mobile games sample per display
            # frame anyway, and pacing keeps the adb stream burst-free.
            if now < next_emit:
                continue
            next_emit = now + 1.0 / EMIT_HZ

            if not (acc_dx or acc_dy):
                if joy_dirty:
                    joy_dirty = False
                    if not emit():
                        stop_pan("adb pipe lost")
                continue
            joy_dirty = False

            if not finger_down:
                finger = [cxm, cym]
                finger_down = True

            finger[0] += acc_dx * upx
            finger[1] += acc_dy * upy
            acc_dx = 0
            acc_dy = 0

            if not (tx0 <= finger[0] <= tx1) or not (ty0 <= finger[1] <= ty1):
                # Zero-gap handoff: old and new fingers in one frame, then
                # the new finger alone in the next - the touch never ends.
                # Respawn is direction-aware: only deltas drive the camera,
                # so the fresh finger lands wherever gives the most clean
                # runway in the direction of travel.
                old = (min(max(finger[0], 0), RANGE),
                       min(max(finger[1], 0), RANGE))
                if finger[0] < tx0:
                    rp = RESPAWN_LEFT
                elif finger[0] > tx1:
                    rp = RESPAWN_RIGHT
                elif finger[1] < ty0:
                    rp = RESPAWN_UP
                else:
                    rp = RESPAWN_DOWN
                nxy = (rp[0] * RANGE, rp[1] * RANGE)
                base = [joy] if joy is not None else []
                data = frame(base + [old, nxy]) + frame(base + [nxy])
                finger = [nxy[0], nxy[1]]
                handoffs += 1
                if not inj.send(data):
                    stop_pan("adb pipe lost")
                    continue
            else:
                if not emit():
                    stop_pan("adb pipe lost")
                    continue
    finally:
        inj.send(frame([]))
        show_cursor()
        inj.close()
        winmm.timeEndPeriod(1)
        log("exited cleanly")


if __name__ == "__main__":
    main()
