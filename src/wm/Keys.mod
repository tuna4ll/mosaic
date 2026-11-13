IMPLEMENTATION MODULE Keys ;

FROM Xlib IMPORT KeySym, XKeysymToKeycode, XGrabKey, XUngrabKey,
                 GrabModeAsync, AnyKey, AnyModifier, True, ShiftMask,
                 LockMask, ControlMask, Mod1Mask, Mod4Mask ;
FROM XGlue IMPORT mx_numlock_mask ;
FROM XServer IMPORT dpy, root ;
FROM SYSTEM IMPORT ADR, ADDRESS ;
IMPORT Log ;
FROM libc IMPORT system ;

CONST
  MaxBindings = 32 ;
  XKTab = 0FF09H ;
  XKF1 = 0FFBEH ;
  XKF2 = 0FFBFH ;
  XKF3 = 0FFC0H ;
  XKF4 = 0FFC1H ;
  XKF9 = 0FFC6H ;
  XKF10 = 0FFC7H ;
  XKF11 = 0FFC8H ;
  XKLeft = 0FF51H ;
  XKRight = 0FF53H ;
  XKAltL = 0FFE9H ;
  XKAltR = 0FFEAH ;
  XK1 = 031H ;
  XKt = 074H ;
  XRaiseVolume = 1008FF13H ;
  XLowerVolume = 1008FF11H ;
  XMuteAudio = 1008FF12H ;

TYPE
  Binding = RECORD
    sym: KeySym ;
    mods: CARDINAL ;
    keycode: CARDINAL ;
    action: Action ;
    arg: INTEGER ;
  END ;

VAR
  bindings: ARRAY [0..MaxBindings - 1] OF Binding ;
  count: CARDINAL ;
  numlock: CARDINAL ;

PROCEDURE Bind (sym: KeySym; mods: CARDINAL; action: Action; arg: INTEGER) ;
BEGIN
  bindings[count].sym := sym ;
  bindings[count].mods := mods ;
  bindings[count].action := action ;
  bindings[count].arg := arg ;
  INC (count)
END Bind ;

PROCEDURE Grab ;
VAR
  i: CARDINAL ;
  extra: ARRAY [0..3] OF CARDINAL ;
  j: CARDINAL ;
BEGIN
  numlock := mx_numlock_mask (dpy) ;
  extra[0] := 0 ;
  extra[1] := LockMask ;
  extra[2] := numlock ;
  extra[3] := numlock + LockMask ;
  IF XUngrabKey (dpy, AnyKey, AnyModifier, root) = 0 THEN END ;
  FOR i := 1 TO count DO
    WITH bindings[i - 1] DO
      keycode := ORD (XKeysymToKeycode (dpy, sym)) ;
      IF keycode # 0
      THEN
        (* the same shortcut must work with caps or num lock on *)
        FOR j := 0 TO 3 DO
          IF (j < 2) OR (numlock # 0)
          THEN
            IF XGrabKey (dpy, keycode, mods + extra[j], root, True,
                         GrabModeAsync, GrabModeAsync) = 0 THEN END
          END
        END
      END
    END
  END
END Grab ;

PROCEDURE Clean (state: CARDINAL) : CARDINAL ;
VAR
  relevant: CARDINAL ;
  s: BITSET ;
BEGIN
  relevant := ShiftMask + ControlMask + Mod1Mask + Mod4Mask ;
  s := BITSET (state) * BITSET (relevant) ;
  RETURN CARDINAL (s)
END Clean ;

PROCEDURE Lookup (code, state: CARDINAL; VAR arg: INTEGER) : Action ;
VAR
  i: CARDINAL ;
BEGIN
  FOR i := 1 TO count DO
    IF (bindings[i - 1].keycode = code) AND
       (bindings[i - 1].mods = Clean (state))
    THEN
      arg := bindings[i - 1].arg ;
      RETURN bindings[i - 1].action
    END
  END ;
  RETURN NoAction
END Lookup ;

PROCEDURE IsCycleModifier (keycode: CARDINAL) : BOOLEAN ;
BEGIN
  RETURN (keycode = ORD (XKeysymToKeycode (dpy, XKAltL))) OR
         (keycode = ORD (XKeysymToKeycode (dpy, XKAltR)))
END IsCycleModifier ;

PROCEDURE RunMixerCommand (command: ADDRESS) ;
VAR
  status: INTEGER ;
BEGIN
  status := system (command) ;
  IF status # 0
  THEN
    Log.Error2 ("keys", "volume command failed") ;
  END
END RunMixerCommand ;

PROCEDURE DoVolumeUp ;
BEGIN
  RunMixerCommand (ADR("amixer -q set Master 5%+"))
END DoVolumeUp ;

PROCEDURE DoVolumeDown ;
BEGIN
  RunMixerCommand (ADR("amixer -q set Master 5%-"))
END DoVolumeDown ;

PROCEDURE DoVolumeToggleMute ;
BEGIN
  RunMixerCommand (ADR ("amixer -q set Master toggle")) ;
END DoVolumeToggleMute ;

PROCEDURE RunVolumeAction (action: Action);
BEGIN
  CASE action OF
    VolumeUp:
      DoVolumeUp |
    VolumeDown:
      DoVolumeDown |
    VolumeToggleMute:
      DoVolumeToggleMute
  ELSE
  END
END RunVolumeAction;

PROCEDURE BindDefaults ;
VAR
  i: INTEGER ;
BEGIN
  count := 0 ;
  Bind (XKTab, Mod1Mask, CycleNext, 0) ;
  Bind (XKTab, Mod1Mask + ShiftMask, CyclePrev, 0) ;
  Bind (XKF4, Mod1Mask, CloseWindow, 0) ;
  Bind (XKF9, Mod1Mask, MinimizeWindow, 0) ;
  Bind (XKF10, Mod1Mask, MaximizeWindow, 0) ;
  Bind (XKF11, Mod1Mask, FullscreenWindow, 0) ;
  Bind (XKRight, ControlMask + Mod1Mask, DesktopNext, 0) ;
  Bind (XKLeft, ControlMask + Mod1Mask, DesktopPrev, 0) ;
  Bind (XKRight, ControlMask + Mod1Mask + ShiftMask, SendNext, 0) ;
  Bind (XKLeft, ControlMask + Mod1Mask + ShiftMask, SendPrev, 0) ;
  Bind (XRaiseVolume, 0, VolumeUp, 0) ;
  Bind (XLowerVolume, 0, VolumeDown, 0) ;
  Bind (XMuteAudio, 0, VolumeToggleMute, 0) ;

  FOR i := 0 TO 8 DO
    Bind (XK1 + VAL (KeySym, i), ControlMask + Mod1Mask, GotoDesktop, i)
  END ;
  Bind (XKF1, Mod1Mask, OpenLauncher, 0) ;
  Bind (XKF2, Mod1Mask, OpenTerminal, 0) ;
  Bind (XKt, ControlMask + Mod1Mask, OpenTerminal, 0) ;
  Bind (XKF3, Mod1Mask, OpenFiles, 0)
END BindDefaults ;

BEGIN
  numlock := 0 ;
  BindDefaults
END Keys.
