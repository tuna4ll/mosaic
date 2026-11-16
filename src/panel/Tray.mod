IMPLEMENTATION MODULE Tray ;

FROM Xlib IMPORT Window, Atom, None, CurrentTime, False, NoEventMask,
                 StructureNotifyMask, PropertyChangeMask, ClientMessage,
                 DestroyNotify, ReparentNotify, PropertyNotify, SelectionClear,
                 XA_CARDINAL, XInternAtom, XCreateSimpleWindow, XMapWindow,
                 XUnmapWindow, XReparentWindow, XMoveResizeWindow,
                 XSelectInput, XAddToSaveSet, XRemoveFromSaveSet,
                 XSetSelectionOwner, XGetSelectionOwner ;
FROM XGlue IMPORT Event, mx_send_client_message ;
FROM XServer IMPORT dpy, root, screen ;
IMPORT Gfx, Props, Str, Log ;

CONST
  MaxIcons = 32 ;
  Spacing = 2 ;
  RequestDock = 0 ;     (* _NET_SYSTEM_TRAY_OPCODE data[1] *)
  EmbeddedNotify = 0 ;  (* _XEMBED data[1] *)

VAR
  tray: Window ;
  selection, opcode, manager, xembed, xembedInfo: Atom ;
  icons: ARRAY [0..MaxIcons - 1] OF Window ;
  shown: ARRAY [0..MaxIcons - 1] OF BOOLEAN ;
  count, size, placedX, placedY, placedW: INTEGER ;
  active: BOOLEAN ;

PROCEDURE Find (w: Window) : INTEGER ;
VAR
  i: INTEGER ;
BEGIN
  FOR i := 0 TO count - 1 DO
    IF icons[i] = w THEN RETURN i END
  END ;
  RETURN -1
END Find ;

(* the XEMBED_MAPPED flag of _XEMBED_INFO; icons without it are shown *)
PROCEDURE Wants (w: Window) : BOOLEAN ;
VAR
  info: ARRAY [0..1] OF LONGCARD ;
BEGIN
  IF Props.GetCardinals (w, xembedInfo, xembedInfo, info) < 2
  THEN
    RETURN TRUE
  END ;
  RETURN (info[1] MOD 2) = 1
END Wants ;

PROCEDURE Arrange ;
VAR
  i, x: INTEGER ;
BEGIN
  x := 0 ;
  FOR i := 0 TO count - 1 DO
    IF shown[i]
    THEN
      IF XMoveResizeWindow (dpy, icons[i], x, 0, size, size) = 0 THEN END ;
      IF XMapWindow (dpy, icons[i]) = 0 THEN END ;
      INC (x, size + Spacing)
    ELSE
      IF XUnmapWindow (dpy, icons[i]) = 0 THEN END
    END
  END
END Arrange ;

PROCEDURE Width () : INTEGER ;
VAR
  i, n: INTEGER ;
BEGIN
  n := 0 ;
  FOR i := 0 TO count - 1 DO
    IF shown[i] THEN INC (n) END
  END ;
  IF n = 0 THEN RETURN 0 END ;
  RETURN n * size + (n - 1) * Spacing
END Width ;

PROCEDURE Place (x, y: INTEGER) ;
VAR
  w: INTEGER ;
BEGIN
  IF NOT active THEN RETURN END ;
  w := Width () ;
  IF (x = placedX) AND (y = placedY) AND (w = placedW) THEN RETURN END ;
  placedX := x ;
  placedY := y ;
  placedW := w ;
  IF w = 0
  THEN
    IF XUnmapWindow (dpy, tray) = 0 THEN END
  ELSE
    IF XMoveResizeWindow (dpy, tray, x, y, w, size) = 0 THEN END ;
    IF XMapWindow (dpy, tray) = 0 THEN END
  END
END Place ;

PROCEDURE Dock (w: Window) ;
BEGIN
  IF (w = None) OR (count = MaxIcons) OR (Find (w) >= 0)
  THEN
    RETURN
  END ;
  IF XSelectInput (dpy, w, StructureNotifyMask + PropertyChangeMask) = 0
  THEN
  END ;
  (* if the panel dies the server hands the icon back to the root *)
  IF XAddToSaveSet (dpy, w) = 0 THEN END ;
  IF XReparentWindow (dpy, w, tray, 0, 0) = 0 THEN END ;
  icons[count] := w ;
  shown[count] := Wants (w) ;
  INC (count) ;
  mx_send_client_message (dpy, w, w, xembed, NoEventMask, CurrentTime,
                          EmbeddedNotify, 0, VAL (LONGINT, tray), 0) ;
  Arrange
END Dock ;

PROCEDURE Remove (i: INTEGER) ;
BEGIN
  WHILE i < count - 1 DO
    icons[i] := icons[i + 1] ;
    shown[i] := shown[i + 1] ;
    INC (i)
  END ;
  DEC (count) ;
  Arrange
END Remove ;

PROCEDURE Handle (VAR e: Event) : BOOLEAN ;
VAR
  i: INTEGER ;
BEGIN
  IF NOT active THEN RETURN FALSE END ;
  CASE e.type OF
    ClientMessage:
      IF (e.window = tray) AND (e.atom = opcode)
      THEN
        IF e.data[1] = RequestDock
        THEN
          Dock (VAL (Window, e.data[2]))
        END ;
        RETURN TRUE
      END |
    DestroyNotify, ReparentNotify:
      i := Find (e.window) ;
      IF i >= 0
      THEN
        (* our own reparent into the tray also reports here *)
        IF (e.type = DestroyNotify) OR (e.subwindow # tray)
        THEN
          Remove (i)
        END ;
        RETURN TRUE
      END |
    PropertyNotify:
      i := Find (e.window) ;
      IF (i >= 0) AND (e.atom = xembedInfo)
      THEN
        shown[i] := Wants (e.window) ;
        Arrange ;
        RETURN TRUE
      END |
    SelectionClear:
      IF (e.window = tray) AND (e.atom = selection)
      THEN
        Log.Error ("another system tray took over") ;
        Release ;
        active := FALSE ;
        IF XUnmapWindow (dpy, tray) = 0 THEN END ;
        RETURN TRUE
      END
  ELSE
  END ;
  RETURN FALSE
END Handle ;

PROCEDURE Release ;
BEGIN
  WHILE count > 0 DO
    DEC (count) ;
    IF XSelectInput (dpy, icons[count], NoEventMask) = 0 THEN END ;
    IF XUnmapWindow (dpy, icons[count]) = 0 THEN END ;
    IF XReparentWindow (dpy, icons[count], root, 0, 0) = 0 THEN END ;
    IF XRemoveFromSaveSet (dpy, icons[count]) = 0 THEN END
  END
END Release ;

PROCEDURE Done ;
BEGIN
  IF active
  THEN
    Release ;
    IF XSetSelectionOwner (dpy, selection, None, CurrentTime) = 0 THEN END ;
    active := FALSE
  END
END Done ;

PROCEDURE Init (parent: Window; iconSize: INTEGER) ;
VAR
  name: ARRAY [0..31] OF CHAR ;
  number: ARRAY [0..7] OF CHAR ;
BEGIN
  size := iconSize ;
  count := 0 ;
  active := FALSE ;
  placedW := -1 ;
  name := "_NET_SYSTEM_TRAY_S" ;
  Str.IntToStr (screen, number) ;
  IF Str.Append (number, name) THEN END ;
  selection := XInternAtom (dpy, name, False) ;
  opcode := XInternAtom (dpy, "_NET_SYSTEM_TRAY_OPCODE", False) ;
  manager := XInternAtom (dpy, "MANAGER", False) ;
  xembed := XInternAtom (dpy, "_XEMBED", False) ;
  xembedInfo := XInternAtom (dpy, "_XEMBED_INFO", False) ;
  IF XGetSelectionOwner (dpy, selection) # None
  THEN
    Log.Error ("another system tray is running, not starting one") ;
    RETURN
  END ;
  (* icons with a ParentRelative background show the panel face *)
  tray := XCreateSimpleWindow (dpy, parent, 0, 0, 1, size, 0, 0,
                               Gfx.Pixel (Gfx.Face)) ;
  Props.SetCardinal (tray,
                     XInternAtom (dpy, "_NET_SYSTEM_TRAY_ORIENTATION", False),
                     XA_CARDINAL, 0) ;
  (* shortcut: CurrentTime instead of a server timestamp; fine unless two
     trays race for the selection *)
  IF XSetSelectionOwner (dpy, selection, tray, CurrentTime) = 0 THEN END ;
  IF XGetSelectionOwner (dpy, selection) # tray
  THEN
    Log.Error ("cannot become the system tray") ;
    RETURN
  END ;
  active := TRUE ;
  mx_send_client_message (dpy, root, root, manager, StructureNotifyMask,
                          CurrentTime, VAL (LONGINT, selection),
                          VAL (LONGINT, tray), 0, 0)
END Init ;

END Tray.
