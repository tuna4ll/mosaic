MODULE panel ;

(* mosaic-panel: launcher button, desktops, task list, system tray, clock
   and the session menu along the top edge of the screen *)

FROM Xlib IMPORT XMapWindow, XMoveResizeWindow, XSelectInput, Expose,
                 ButtonPress, ConfigureNotify, PropertyChangeMask,
                 StructureNotifyMask, XA_CARDINAL ;
FROM XGlue IMPORT Event, mx_set_input_hint ;
FROM XServer IMPORT dpy, root, width ;
FROM Posix IMPORT mx_watch_signals, mx_take_signal, mx_init_locale,
                  mx_format_time ;
FROM libc IMPORT exit, time ;
FROM Gfx IMPORT Surface ;
FROM Spawn IMPORT Args ;
IMPORT XServer, Atoms, Config, Gfx, Win, Menu, Dialog, Spawn, Props, Str,
       Tasks, Tray, Log ;

CONST
  Gap = 4 ;
  MaxTaskWidth = 200 ;
  MinTaskWidth = 40 ;
  MoreWidth = 44 ;
  ZoneLimit = Tasks.MaxTasks + Tasks.MaxDesktops + 5 ;
  TrayPad = 3 ;

TYPE
  ZoneKind = (LauncherZone, DesktopZone, TaskZone, MoreZone, TrayZone,
              ClockZone, SessionZone) ;
  Zone = RECORD
    kind: ZoneKind ;
    x, w, index: INTEGER ;
  END ;

VAR
  panel: Win.Handle ;
  height: INTEGER ;
  zones: ARRAY [0..ZoneLimit - 1] OF Zone ;
  zoneCount: INTEGER ;
  clockText: ARRAY [0..63] OF CHAR ;
  clockFormat: ARRAY [0..63] OF CHAR ;
  atBottom: BOOLEAN ;
  pressed: INTEGER ;
  running: BOOLEAN ;
  event: Event ;
  position: ARRAY [0..15] OF CHAR ;

PROCEDURE AddZone (kind: ZoneKind; x, w, index: INTEGER) ;
BEGIN
  IF zoneCount < ZoneLimit
  THEN
    zones[zoneCount].kind := kind ;
    zones[zoneCount].x := x ;
    zones[zoneCount].w := w ;
    zones[zoneCount].index := index ;
    INC (zoneCount)
  END
END AddZone ;

PROCEDURE UpdateClock () : BOOLEAN ;
VAR
  text: ARRAY [0..63] OF CHAR ;
BEGIN
  IF mx_format_time (time (NIL), clockFormat, text, HIGH (text)) = 0
  THEN
    text := "--:--"
  END ;
  IF Str.Equal (text, clockText)
  THEN
    RETURN FALSE
  END ;
  clockText := text ;
  RETURN TRUE
END UpdateClock ;

PROCEDURE Visible (VAR t: Tasks.Task) : BOOLEAN ;
BEGIN
  RETURN (NOT t.skip) AND Tasks.OnDesktop (t, Tasks.current)
END Visible ;

PROCEDURE Layout ;
VAR
  x, right, w, i, n, taskWidth, hidden: INTEGER ;
BEGIN
  zoneCount := 0 ;
  x := Gap ;
  w := Gfx.TextWidth ("Mosaic", TRUE) + 30 ;
  AddZone (LauncherZone, x, w, 0) ;
  INC (x, w + Gap + 2) ;
  FOR i := 0 TO Tasks.desktops - 1 DO
    w := Gfx.TextWidth (Tasks.names[i], FALSE) + 14 ;
    IF w < 24 THEN w := 24 END ;
    AddZone (DesktopZone, x, w, i) ;
    INC (x, w)
  END ;
  INC (x, Gap + 4) ;
  right := width - Gap ;
  w := Gfx.TextWidth ("Session", FALSE) + 20 ;
  DEC (right, w) ;
  AddZone (SessionZone, right, w, 0) ;
  w := Gfx.TextWidth (clockText, FALSE) + 20 ;
  DEC (right, w + Gap) ;
  AddZone (ClockZone, right, w, 0) ;
  w := Tray.Width () ;
  IF w > 0
  THEN
    INC (w, 2 * TrayPad) ;
    DEC (right, w + Gap) ;
    AddZone (TrayZone, right, w, 0)
  END ;
  (* the icons sit in the sunken well the zone draws *)
  Tray.Place (right + TrayPad, 5) ;
  DEC (right, Gap + 4) ;
  n := 0 ;
  FOR i := 0 TO Tasks.count - 1 DO
    IF Visible (Tasks.tasks[i]) THEN INC (n) END
  END ;
  IF n = 0
  THEN
    RETURN
  END ;
  taskWidth := (right - x) DIV n ;
  IF taskWidth > MaxTaskWidth THEN taskWidth := MaxTaskWidth END ;
  IF taskWidth < MinTaskWidth
  THEN
    (* too many: the last slot opens a menu with the rest *)
    taskWidth := MinTaskWidth ;
    DEC (right, MoreWidth)
  END ;
  hidden := 0 ;
  FOR i := 0 TO Tasks.count - 1 DO
    IF Visible (Tasks.tasks[i])
    THEN
      IF x + taskWidth <= right
      THEN
        AddZone (TaskZone, x, taskWidth - 2, i) ;
        INC (x, taskWidth)
      ELSE
        INC (hidden)
      END
    END
  END ;
  IF hidden > 0
  THEN
    AddZone (MoreZone, right, MoreWidth - 2, hidden)
  END
END Layout ;

(* four tiles in two shades: the mosaic mark *)
PROCEDURE DrawMark (s: Surface; x, y: INTEGER) ;
BEGIN
  Gfx.Fill (s, x, y, 5, 5, Gfx.Accent) ;
  Gfx.Fill (s, x + 6, y, 5, 5, Gfx.Alert) ;
  Gfx.Fill (s, x, y + 6, 5, 5, Gfx.Alert) ;
  Gfx.Fill (s, x + 6, y + 6, 5, 5, Gfx.Accent)
END DrawMark ;

PROCEDURE DrawZone (s: Surface; VAR z: Zone; down: BOOLEAN) ;
VAR
  y, h, ty, tw: INTEGER ;
  t: Tasks.Task ;
  label: ARRAY [0..259] OF CHAR ;
  text: ARRAY [0..15] OF CHAR ;
  ink: Gfx.Color ;
BEGIN
  y := 3 ;
  h := height - 6 ;
  ty := (height - Gfx.lineHeight) DIV 2 ;
  CASE z.kind OF
    LauncherZone:
      Gfx.Button (s, z.x, y, z.w, h, down) ;
      DrawMark (s, z.x + 7, (height - 11) DIV 2) ;
      Gfx.Text (s, z.x + 23, ty, "Mosaic", Gfx.Ink, TRUE) |
    DesktopZone:
      IF z.index = Tasks.current
      THEN
        Gfx.Outline (s, z.x, y, z.w, h, Gfx.Dark) ;
        Gfx.Fill (s, z.x + 1, y + 1, z.w - 2, h - 2, Gfx.Accent) ;
        ink := Gfx.AccentInk
      ELSE
        Gfx.Button (s, z.x, y, z.w, h, down) ;
        ink := Gfx.InkDim ;
        IF Tasks.Occupied (z.index) THEN ink := Gfx.Ink END
      END ;
      tw := Gfx.TextWidth (Tasks.names[z.index], FALSE) ;
      Gfx.Text (s, z.x + (z.w - tw) DIV 2, ty, Tasks.names[z.index], ink,
                z.index = Tasks.current) |
    TaskZone:
      t := Tasks.tasks[z.index] ;
      IF t.minimized
      THEN
        label := "[" ;
        IF Str.Append (t.title, label) AND Str.Append ("]", label) THEN END
      ELSE
        IF Str.Assign (t.title, label) THEN END
      END ;
      IF t.window = Tasks.active
      THEN
        Gfx.Outline (s, z.x, y, z.w, h, Gfx.Dark) ;
        Gfx.Fill (s, z.x + 1, y + 1, z.w - 2, h - 2, Gfx.Accent) ;
        Gfx.Bevel (s, z.x + 1, y + 1, z.w - 2, h - 2, FALSE) ;
        Gfx.TextClip (s, z.x + 8, ty, z.w - 14, label, Gfx.AccentInk, TRUE)
      ELSE
        IF t.urgent
        THEN
          Gfx.Outline (s, z.x, y, z.w, h, Gfx.Dark) ;
          Gfx.Fill (s, z.x + 1, y + 1, z.w - 2, h - 2, Gfx.Alert)
        ELSE
          Gfx.Button (s, z.x, y, z.w, h, down)
        END ;
        ink := Gfx.Ink ;
        IF t.minimized THEN ink := Gfx.InkDim END ;
        Gfx.TextClip (s, z.x + 8, ty, z.w - 14, label, ink, FALSE)
      END |
    MoreZone:
      Gfx.Button (s, z.x, y, z.w, h, down) ;
      Str.IntToStr (z.index, label) ;
      IF Str.Assign ("+", text) AND Str.Append (label, text) THEN END ;
      tw := Gfx.TextWidth (text, FALSE) ;
      Gfx.Text (s, z.x + (z.w - tw) DIV 2, ty, text, Gfx.Ink, FALSE) |
    TrayZone:
      Gfx.Bevel (s, z.x, y, z.w, h, FALSE) |
    ClockZone:
      Gfx.Bevel (s, z.x, y, z.w, h, FALSE) ;
      Gfx.Text (s, z.x + 10, ty, clockText, Gfx.Ink, FALSE) |
    SessionZone:
      Gfx.Button (s, z.x, y, z.w, h, down) ;
      Gfx.Text (s, z.x + 10, ty, "Session", Gfx.Ink, FALSE)
  END
END DrawZone ;

PROCEDURE Draw ;
VAR
  s: Surface ;
  i: INTEGER ;
BEGIN
  Layout ;
  s := panel^.surface ;
  Gfx.Fill (s, 0, 0, panel^.width, height, Gfx.Face) ;
  (* the dark edge faces the windows *)
  IF atBottom
  THEN
    Gfx.Line (s, 0, 0, panel^.width - 1, 0, Gfx.Dark) ;
    Gfx.Line (s, 0, 1, panel^.width - 1, 1, Gfx.Light) ;
    Gfx.Line (s, 0, height - 1, panel^.width - 1, height - 1, Gfx.Shadow)
  ELSE
    Gfx.Line (s, 0, 0, panel^.width - 1, 0, Gfx.Light) ;
    Gfx.Line (s, 0, height - 2, panel^.width - 1, height - 2, Gfx.Shadow) ;
    Gfx.Line (s, 0, height - 1, panel^.width - 1, height - 1, Gfx.Dark)
  END ;
  FOR i := 0 TO zoneCount - 1 DO
    DrawZone (s, zones[i], i = pressed)
  END ;
  Gfx.Flush (s)
END Draw ;

PROCEDURE ZoneAt (x: INTEGER) : INTEGER ;
VAR
  i: INTEGER ;
BEGIN
  FOR i := 0 TO zoneCount - 1 DO
    IF (x >= zones[i].x) AND (x < zones[i].x + zones[i].w)
    THEN
      RETURN i
    END
  END ;
  RETURN -1
END ZoneAt ;

(* menus open away from the screen edge the panel sits on *)
PROCEDURE OpenMenu (VAR m: Menu.Menu; x: INTEGER; VAR e: Event) : INTEGER ;
BEGIN
  IF atBottom
  THEN
    RETURN Menu.PopupAbove (m, x, XServer.height - height, e.time, Dispatch)
  END ;
  RETURN Menu.Popup (m, x, height, e.time, Dispatch)
END OpenMenu ;

PROCEDURE Launch (name: ARRAY OF CHAR) ;
VAR
  a: Args ;
  path: ARRAY [0..4095] OF CHAR ;
BEGIN
  Spawn.Clear (a) ;
  IF Str.Equal (name, "terminal")
  THEN
    IF NOT Spawn.Terminal (path)
    THEN
      Dialog.Message (panel^.window, "Terminal",
                      "No terminal emulator was found. Set terminal in ~/.config/mosaic/mosaicrc.",
                      Dispatch) ;
      RETURN
    END
  ELSE
    Spawn.Sibling (name, path)
  END ;
  IF Spawn.Add (a, path) AND (Spawn.Run (a, "") > 0) THEN END
END Launch ;

PROCEDURE SessionMenu (x: INTEGER; VAR e: Event) ;
VAR
  m: Menu.Menu ;
BEGIN
  Menu.Clear (m) ;
  Menu.Add (m, "Applications…", TRUE) ;
  Menu.Add (m, "Terminal", TRUE) ;
  Menu.Add (m, "Files", TRUE) ;
  Menu.AddSeparator (m) ;
  Menu.Add (m, "Log Out…", TRUE) ;
  CASE OpenMenu (m, x, e) OF
    0: Launch ("mosaic-launcher") |
    1: Launch ("terminal") |
    2: Launch ("mosaic-files") |
    4: IF Dialog.Confirm (panel^.window, "Log Out",
                          "End the Mosaic session? Running programs lose their window manager.",
                          "Log Out", Dispatch)
       THEN
         Tasks.Logout
       END
  ELSE
  END
END SessionMenu ;

PROCEDURE TaskMenu (VAR z: Zone; VAR e: Event) ;
VAR
  m: Menu.Menu ;
  t: Tasks.Task ;
  i, choice, moveFirst: INTEGER ;
  label: ARRAY [0..63] OF CHAR ;
BEGIN
  t := Tasks.tasks[z.index] ;
  Menu.Clear (m) ;
  IF t.minimized
  THEN
    Menu.Add (m, "Restore", TRUE)
  ELSE
    Menu.Add (m, "Minimize", TRUE)
  END ;
  Menu.Add (m, "Maximize", TRUE) ;
  Menu.AddSeparator (m) ;
  moveFirst := 3 ;
  FOR i := 0 TO Tasks.desktops - 1 DO
    label := "Move to " ;
    IF Str.Append (Tasks.names[i], label) THEN END ;
    Menu.AddChecked (m, label, t.desktop = i)
  END ;
  Menu.AddSeparator (m) ;
  Menu.Add (m, "Close", TRUE) ;
  choice := OpenMenu (m, z.x, e) ;
  IF choice = 0
  THEN
    IF t.minimized THEN Tasks.Activate (t.window) ELSE Tasks.Minimize (t.window) END
  ELSIF choice = 1
  THEN
    Tasks.ToggleMaximize (t.window)
  ELSIF (choice >= moveFirst) AND (choice < moveFirst + Tasks.desktops)
  THEN
    Tasks.SendTo (t.window, choice - moveFirst)
  ELSIF choice = moveFirst + Tasks.desktops + 1
  THEN
    Tasks.Close (t.window)
  END
END TaskMenu ;

(* tasks that did not fit on the panel, as a menu *)
PROCEDURE MoreMenu (VAR z: Zone; VAR e: Event) ;
VAR
  m: Menu.Menu ;
  index: ARRAY [0..Menu.MaxItems - 1] OF INTEGER ;
  i, shown, choice: INTEGER ;
BEGIN
  Menu.Clear (m) ;
  shown := 0 ;
  FOR i := 0 TO Tasks.count - 1 DO
    IF Visible (Tasks.tasks[i]) AND NOT OnPanel (i) AND
       (shown < Menu.MaxItems)
    THEN
      Menu.AddChecked (m, Tasks.tasks[i].title,
                       Tasks.tasks[i].window = Tasks.active) ;
      index[shown] := i ;
      INC (shown)
    END
  END ;
  choice := OpenMenu (m, z.x, e) ;
  IF choice >= 0
  THEN
    Tasks.Activate (Tasks.tasks[index[choice]].window)
  END
END MoreMenu ;

PROCEDURE OnPanel (task: INTEGER) : BOOLEAN ;
VAR
  i: INTEGER ;
BEGIN
  FOR i := 0 TO zoneCount - 1 DO
    IF (zones[i].kind = TaskZone) AND (zones[i].index = task)
    THEN
      RETURN TRUE
    END
  END ;
  RETURN FALSE
END OnPanel ;

PROCEDURE Press (VAR e: Event) ;
VAR
  i: INTEGER ;
  t: Tasks.Task ;
BEGIN
  i := ZoneAt (e.x) ;
  IF i < 0
  THEN
    RETURN
  END ;
  pressed := i ;
  Draw ;
  CASE zones[i].kind OF
    LauncherZone:
      IF e.detail = 1 THEN Launch ("mosaic-launcher") END |
    DesktopZone:
      Tasks.SwitchTo (zones[i].index) |
    TaskZone:
      t := Tasks.tasks[zones[i].index] ;
      IF e.detail = 3
      THEN
        TaskMenu (zones[i], e)
      ELSIF e.detail = 1
      THEN
        (* clicking the active task puts it away *)
        IF (t.window = Tasks.active) AND NOT t.minimized
        THEN
          Tasks.Minimize (t.window)
        ELSE
          Tasks.Activate (t.window)
        END
      END |
    MoreZone:
      MoreMenu (zones[i], e) |
    SessionZone:
      SessionMenu (zones[i].x, e)
  ELSE
  END ;
  pressed := -1 ;
  Draw
END Press ;

PROCEDURE Dispatch (VAR e: Event) ;
BEGIN
  IF e.window = panel^.window
  THEN
    CASE e.type OF
      Expose:
        IF e.detail = 0 THEN Draw END |
      ConfigureNotify:
        IF Win.Configured (panel, e) THEN Draw END |
      ButtonPress:
        Press (e)
    ELSE
    END
  ELSIF (e.window = root) AND (e.type = ConfigureNotify)
  THEN
    (* the screen changed size; a bottom bar follows the new height *)
    width := e.width ;
    XServer.height := e.height ;
    Place
  ELSIF Tray.Handle (e) OR Tasks.Changed (e)
  THEN
    Draw
  END
END Dispatch ;

PROCEDURE Place ;
VAR
  strut: ARRAY [0..11] OF LONGCARD ;
  i: CARDINAL ;
BEGIN
  FOR i := 0 TO 11 DO strut[i] := 0 END ;
  IF atBottom
  THEN
    IF XMoveResizeWindow (dpy, panel^.window, 0, XServer.height - height,
                          width, height) = 0 THEN END ;
    strut[3] := height ;
    strut[11] := width - 1
  ELSE
    IF XMoveResizeWindow (dpy, panel^.window, 0, 0, width, height) = 0 THEN END ;
    strut[2] := height ;
    strut[9] := width - 1
  END ;
  Props.SetCardinals (panel^.window, Atoms.NetWmStrut, XA_CARDINAL, strut, 4) ;
  Props.SetCardinals (panel^.window, Atoms.NetWmStrutPartial, XA_CARDINAL,
                      strut, 12)
END Place ;

(* milliseconds until the clock needs to change *)
PROCEDURE UntilNextMinute () : INTEGER ;
BEGIN
  RETURN (60 - VAL (INTEGER, time (NIL) MOD 60)) * 1000
END UntilNextMinute ;

BEGIN
  Log.SetProgram ("mosaic-panel") ;
  mx_init_locale ;
  mx_watch_signals ;
  IF NOT XServer.Open ()
  THEN
    exit (1)
  END ;
  Config.Load ;
  Atoms.Init ;
  IF NOT Gfx.Init ()
  THEN
    XServer.Close ;
    exit (1)
  END ;
  Config.Get ("clock.format", "%a %d %b  %H:%M", clockFormat) ;
  Config.Get ("panel.position", "top", position) ;
  atBottom := Str.Equal (position, "bottom") ;
  IF NOT (atBottom OR Str.Equal (position, "top"))
  THEN
    Log.Error2 ("unknown panel.position, using top", position)
  END ;
  clockText[0] := 0C ;
  IF UpdateClock () THEN END ;
  pressed := -1 ;
  height := Gfx.lineHeight + 14 ;
  panel := Win.Create ("Mosaic Panel", "mosaic-panel", width, height, 0, 0) ;
  Win.SetType (panel, Atoms.NetWmWindowTypeDock) ;
  mx_set_input_hint (dpy, panel^.window, 0) ;
  Props.SetCardinal (panel^.window, Atoms.NetWmDesktop, XA_CARDINAL,
                     0FFFFFFFFH) ;
  Place ;
  Tray.Init (panel^.window, height - 10) ;
  (* select before reading so no change slips between the two *)
  IF XSelectInput (dpy, root, PropertyChangeMask + StructureNotifyMask) = 0
  THEN
  END ;
  Tasks.Init (panel^.window) ;
  IF XMapWindow (dpy, panel^.window) = 0 THEN END ;
  running := TRUE ;
  WHILE running DO
    IF XServer.WaitEvent (UntilNextMinute ()) AND XServer.NextEvent (event)
    THEN
      Dispatch (event)
    END ;
    IF UpdateClock ()
    THEN
      Draw
    END ;
    WHILE Spawn.Reap () > 0 DO END ;
    IF mx_take_signal () # 0
    THEN
      running := FALSE
    END
  END ;
  Tray.Done ;
  Win.Destroy (panel) ;
  Gfx.Done ;
  XServer.Close ;
  exit (0)
END panel.
