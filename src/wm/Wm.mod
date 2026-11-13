IMPLEMENTATION MODULE Wm ;

FROM SYSTEM IMPORT ADDRESS, TSIZE ;
FROM Xlib IMPORT Window, Atom, Time, None, CurrentTime, False,
                 XSelectInput, XMapWindow, XUnmapWindow, XRestackWindows,
                 XSetInputFocus, XGrabButton, XUngrabButton, XAllowEvents,
                 XGetTransientForHint, XGetWMProtocols, XFree, XKillClient,
                 XQueryTree, XGrabServer, XUngrabServer, XSync,
                 XGrabPointer, XUngrabPointer, XGrabKeyboard, XUngrabKeyboard,
                 XQueryKeymap, XCreateFontCursor, XDefineCursor, XFreeCursor,
                 Cursor, Mod1Mask, LockMask, ButtonMotionMask,
                 ButtonReleaseMask, PointerMotionMask, GrabSuccess, True,
                 MapRequest, UnmapNotify, DestroyNotify, ConfigureRequest,
                 PropertyNotify, ClientMessage, ButtonPress, Expose,
                 KeyPress, KeyRelease, ButtonRelease, MotionNotify,
                 ConfigureNotify, XQueryPointer, Button1Mask,
                 SubstructureRedirectMask, SubstructureNotifyMask,
                 PropertyChangeMask, StructureNotifyMask, ButtonPressMask,
                 FocusChangeMask,
                 AnyButton, AnyModifier, GrabModeSync, GrabModeAsync,
                 ReplayPointer, PointerRoot, RevertToPointerRoot, CWX, CWY,
                 CWWidth,
                 CWHeight, CWStackMode, Above, IsViewable, NormalState,
                 IconicState, WithdrawnState, XA_ATOM, XA_CARDINAL,
                 XA_WM_NAME, XA_WM_HINTS, XA_WM_NORMAL_HINTS,
                 XA_WM_TRANSIENT_FOR ;
FROM XGlue IMPORT Event, mx_become_wm, mx_window_attrs, mx_size_hints,
                  mx_wm_hints, mx_configure_window, mx_send_client_message,
                  mx_compress_motion, mx_numlock_mask ;
FROM XServer IMPORT dpy, root, width, height ;
FROM Clients IMPORT Client, Kind, AllDesktops ;
FROM Storage IMPORT ALLOCATE, DEALLOCATE ;
FROM Frames IMPORT Part ;
FROM Keys IMPORT Action ;
IMPORT Clients, Frames, Keys, Ewmh, Atoms, Props, Config, Str, Desktop, Log ;

CONST
  RootMask = SubstructureRedirectMask + SubstructureNotifyMask +
             PropertyChangeMask + StructureNotifyMask + ButtonPressMask ;
  ClientMask = PropertyChangeMask + FocusChangeMask ;
  MotifDecorations = 2 ;
  CascadeStep = 24 ;
  DoubleClickTime = 400 ;
  DragMask = ButtonMotionMask + ButtonReleaseMask + PointerMotionMask ;
  StateRemove = 0 ;
  StateAdd = 1 ;
  StateToggle = 2 ;

TYPE
  Longs = POINTER TO ARRAY [0..65535] OF LONGCARD ;
  DragMode = (DragNone, DragMove, DragResize, DragBox) ;

VAR
  focused: Client ;
  currentDesktop, desktopCount: INTEGER ;
  workX, workY, workWidth, workHeight: INTEGER ;
  cascade: INTEGER ;
  lastTime: Time ;
  scanning: BOOLEAN ;
  cycling: BOOLEAN ;
  drag: DragMode ;
  dragClient: Client ;
  dragPart: Part ;
  dragX, dragY, origX, origY, origWidth, origHeight: INTEGER ;
  titleClickClient: Client ;
  titleClickTime: Time ;
  hoverFrame: Client ;
  hoverPart: Part ;
  cursors: ARRAY Part OF Cursor ;

PROCEDURE HasBit (mask: LONGCARD; bit: LONGCARD) : BOOLEAN ;
BEGIN
  RETURN (mask DIV bit) MOD 2 = 1
END HasBit ;

PROCEDURE Reparented (c: Client) : BOOLEAN ;
BEGIN
  RETURN c^.frame # c^.window
END Reparented ;

PROCEDURE Visible (c: Client) : BOOLEAN ;
BEGIN
  RETURN (NOT c^.minimized) AND
         ((c^.desktop = currentDesktop) OR (c^.desktop = AllDesktops))
END Visible ;

PROCEDURE SetWmState (c: Client; state: LONGCARD) ;
VAR
  v: ARRAY [0..1] OF LONGCARD ;
BEGIN
  v[0] := state ;
  v[1] := None ;
  Props.SetCardinals (c^.window, Atoms.WmState, Atoms.WmState, v, 2)
END SetWmState ;

(* map or unmap the frame to match desktop and minimized state *)
PROCEDURE Show (c: Client) ;
BEGIN
  IF NOT Reparented (c)
  THEN
    RETURN
  END ;
  IF Visible (c)
  THEN
    IF XMapWindow (dpy, c^.frame) = 0 THEN END
  ELSE
    IF XUnmapWindow (dpy, c^.frame) = 0 THEN END
  END
END Show ;

PROCEDURE Put (list: Longs; VAR n: CARDINAL; c: Client) ;
BEGIN
  list^[n] := c^.frame ;
  INC (n)
END Put ;

PROCEDURE Restack ;
VAR
  list: Longs ;
  c: Client ;
  n, size: CARDINAL ;
BEGIN
  IF Clients.count = 0
  THEN
    RETURN
  END ;
  size := Clients.count * TSIZE (LONGCARD) ;
  ALLOCATE (list, size) ;
  n := 0 ;
  IF (focused # NIL) AND focused^.fullscreen
  THEN
    Put (list, n, focused)
  END ;
  c := Clients.stackTop ;
  WHILE c # NIL DO
    IF c^.kind = Dock THEN Put (list, n, c) END ;
    c := c^.stackNext
  END ;
  c := Clients.stackTop ;
  WHILE c # NIL DO
    IF ((c^.kind = Normal) OR (c^.kind = Dialog)) AND
       NOT ((c = focused) AND c^.fullscreen)
    THEN
      Put (list, n, c)
    END ;
    c := c^.stackNext
  END ;
  c := Clients.stackTop ;
  WHILE c # NIL DO
    IF c^.kind = DesktopKind THEN Put (list, n, c) END ;
    c := c^.stackNext
  END ;
  IF XRestackWindows (dpy, list, n) = 0 THEN END ;
  DEALLOCATE (list, size) ;
  Ewmh.UpdateClientList
END Restack ;

(* raise c and keep its transients above it *)
PROCEDURE RaiseClient (c: Client) ;
VAR
  t: Client ;
BEGIN
  Clients.Raise (c) ;
  t := Clients.first ;
  WHILE t # NIL DO
    IF (t^.transientFor = c^.window) AND (t # c)
    THEN
      Clients.Raise (t)
    END ;
    t := t^.next
  END ;
  Restack
END RaiseClient ;

PROCEDURE GrabClicks (c: Client) ;
BEGIN
  IF XGrabButton (dpy, AnyButton, AnyModifier, c^.window, False,
                  ButtonPressMask, GrabModeSync, GrabModeAsync,
                  None, None) = 0 THEN END
END GrabClicks ;

PROCEDURE UngrabClicks (c: Client) ;
BEGIN
  IF XUngrabButton (dpy, AnyButton, AnyModifier, c^.window) = 0 THEN END
END UngrabClicks ;

PROCEDURE SendProtocol (c: Client; protocol: Atom) ;
BEGIN
  mx_send_client_message (dpy, c^.window, c^.window, Atoms.WmProtocols, 0,
                          protocol, lastTime, 0, 0, 0)
END SendProtocol ;

PROCEDURE Focus (c: Client) ;
VAR
  old: Client ;
BEGIN
  IF (c # NIL) AND ((NOT Visible (c)) OR (c^.kind = Dock) OR
                    (c^.kind = DesktopKind))
  THEN
    c := NIL
  END ;
  old := focused ;
  focused := c ;
  IF (old # NIL) AND (old # c)
  THEN
    Frames.Draw (old, FALSE) ;
    GrabClicks (old)
  END ;
  IF c = NIL
  THEN
    IF XSetInputFocus (dpy, Ewmh.checkWindow, RevertToPointerRoot,
                       lastTime) = 0 THEN END ;
    Ewmh.SetActive (None) ;
    RETURN
  END ;
  IF NOT cycling
  THEN
    Clients.Touch (c)
  END ;
  IF c^.urgent
  THEN
    c^.urgent := FALSE ;
    Ewmh.SetClientState (c)
  END ;
  Frames.Draw (c, TRUE) ;
  UngrabClicks (c) ;
  IF c^.acceptsInput
  THEN
    IF XSetInputFocus (dpy, c^.window, RevertToPointerRoot,
                       lastTime) = 0 THEN END
  END ;
  IF c^.takeFocus
  THEN
    SendProtocol (c, Atoms.WmTakeFocus)
  END ;
  Ewmh.SetActive (c^.window)
END Focus ;

(* focus the most recently used window still visible here *)
PROCEDURE FocusFallback ;
VAR
  c: Client ;
BEGIN
  c := Clients.focusFirst ;
  WHILE (c # NIL) AND
        ((NOT Visible (c)) OR (c^.kind = Dock) OR (c^.kind = DesktopKind)) DO
    c := c^.focusNext
  END ;
  Focus (c)
END FocusFallback ;

PROCEDURE Close (c: Client) ;
BEGIN
  IF c^.deleteWindow
  THEN
    SendProtocol (c, Atoms.WmDeleteWindow)
  ELSE
    IF XKillClient (dpy, c^.window) = 0 THEN END
  END
END Close ;

PROCEDURE ReadTitle (c: Client) ;
BEGIN
  IF NOT Props.GetTitle (c^.window, c^.title)
  THEN
    c^.title[0] := 0C
  END
END ReadTitle ;

PROCEDURE ReadSizeHints (c: Client) ;
VAR
  h: ARRAY [0..8] OF INTEGER ;
BEGIN
  IF mx_size_hints (dpy, c^.window, h) # 0 THEN END ;
  c^.minWidth := h[0] ; c^.minHeight := h[1] ;
  c^.maxWidth := h[2] ; c^.maxHeight := h[3] ;
  c^.incWidth := h[4] ; c^.incHeight := h[5] ;
  c^.baseWidth := h[6] ; c^.baseHeight := h[7]
END ReadSizeHints ;

PROCEDURE UserPositioned (c: Client) : BOOLEAN ;
VAR
  h: ARRAY [0..8] OF INTEGER ;
BEGIN
  IF mx_size_hints (dpy, c^.window, h) = 0
  THEN
    RETURN FALSE
  END ;
  RETURN h[8] # 0
END UserPositioned ;

PROCEDURE ReadWmHints (c: Client) : INTEGER ;
VAR
  input, urgent, state: INTEGER ;
BEGIN
  IF mx_wm_hints (dpy, c^.window, input, urgent, state) # 0 THEN END ;
  c^.acceptsInput := input # 0 ;
  c^.urgent := (urgent # 0) AND (c # focused) ;
  RETURN state
END ReadWmHints ;

PROCEDURE ReadProtocols (c: Client) ;
VAR
  list: ADDRESS ;
  atoms: Longs ;
  n, i: INTEGER ;
BEGIN
  c^.deleteWindow := FALSE ;
  c^.takeFocus := FALSE ;
  IF XGetWMProtocols (dpy, c^.window, list, n) = 0
  THEN
    RETURN
  END ;
  atoms := list ;
  FOR i := 0 TO n - 1 DO
    IF atoms^[i] = Atoms.WmDeleteWindow THEN c^.deleteWindow := TRUE END ;
    IF atoms^[i] = Atoms.WmTakeFocus THEN c^.takeFocus := TRUE END
  END ;
  IF XFree (list) = 0 THEN END
END ReadProtocols ;

PROCEDURE ReadType (c: Client) ;
VAR
  types: ARRAY [0..15] OF LONGCARD ;
  n, i: CARDINAL ;
  t: LONGCARD ;
BEGIN
  n := Props.GetCardinals (c^.window, Atoms.NetWmWindowType, XA_ATOM, types) ;
  FOR i := 1 TO n DO
    t := types[i - 1] ;
    IF t = Atoms.NetWmWindowTypeDock
    THEN
      c^.kind := Dock ; RETURN
    ELSIF t = Atoms.NetWmWindowTypeDesktop
    THEN
      c^.kind := DesktopKind ; RETURN
    ELSIF t = Atoms.NetWmWindowTypeDialog
    THEN
      c^.kind := Dialog ; RETURN
    ELSIF t = Atoms.NetWmWindowTypeSplash
    THEN
      c^.decorated := FALSE ; RETURN
    ELSIF (t = Atoms.NetWmWindowTypeNormal) OR
          (t = Atoms.NetWmWindowTypeUtility)
    THEN
      RETURN
    END
  END ;
  IF c^.transientFor # None
  THEN
    c^.kind := Dialog
  END
END ReadType ;

PROCEDURE ReadMotifHints (c: Client) ;
VAR
  h: ARRAY [0..4] OF LONGCARD ;
BEGIN
  IF (Props.GetCardinals (c^.window, Atoms.MotifWmHints, Atoms.MotifWmHints,
                          h) >= 3) AND HasBit (h[0], MotifDecorations) AND
     (h[2] = 0)
  THEN
    c^.decorated := FALSE
  END
END ReadMotifHints ;

PROCEDURE ReadStrut (c: Client) ;
VAR
  s: ARRAY [0..11] OF LONGCARD ;
  i: CARDINAL ;
BEGIN
  IF (Props.GetCardinals (c^.window, Atoms.NetWmStrutPartial, XA_CARDINAL,
                          s) < 4) AND
     (Props.GetCardinals (c^.window, Atoms.NetWmStrut, XA_CARDINAL, s) < 4)
  THEN
    s[0] := 0 ; s[1] := 0 ; s[2] := 0 ; s[3] := 0
  END ;
  FOR i := 0 TO 3 DO
    (* refuse struts that would swallow the screen *)
    IF s[i] > VAL (LONGCARD, height DIV 2)
    THEN
      c^.strut[i] := 0
    ELSE
      c^.strut[i] := VAL (INTEGER, s[i])
    END
  END
END ReadStrut ;

PROCEDURE UpdateWorkarea ;
VAR
  c: Client ;
  left, right, top, bottom: INTEGER ;
BEGIN
  left := 0 ; right := 0 ; top := 0 ; bottom := 0 ;
  c := Clients.first ;
  WHILE c # NIL DO
    IF c^.kind = Dock
    THEN
      IF c^.strut[0] > left THEN left := c^.strut[0] END ;
      IF c^.strut[1] > right THEN right := c^.strut[1] END ;
      IF c^.strut[2] > top THEN top := c^.strut[2] END ;
      IF c^.strut[3] > bottom THEN bottom := c^.strut[3] END
    END ;
    c := c^.next
  END ;
  IF (left = workX) AND (top = workY) AND
     (width - left - right = workWidth) AND (height - top - bottom = workHeight)
  THEN
    RETURN
  END ;
  workX := left ;
  workY := top ;
  workWidth := width - left - right ;
  workHeight := height - top - bottom ;
  Ewmh.SetWorkarea (desktopCount, workX, workY, workWidth, workHeight) ;
  (* keep windows clear of a panel that appeared or changed size *)
  c := Clients.first ;
  WHILE c # NIL DO
    IF Reparented (c) AND NOT c^.fullscreen
    THEN
      IF c^.maximized
      THEN
        MaximizedGeometry (c)
      ELSE
        Fit (c)
      END ;
      Frames.Apply (c) ;
      Frames.Draw (c, c = focused)
    END ;
    c := c^.next
  END
END UpdateWorkarea ;

(* keep the frame inside the work area, shrinking it if needed *)
PROCEDURE Fit (c: Client) ;
VAR
  w, h: INTEGER ;
BEGIN
  IF c^.width + Frames.ExtraWidth (c) > workWidth
  THEN
    c^.width := workWidth - Frames.ExtraWidth (c)
  END ;
  IF c^.height + Frames.ExtraHeight (c) > workHeight
  THEN
    c^.height := workHeight - Frames.ExtraHeight (c)
  END ;
  w := c^.width ;
  h := c^.height ;
  Frames.Constrain (c, w, h) ;
  c^.width := w ;
  c^.height := h ;
  IF c^.x + c^.width + Frames.ExtraWidth (c) > workX + workWidth
  THEN
    c^.x := workX + workWidth - c^.width - Frames.ExtraWidth (c)
  END ;
  IF c^.y + c^.height + Frames.ExtraHeight (c) > workY + workHeight
  THEN
    c^.y := workY + workHeight - c^.height - Frames.ExtraHeight (c)
  END ;
  IF c^.x < workX THEN c^.x := workX END ;
  IF c^.y < workY THEN c^.y := workY END
END Fit ;

PROCEDURE Place (c: Client) ;
VAR
  parent: Client ;
BEGIN
  parent := NIL ;
  IF c^.transientFor # None
  THEN
    parent := Clients.Find (c^.transientFor)
  END ;
  IF (parent # NIL) AND (parent^.frame # parent^.window)
  THEN
    c^.x := parent^.x + (parent^.width + Frames.ExtraWidth (parent) -
                         c^.width - Frames.ExtraWidth (c)) DIV 2 ;
    c^.y := parent^.y + (parent^.height + Frames.ExtraHeight (parent) -
                         c^.height - Frames.ExtraHeight (c)) DIV 2
  ELSIF NOT (scanning OR UserPositioned (c))
  THEN
    c^.x := workX + CascadeStep + cascade * CascadeStep ;
    c^.y := workY + CascadeStep + cascade * CascadeStep ;
    cascade := (cascade + 1) MOD 8
  END ;
  Fit (c)
END Place ;

PROCEDURE Manage (w: Window) ;
VAR
  c, parent: Client ;
  x, y, cw, ch, mapState, override, state: INTEGER ;
  desk: LONGCARD ;
BEGIN
  IF (w = Ewmh.checkWindow) OR (Clients.Find (w) # NIL) OR
     (Clients.FindFrame (w) # NIL)
  THEN
    RETURN
  END ;
  IF (mx_window_attrs (dpy, w, x, y, cw, ch, mapState, override) = 0) OR
     (override # 0)
  THEN
    RETURN
  END ;
  c := Clients.New (w) ;
  c^.x := x ; c^.y := y ;
  c^.width := cw ; c^.height := ch ;
  IF XGetTransientForHint (dpy, w, c^.transientFor) = 0
  THEN
    c^.transientFor := None
  END ;
  ReadType (c) ;
  ReadMotifHints (c) ;
  ReadProtocols (c) ;
  ReadTitle (c) ;
  ReadSizeHints (c) ;
  state := ReadWmHints (c) ;
  c^.desktop := currentDesktop ;
  parent := NIL ;
  IF c^.transientFor # None
  THEN
    parent := Clients.Find (c^.transientFor)
  END ;
  IF parent # NIL
  THEN
    c^.desktop := parent^.desktop
  ELSIF Props.GetCardinal (w, Atoms.NetWmDesktop, XA_CARDINAL, desk)
  THEN
    IF desk = 0FFFFFFFFH
    THEN
      c^.desktop := AllDesktops
    ELSIF desk < VAL (LONGCARD, desktopCount)
    THEN
      c^.desktop := VAL (INTEGER, desk)
    END
  END ;
  IF XSelectInput (dpy, w, ClientMask) = 0 THEN END ;
  IF (c^.kind = Dock) OR (c^.kind = DesktopKind)
  THEN
    (* docks and desktop windows stay unframed on every desktop *)
    c^.frame := w ;
    c^.decorated := FALSE ;
    c^.desktop := AllDesktops ;
    IF c^.kind = Dock
    THEN
      ReadStrut (c)
    END ;
    IF XMapWindow (dpy, w) = 0 THEN END ;
    SetWmState (c, NormalState) ;
    Ewmh.SetClientDesktop (c) ;
    UpdateWorkarea ;
    Restack ;
    RETURN
  END ;
  c^.minimized := state = IconicState ;
  IF scanning
  THEN
    (* keep an adopted client where it already is on screen *)
    c^.x := c^.x - Frames.Left (c) ;
    c^.y := c^.y - Frames.Top (c)
  END ;
  Place (c) ;
  Frames.Create (c) ;
  Frames.Apply (c) ;
  GrabClicks (c) ;
  GrabFrameButtons (c) ;
  ReadInitialState (c) ;
  IF c^.minimized
  THEN
    SetWmState (c, IconicState)
  ELSE
    SetWmState (c, NormalState)
  END ;
  Ewmh.SetClientDesktop (c) ;
  Ewmh.SetClientState (c) ;
  Show (c) ;
  RaiseClient (c) ;
  IF Visible (c)
  THEN
    Focus (c)
  END
END Manage ;

PROCEDURE Unmanage (c: Client; alive, withdraw: BOOLEAN) ;
VAR
  wasFocused, wasDock: BOOLEAN ;
  owner: Window ;
  parent: Client ;
BEGIN
  owner := c^.transientFor ;
  wasFocused := c = focused ;
  wasDock := c^.kind = Dock ;
  IF dragClient = c
  THEN
    EndDrag
  END ;
  IF hoverFrame = c THEN hoverFrame := NIL END ;
  IF titleClickClient = c THEN titleClickClient := NIL END ;
  IF wasFocused
  THEN
    focused := NIL
  END ;
  IF Reparented (c)
  THEN
    Frames.Release (c, alive)
  END ;
  IF alive
  THEN
    IF XSelectInput (dpy, c^.window, 0) = 0 THEN END ;
    IF withdraw
    THEN
      SetWmState (c, WithdrawnState) ;
      Ewmh.ClearClient (c)
    END
  END ;
  Clients.Remove (c) ;
  IF wasDock
  THEN
    UpdateWorkarea
  END ;
  Ewmh.UpdateClientList ;
  IF wasFocused
  THEN
    (* a closed dialog hands focus back to its owner *)
    parent := NIL ;
    IF owner # None
    THEN
      parent := Clients.Find (owner)
    END ;
    IF (parent # NIL) AND Eligible (parent)
    THEN
      Focus (parent)
    ELSE
      FocusFallback
    END
  END
END Unmanage ;

PROCEDURE SetMinimized (c: Client; on: BOOLEAN) ;
VAR
  t: Client ;
BEGIN
  IF (NOT Reparented (c)) OR (c^.minimized = on)
  THEN
    RETURN
  END ;
  c^.minimized := on ;
  IF on
  THEN
    SetWmState (c, IconicState)
  ELSE
    SetWmState (c, NormalState)
  END ;
  Ewmh.SetClientState (c) ;
  Show (c) ;
  (* dialogs follow their owner *)
  t := Clients.first ;
  WHILE t # NIL DO
    IF (t^.transientFor = c^.window) AND (t # c)
    THEN
      SetMinimized (t, on)
    END ;
    t := t^.next
  END ;
  IF on AND (c = focused)
  THEN
    FocusFallback
  END
END SetMinimized ;

PROCEDURE SwitchDesktop (n: INTEGER) ;
VAR
  c: Client ;
BEGIN
  IF (n < 0) OR (n >= desktopCount) OR (n = currentDesktop)
  THEN
    RETURN
  END ;
  currentDesktop := n ;
  (* map the new desktop before unmapping the old one *)
  c := Clients.stackTop ;
  WHILE c # NIL DO
    IF Visible (c) THEN Show (c) END ;
    c := c^.stackNext
  END ;
  c := Clients.stackTop ;
  WHILE c # NIL DO
    IF NOT Visible (c) THEN Show (c) END ;
    c := c^.stackNext
  END ;
  Ewmh.SetDesktops (desktopCount, currentDesktop) ;
  FocusFallback
END SwitchDesktop ;

PROCEDURE SendToDesktop (c: Client; n: INTEGER) ;
VAR
  t: Client ;
BEGIN
  IF (NOT Reparented (c)) OR (n = c^.desktop) OR
     ((n # AllDesktops) AND ((n < 0) OR (n >= desktopCount)))
  THEN
    RETURN
  END ;
  c^.desktop := n ;
  Ewmh.SetClientDesktop (c) ;
  Show (c) ;
  t := Clients.first ;
  WHILE t # NIL DO
    IF (t^.transientFor = c^.window) AND (t # c)
    THEN
      SendToDesktop (t, n)
    END ;
    t := t^.next
  END ;
  IF (c = focused) AND NOT Visible (c)
  THEN
    FocusFallback
  END
END SendToDesktop ;

(* step through desktops, wrapping at either end *)
PROCEDURE Neighbour (step: INTEGER) : INTEGER ;
BEGIN
  RETURN (currentDesktop + step + desktopCount) MOD desktopCount
END Neighbour ;

PROCEDURE SendAndFollow (step: INTEGER) ;
VAR
  c: Client ;
  n: INTEGER ;
BEGIN
  c := focused ;
  IF (c = NIL) OR (c^.desktop = AllDesktops)
  THEN
    RETURN
  END ;
  n := Neighbour (step) ;
  SendToDesktop (c, n) ;
  SwitchDesktop (n) ;
  Activate (c)
END SendAndFollow ;

PROCEDURE Activate (c: Client) ;
BEGIN
  IF (c^.desktop # AllDesktops) AND (c^.desktop # currentDesktop)
  THEN
    SwitchDesktop (c^.desktop)
  END ;
  SetMinimized (c, FALSE) ;
  RaiseClient (c) ;
  Focus (c)
END Activate ;

PROCEDURE SaveGeometry (c: Client) ;
BEGIN
  c^.savedX := c^.x ;
  c^.savedY := c^.y ;
  c^.savedWidth := c^.width ;
  c^.savedHeight := c^.height
END SaveGeometry ;

PROCEDURE RestoreGeometry (c: Client) ;
BEGIN
  IF c^.savedWidth > 0
  THEN
    c^.x := c^.savedX ;
    c^.y := c^.savedY ;
    c^.width := c^.savedWidth ;
    c^.height := c^.savedHeight
  END
END RestoreGeometry ;

PROCEDURE MaximizedGeometry (c: Client) ;
VAR
  w, h: INTEGER ;
BEGIN
  w := workWidth - Frames.ExtraWidth (c) ;
  h := workHeight - Frames.ExtraHeight (c) ;
  Frames.Constrain (c, w, h) ;
  c^.width := w ;
  c^.height := h ;
  c^.x := workX ;
  c^.y := workY
END MaximizedGeometry ;

PROCEDURE SetMaximized (c: Client; on: BOOLEAN) ;
BEGIN
  IF (NOT Reparented (c)) OR (c^.maximized = on)
  THEN
    RETURN
  END ;
  c^.maximized := on ;
  IF NOT c^.fullscreen
  THEN
    IF on
    THEN
      SaveGeometry (c) ;
      MaximizedGeometry (c)
    ELSE
      RestoreGeometry (c)
    END ;
    Frames.Apply (c) ;
    Frames.Draw (c, c = focused)
  END ;
  Ewmh.SetClientState (c)
END SetMaximized ;

PROCEDURE SetFullscreen (c: Client; on: BOOLEAN) ;
BEGIN
  IF (NOT Reparented (c)) OR (c^.fullscreen = on)
  THEN
    RETURN
  END ;
  IF on
  THEN
    IF NOT c^.maximized
    THEN
      SaveGeometry (c)
    END ;
    c^.fullscreen := TRUE ;
    c^.x := 0 ;
    c^.y := 0 ;
    c^.width := width ;
    c^.height := height
  ELSE
    c^.fullscreen := FALSE ;
    IF c^.maximized
    THEN
      MaximizedGeometry (c)
    ELSE
      RestoreGeometry (c)
    END
  END ;
  Frames.Apply (c) ;
  Frames.SetExtents (c) ;
  Frames.Draw (c, c = focused) ;
  Ewmh.SetClientState (c) ;
  Restack
END SetFullscreen ;

PROCEDURE Wanted (action: LONGINT; current: BOOLEAN) : BOOLEAN ;
BEGIN
  CASE action OF
    StateRemove: RETURN FALSE |
    StateAdd: RETURN TRUE |
    StateToggle: RETURN NOT current
  ELSE
    RETURN current
  END
END Wanted ;

PROCEDURE ChangeState (c: Client; action: LONGINT; prop: Atom;
                       VAR maximizeDone: BOOLEAN) ;
BEGIN
  IF prop = None
  THEN
    RETURN
  ELSIF prop = Atoms.NetWmStateFullscreen
  THEN
    SetFullscreen (c, Wanted (action, c^.fullscreen))
  ELSIF (prop = Atoms.NetWmStateMaximizedVert) OR
        (prop = Atoms.NetWmStateMaximizedHorz)
  THEN
    (* both axes are maximized together *)
    IF NOT maximizeDone
    THEN
      SetMaximized (c, Wanted (action, c^.maximized)) ;
      maximizeDone := TRUE
    END
  ELSIF prop = Atoms.NetWmStateHidden
  THEN
    SetMinimized (c, Wanted (action, c^.minimized))
  ELSIF prop = Atoms.NetWmStateDemandsAttention
  THEN
    c^.urgent := Wanted (action, c^.urgent) AND (c # focused)
  ELSIF prop = Atoms.NetWmStateSkipTaskbar
  THEN
    c^.skipTaskbar := Wanted (action, c^.skipTaskbar)
  ELSIF prop = Atoms.NetWmStateSkipPager
  THEN
    c^.skipPager := Wanted (action, c^.skipPager)
  END
END ChangeState ;

(* apply _NET_WM_STATE requested before the window was mapped *)
PROCEDURE ReadInitialState (c: Client) ;
VAR
  states: ARRAY [0..15] OF LONGCARD ;
  n, i: CARDINAL ;
  done: BOOLEAN ;
BEGIN
  n := Props.GetCardinals (c^.window, Atoms.NetWmState, XA_ATOM, states) ;
  done := FALSE ;
  FOR i := 1 TO n DO
    IF states[i - 1] # Atoms.NetWmStateHidden
    THEN
      ChangeState (c, StateAdd, states[i - 1], done)
    END
  END
END ReadInitialState ;

PROCEDURE GrabFrameButtons (c: Client) ;
VAR
  numlock: CARDINAL ;
  mods: ARRAY [0..3] OF CARDINAL ;
  i, b: CARDINAL ;
BEGIN
  numlock := mx_numlock_mask (dpy) ;
  mods[0] := Mod1Mask ;
  mods[1] := Mod1Mask + LockMask ;
  mods[2] := Mod1Mask + numlock ;
  mods[3] := Mod1Mask + numlock + LockMask ;
  FOR i := 0 TO 3 DO
    IF (i < 2) OR (numlock # 0)
    THEN
      FOR b := 1 TO 3 BY 2 DO
        IF XGrabButton (dpy, b, mods[i], c^.frame, False,
                        ButtonPressMask + ButtonReleaseMask,
                        GrabModeAsync, GrabModeAsync, None, None) = 0 THEN END
      END
    END
  END
END GrabFrameButtons ;

PROCEDURE EndDrag ;
BEGIN
  IF drag = DragNone
  THEN
    RETURN
  END ;
  IF drag = DragBox
  THEN
    Frames.SetPressed (NIL, Frames.Nowhere)
  END ;
  drag := DragNone ;
  dragClient := NIL ;
  IF XUngrabPointer (dpy, lastTime) = 0 THEN END
END EndDrag ;

PROCEDURE StartDrag (c: Client; mode: DragMode; part: Part; VAR e: Event) ;
VAR
  cursor: Cursor ;
BEGIN
  IF c^.fullscreen
  THEN
    RETURN
  END ;
  IF mode = DragMove
  THEN
    cursor := cursors[Frames.TitleBar]
  ELSE
    cursor := cursors[part]
  END ;
  IF XGrabPointer (dpy, root, False, DragMask, GrabModeAsync, GrabModeAsync,
                   None, cursor, e.time) # GrabSuccess
  THEN
    RETURN
  END ;
  drag := mode ;
  dragClient := c ;
  dragPart := part ;
  dragX := e.xRoot ;
  dragY := e.yRoot ;
  origX := c^.x ;
  origY := c^.y ;
  origWidth := c^.width ;
  origHeight := c^.height ;
  IF mode = DragBox
  THEN
    Frames.SetPressed (c, part)
  END
END StartDrag ;

PROCEDURE DragMoved (VAR e: Event) ;
VAR
  c: Client ;
  dx, dy, w, h: INTEGER ;
  north, south, east, west: BOOLEAN ;
BEGIN
  c := dragClient ;
  dx := e.xRoot - dragX ;
  dy := e.yRoot - dragY ;
  IF c^.maximized AND (drag # DragBox) AND ((dx # 0) OR (dy # 0))
  THEN
    (* a moved or resized maximized window keeps its current size *)
    c^.maximized := FALSE ;
    Ewmh.SetClientState (c)
  END ;
  CASE drag OF
    DragMove:
      c^.x := origX + dx ;
      c^.y := origY + dy ;
      (* the title bar must stay reachable *)
      IF c^.y < workY THEN c^.y := workY END ;
      IF c^.y > height - Frames.Top (c) THEN c^.y := height - Frames.Top (c) END ;
      Frames.Apply (c) |
    DragResize:
      north := (dragPart = Frames.EdgeN) OR (dragPart = Frames.EdgeNE) OR
               (dragPart = Frames.EdgeNW) ;
      south := (dragPart = Frames.EdgeS) OR (dragPart = Frames.EdgeSE) OR
               (dragPart = Frames.EdgeSW) ;
      west := (dragPart = Frames.EdgeW) OR (dragPart = Frames.EdgeNW) OR
              (dragPart = Frames.EdgeSW) ;
      east := (dragPart = Frames.EdgeE) OR (dragPart = Frames.EdgeNE) OR
              (dragPart = Frames.EdgeSE) ;
      w := origWidth ;
      h := origHeight ;
      IF east THEN w := origWidth + dx END ;
      IF west THEN w := origWidth - dx END ;
      IF south THEN h := origHeight + dy END ;
      IF north THEN h := origHeight - dy END ;
      Frames.Constrain (c, w, h) ;
      c^.width := w ;
      c^.height := h ;
      c^.x := origX ;
      c^.y := origY ;
      IF west THEN c^.x := origX + origWidth - w END ;
      IF north THEN c^.y := origY + origHeight - h END ;
      Frames.Apply (c) ;
      Frames.Draw (c, c = focused) |
    DragBox:
      IF Frames.HitTest (c, e.xRoot - c^.x, e.yRoot - c^.y) = dragPart
      THEN
        Frames.SetPressed (c, dragPart)
      ELSE
        Frames.SetPressed (NIL, Frames.Nowhere)
      END
  ELSE
  END
END DragMoved ;

PROCEDURE DragReleased (VAR e: Event) ;
VAR
  c: Client ;
  part: Part ;
BEGIN
  c := dragClient ;
  part := dragPart ;
  IF (drag = DragBox) AND
     (Frames.HitTest (c, e.xRoot - c^.x, e.yRoot - c^.y) = part)
  THEN
    EndDrag ;
    CASE part OF
      Frames.CloseBox: Close (c) |
      Frames.MinimizeBox: SetMinimized (c, TRUE) |
      Frames.MaximizeBox: SetMaximized (c, NOT c^.maximized)
    ELSE
    END
  ELSE
    EndDrag
  END
END DragReleased ;

(* edge nearest to the pointer, for alt + right button resizing *)
PROCEDURE NearestCorner (c: Client; x, y: INTEGER) : Part ;
VAR
  left, top: BOOLEAN ;
BEGIN
  left := x < (c^.width + Frames.ExtraWidth (c)) DIV 2 ;
  top := y < (c^.height + Frames.ExtraHeight (c)) DIV 2 ;
  IF top AND left THEN RETURN Frames.EdgeNW END ;
  IF top THEN RETURN Frames.EdgeNE END ;
  IF left THEN RETURN Frames.EdgeSW END ;
  RETURN Frames.EdgeSE
END NearestCorner ;

(* _NET_WM_MOVERESIZE: a client asks us to run a move or resize drag,
   typically from its own title bar or size grip *)
PROCEDURE ClientDrag (c: Client; VAR e: Event) ;
CONST
  Move = 8 ;
  Cancel = 11 ;
VAR
  parts: ARRAY [0..7] OF Part ;
  start: Event ;
  rootRet, child: Window ;
  rx, ry, wx, wy: INTEGER ;
  buttons: CARDINAL ;
BEGIN
  IF e.data[2] = Cancel
  THEN
    IF dragClient = c THEN EndDrag END ;
    RETURN
  END ;
  IF (drag # DragNone) OR (NOT Reparented (c)) OR (e.data[2] < 0) OR
     (e.data[2] > Move)
  THEN
    RETURN
  END ;
  parts[0] := Frames.EdgeNW ; parts[1] := Frames.EdgeN ;
  parts[2] := Frames.EdgeNE ; parts[3] := Frames.EdgeE ;
  parts[4] := Frames.EdgeSE ; parts[5] := Frames.EdgeS ;
  parts[6] := Frames.EdgeSW ; parts[7] := Frames.EdgeW ;
  start := e ;
  start.xRoot := VAL (INTEGER, e.data[0]) ;
  start.yRoot := VAL (INTEGER, e.data[1]) ;
  start.time := CurrentTime ;
  IF e.data[2] = Move
  THEN
    StartDrag (c, DragMove, Frames.TitleBar, start)
  ELSE
    StartDrag (c, DragResize, parts[e.data[2]], start)
  END ;
  (* the button may already be up, and then no release would end it *)
  IF (drag # DragNone) AND
     (XQueryPointer (dpy, root, rootRet, child, rx, ry, wx, wy, buttons) # 0) AND
     (buttons DIV Button1Mask MOD 32 = 0)
  THEN
    EndDrag
  END
END ClientDrag ;

PROCEDURE FramePress (c: Client; VAR e: Event) ;
VAR
  part: Part ;
BEGIN
  Activate (c) ;
  IF HasBit (e.state, Mod1Mask)
  THEN
    IF e.detail = 1
    THEN
      StartDrag (c, DragMove, Frames.TitleBar, e)
    ELSIF (e.detail = 3) AND NOT c^.fullscreen
    THEN
      StartDrag (c, DragResize, NearestCorner (c, e.x, e.y), e)
    END ;
    RETURN
  END ;
  part := Frames.HitTest (c, e.x, e.y) ;
  IF e.detail = 3
  THEN
    IF part = Frames.TitleBar
    THEN
      Clients.Lower (c) ;
      Restack
    END ;
    RETURN
  END ;
  IF e.detail # 1
  THEN
    RETURN
  END ;
  CASE part OF
    Frames.TitleBar:
      IF (titleClickClient = c) AND (e.time - titleClickTime < DoubleClickTime)
      THEN
        titleClickClient := NIL ;
        SetMaximized (c, NOT c^.maximized)
      ELSE
        titleClickClient := c ;
        titleClickTime := e.time ;
        StartDrag (c, DragMove, part, e)
      END |
    Frames.CloseBox, Frames.MinimizeBox, Frames.MaximizeBox:
      StartDrag (c, DragBox, part, e) |
    Frames.Nowhere:
  ELSE
    StartDrag (c, DragResize, part, e)
  END
END FramePress ;

PROCEDURE Hover (VAR e: Event) ;
VAR
  c: Client ;
  part: Part ;
BEGIN
  c := Clients.FindFrame (e.window) ;
  IF (c = NIL) OR NOT Reparented (c)
  THEN
    RETURN
  END ;
  part := Frames.HitTest (c, e.x, e.y) ;
  IF (part >= Frames.EdgeN) AND NOT c^.fullscreen
  THEN
  ELSE
    part := Frames.Nowhere
  END ;
  IF (c # hoverFrame) OR (part # hoverPart)
  THEN
    hoverFrame := c ;
    hoverPart := part ;
    IF XDefineCursor (dpy, c^.frame, cursors[part]) = 0 THEN END
  END
END Hover ;

PROCEDURE OnMotionNotify (VAR e: Event) ;
BEGIN
  mx_compress_motion (dpy, e) ;
  IF drag # DragNone
  THEN
    DragMoved (e)
  ELSE
    Hover (e)
  END
END OnMotionNotify ;

PROCEDURE Eligible (c: Client) : BOOLEAN ;
BEGIN
  RETURN Visible (c) AND (c^.kind # Dock) AND (c^.kind # DesktopKind)
END Eligible ;

(* step through the focus history without reordering it *)
PROCEDURE CycleStep (forward: BOOLEAN) ;
VAR
  c, target, prev: Client ;
BEGIN
  target := NIL ;
  IF forward
  THEN
    IF focused # NIL THEN c := focused^.focusNext ELSE c := Clients.focusFirst END ;
    WHILE (c # NIL) AND NOT Eligible (c) DO c := c^.focusNext END ;
    IF c = NIL
    THEN
      c := Clients.focusFirst ;
      WHILE (c # NIL) AND NOT Eligible (c) DO c := c^.focusNext END
    END ;
    target := c
  ELSE
    (* the last eligible client before the focused one, wrapping *)
    prev := NIL ;
    c := Clients.focusFirst ;
    WHILE c # NIL DO
      IF (c = focused) AND (prev # NIL)
      THEN
        target := prev
      END ;
      IF Eligible (c) AND (c # focused)
      THEN
        prev := c
      END ;
      c := c^.focusNext
    END ;
    IF target = NIL THEN target := prev END
  END ;
  IF (target # NIL) AND (target # focused)
  THEN
    RaiseClient (target) ;
    Focus (target)
  END
END CycleStep ;

PROCEDURE EndCycle ;
BEGIN
  IF NOT cycling
  THEN
    RETURN
  END ;
  cycling := FALSE ;
  IF XUngrabKeyboard (dpy, lastTime) = 0 THEN END ;
  IF focused # NIL
  THEN
    Clients.Touch (focused)
  END
END EndCycle ;

PROCEDURE AltHeld () : BOOLEAN ;
VAR
  keys: ARRAY [0..31] OF CHAR ;
  i: CARDINAL ;
BEGIN
  IF XQueryKeymap (dpy, keys) = 0 THEN END ;
  FOR i := 8 TO 255 DO
    IF ((i MOD 8) IN BITSET (ORD (keys[i DIV 8]))) AND
       Keys.IsCycleModifier (i)
    THEN
      RETURN TRUE
    END
  END ;
  RETURN FALSE
END AltHeld ;

PROCEDURE StartCycle (forward: BOOLEAN; VAR e: Event) ;
BEGIN
  IF (NOT cycling) AND
     (XGrabKeyboard (dpy, root, True, GrabModeAsync, GrabModeAsync,
                     e.time) = GrabSuccess)
  THEN
    cycling := TRUE
  END ;
  CycleStep (forward) ;
  (* alt may have been released before the grab took effect *)
  IF cycling AND NOT AltHeld ()
  THEN
    EndCycle
  END
END StartCycle ;

PROCEDURE RunAction (action: Action; arg: INTEGER; VAR e: Event) ;
BEGIN
  CASE action OF
    Keys.CycleNext: StartCycle (TRUE, e) |
    Keys.CyclePrev: StartCycle (FALSE, e) |
    Keys.CloseWindow: IF focused # NIL THEN Close (focused) END |
    Keys.MinimizeWindow: IF focused # NIL THEN SetMinimized (focused, TRUE) END |
    Keys.MaximizeWindow:
      IF focused # NIL THEN SetMaximized (focused, NOT focused^.maximized) END |
    Keys.FullscreenWindow:
      IF focused # NIL THEN SetFullscreen (focused, NOT focused^.fullscreen) END |
    Keys.DesktopNext: SwitchDesktop (Neighbour (1)) |
    Keys.DesktopPrev: SwitchDesktop (Neighbour (-1)) |
    Keys.GotoDesktop: SwitchDesktop (arg) |
    Keys.SendNext: SendAndFollow (1) |
    Keys.SendPrev: SendAndFollow (-1) |
    Keys.OpenLauncher: Desktop.Launch (Desktop.Launcher) |
    Keys.OpenTerminal: Desktop.Launch (Desktop.Terminal) |
    Keys.OpenFiles: Desktop.Launch (Desktop.Files)
  ELSE
  END
END RunAction ;

PROCEDURE OnKeyPress (VAR e: Event) ;
VAR
  arg: INTEGER ;
  action: Action ;
BEGIN
  arg := 0 ;
  action := Keys.Lookup (e.detail, e.state, arg) ;
  IF cycling AND (action # Keys.CycleNext) AND (action # Keys.CyclePrev)
  THEN
    EndCycle
  END ;
  RunAction (action, arg, e)
END OnKeyPress ;

PROCEDURE OnKeyRelease (VAR e: Event) ;
BEGIN
  IF cycling AND Keys.IsCycleModifier (e.detail)
  THEN
    EndCycle
  END
END OnKeyRelease ;

PROCEDURE OnMapRequest (VAR e: Event) ;
VAR
  c: Client ;
BEGIN
  c := Clients.Find (e.window) ;
  IF c = NIL
  THEN
    Manage (e.window)
  ELSE
    Activate (c)
  END
END OnMapRequest ;

PROCEDURE OnUnmapNotify (VAR e: Event) ;
VAR
  c: Client ;
BEGIN
  c := Clients.Find (e.window) ;
  IF c = NIL
  THEN
    RETURN
  END ;
  (* our own reparenting unmaps arrive from the root and are ignored *)
  IF (NOT Reparented (c)) OR (e.subwindow = c^.frame) OR (e.sendEvent # 0)
  THEN
    Unmanage (c, TRUE, TRUE)
  END
END OnUnmapNotify ;

PROCEDURE OnDestroyNotify (VAR e: Event) ;
VAR
  c: Client ;
BEGIN
  c := Clients.Find (e.window) ;
  IF c # NIL
  THEN
    Unmanage (c, FALSE, FALSE)
  END
END OnDestroyNotify ;

PROCEDURE OnConfigureRequest (VAR e: Event) ;
VAR
  c: Client ;
  w, h: INTEGER ;
BEGIN
  c := Clients.Find (e.window) ;
  IF c = NIL
  THEN
    mx_configure_window (dpy, e.window, e.valueMask, e.x, e.y, e.width,
                         e.height, e.border, e.subwindow, e.detail) ;
    RETURN
  END ;
  IF NOT Reparented (c)
  THEN
    mx_configure_window (dpy, e.window, e.valueMask, e.x, e.y, e.width,
                         e.height, 0, e.subwindow, e.detail) ;
    RETURN
  END ;
  IF NOT (c^.fullscreen OR c^.maximized)
  THEN
    IF HasBit (e.valueMask, CWX) THEN c^.x := e.x END ;
    IF HasBit (e.valueMask, CWY) THEN c^.y := e.y END ;
    w := c^.width ;
    h := c^.height ;
    IF HasBit (e.valueMask, CWWidth) THEN w := e.width END ;
    IF HasBit (e.valueMask, CWHeight) THEN h := e.height END ;
    Frames.Constrain (c, w, h) ;
    c^.width := w ;
    c^.height := h
  END ;
  Frames.Apply (c) ;
  IF HasBit (e.valueMask, CWStackMode) AND (e.detail = Above) AND
     (e.subwindow = None) AND Visible (c)
  THEN
    RaiseClient (c)
  END
END OnConfigureRequest ;

PROCEDURE OnPropertyNotify (VAR e: Event) ;
VAR
  c: Client ;
  state: INTEGER ;
BEGIN
  c := Clients.Find (e.window) ;
  IF c = NIL
  THEN
    RETURN
  END ;
  IF (e.atom = XA_WM_NAME) OR (e.atom = Atoms.NetWmName)
  THEN
    ReadTitle (c) ;
    IF Reparented (c)
    THEN
      Frames.Draw (c, c = focused)
    END
  ELSIF e.atom = XA_WM_NORMAL_HINTS
  THEN
    ReadSizeHints (c)
  ELSIF e.atom = XA_WM_HINTS
  THEN
    state := ReadWmHints (c) ;
    Ewmh.SetClientState (c)
  ELSIF e.atom = XA_WM_TRANSIENT_FOR
  THEN
    IF XGetTransientForHint (dpy, c^.window, c^.transientFor) = 0
    THEN
      c^.transientFor := None
    END
  ELSIF e.atom = Atoms.WmProtocols
  THEN
    ReadProtocols (c)
  ELSIF (c^.kind = Dock) AND
        ((e.atom = Atoms.NetWmStrut) OR (e.atom = Atoms.NetWmStrutPartial))
  THEN
    ReadStrut (c) ;
    UpdateWorkarea
  END
END OnPropertyNotify ;

PROCEDURE OnClientMessage (VAR e: Event) ;
VAR
  c: Client ;
  ext: ARRAY [0..3] OF LONGCARD ;
  done: BOOLEAN ;
BEGIN
  IF e.atom = Atoms.MosaicCommand
  THEN
    IF e.data[0] = Atoms.CommandLogout
    THEN
      quit := TRUE
    END ;
    RETURN
  ELSIF e.atom = Atoms.NetCurrentDesktop
  THEN
    SwitchDesktop (VAL (INTEGER, e.data[0])) ;
    RETURN
  ELSIF e.atom = Atoms.NetRequestFrameExtents
  THEN
    ext[0] := Frames.Border ;
    ext[1] := Frames.Border ;
    ext[2] := Frames.Border + Frames.TitleHeight ;
    ext[3] := Frames.Border ;
    Props.SetCardinals (e.window, Atoms.NetFrameExtents, XA_CARDINAL, ext, 4) ;
    RETURN
  END ;
  c := Clients.Find (e.window) ;
  IF c = NIL
  THEN
    RETURN
  END ;
  IF e.atom = Atoms.NetActiveWindow
  THEN
    Activate (c)
  ELSIF e.atom = Atoms.NetCloseWindow
  THEN
    Close (c)
  ELSIF e.atom = Atoms.NetWmMoveresize
  THEN
    ClientDrag (c, e)
  ELSIF e.atom = Atoms.NetWmDesktop
  THEN
    IF (e.data[0] = 0FFFFFFFFH) OR (e.data[0] = -1)
    THEN
      SendToDesktop (c, AllDesktops)
    ELSE
      SendToDesktop (c, VAL (INTEGER, e.data[0]))
    END
  ELSIF e.atom = Atoms.WmChangeState
  THEN
    IF e.data[0] = IconicState
    THEN
      SetMinimized (c, TRUE)
    END
  ELSIF e.atom = Atoms.NetWmState
  THEN
    done := FALSE ;
    ChangeState (c, e.data[0], e.data[1], done) ;
    ChangeState (c, e.data[0], e.data[2], done) ;
    Ewmh.SetClientState (c) ;
    Frames.Draw (c, c = focused)
  END
END OnClientMessage ;

PROCEDURE RootPress (VAR e: Event) ;
VAR
  desk: INTEGER ;
BEGIN
  IF e.detail # 3
  THEN
    RETURN
  END ;
  desk := 0 ;
  CASE Desktop.RootMenu (e.xRoot, e.yRoot, e.time, currentDesktop,
                         desktopCount, Handle, desk) OF
    Desktop.Logout: quit := TRUE |
    Desktop.SwitchTo: SwitchDesktop (desk)
  ELSE
  END
END RootPress ;

PROCEDURE OnButtonPress (VAR e: Event) ;
VAR
  c: Client ;
BEGIN
  IF (e.window = root) AND (drag = DragNone) AND NOT cycling
  THEN
    RootPress (e) ;
    RETURN
  END ;
  c := Clients.Find (e.window) ;
  IF c # NIL
  THEN
    (* click on an unfocused client: focus it and pass the click on *)
    Activate (c) ;
    IF XAllowEvents (dpy, ReplayPointer, e.time) = 0 THEN END ;
    RETURN
  END ;
  IF cycling
  THEN
    EndCycle
  END ;
  c := Clients.FindFrame (e.window) ;
  IF (c # NIL) AND Reparented (c) AND (drag = DragNone)
  THEN
    FramePress (c, e)
  END
END OnButtonPress ;

PROCEDURE OnButtonRelease (VAR e: Event) ;
BEGIN
  IF drag # DragNone
  THEN
    DragReleased (e)
  END
END OnButtonRelease ;

PROCEDURE OnExpose (VAR e: Event) ;
VAR
  c: Client ;
BEGIN
  IF e.detail # 0
  THEN
    RETURN
  END ;
  c := Clients.FindFrame (e.window) ;
  IF (c # NIL) AND Reparented (c)
  THEN
    Frames.Draw (c, c = focused)
  END
END OnExpose ;

(* the root changed size, for example through xrandr *)
PROCEDURE OnRootConfigure (VAR e: Event) ;
BEGIN
  IF (e.window # root) OR ((e.width = width) AND (e.height = height))
  THEN
    RETURN
  END ;
  width := e.width ;
  height := e.height ;
  Ewmh.SetDesktops (desktopCount, currentDesktop) ;
  workWidth := -1 ;
  UpdateWorkarea ;
  (* the wallpaper is scaled to the old size *)
  Desktop.Release ;
  Desktop.Paint
END OnRootConfigure ;

PROCEDURE Handle (VAR e: Event) ;
BEGIN
  CASE e.type OF
    KeyPress, KeyRelease, ButtonPress, ButtonRelease, MotionNotify,
    PropertyNotify:
      IF e.time # 0 THEN lastTime := e.time END
  ELSE
  END ;
  CASE e.type OF
    MapRequest: OnMapRequest (e) |
    UnmapNotify: OnUnmapNotify (e) |
    DestroyNotify: OnDestroyNotify (e) |
    ConfigureRequest: OnConfigureRequest (e) |
    PropertyNotify: OnPropertyNotify (e) |
    ConfigureNotify: OnRootConfigure (e) |
    ClientMessage: OnClientMessage (e) |
    ButtonPress: OnButtonPress (e) |
    ButtonRelease: OnButtonRelease (e) |
    MotionNotify: OnMotionNotify (e) |
    KeyPress: OnKeyPress (e) |
    KeyRelease: OnKeyRelease (e) |
    Expose: OnExpose (e)
  ELSE
  END
END Handle ;

PROCEDURE ScanExisting ;
VAR
  rootRet, parentRet: Window ;
  children: ADDRESS ;
  list: Longs ;
  n, i: CARDINAL ;
  x, y, w, h, mapState, override: INTEGER ;
  state: LONGCARD ;
BEGIN
  IF XQueryTree (dpy, root, rootRet, parentRet, children, n) = 0
  THEN
    RETURN
  END ;
  scanning := TRUE ;
  list := children ;
  FOR i := 1 TO n DO
    IF (mx_window_attrs (dpy, list^[i - 1], x, y, w, h, mapState,
                         override) # 0) AND (override = 0)
    THEN
      IF (mapState = IsViewable) OR
         (Props.GetCardinal (list^[i - 1], Atoms.WmState, Atoms.WmState,
                             state) AND (state = IconicState))
      THEN
        Manage (list^[i - 1])
      END
    END
  END ;
  scanning := FALSE ;
  IF children # NIL
  THEN
    IF XFree (children) = 0 THEN END
  END
END ScanExisting ;

PROCEDURE CreateCursors ;
BEGIN
  cursors[Frames.Nowhere] := XCreateFontCursor (dpy, 68) ;
  cursors[Frames.TitleBar] := XCreateFontCursor (dpy, 52) ;
  cursors[Frames.CloseBox] := cursors[Frames.Nowhere] ;
  cursors[Frames.MinimizeBox] := cursors[Frames.Nowhere] ;
  cursors[Frames.MaximizeBox] := cursors[Frames.Nowhere] ;
  cursors[Frames.EdgeN] := XCreateFontCursor (dpy, 138) ;
  cursors[Frames.EdgeS] := XCreateFontCursor (dpy, 16) ;
  cursors[Frames.EdgeE] := XCreateFontCursor (dpy, 96) ;
  cursors[Frames.EdgeW] := XCreateFontCursor (dpy, 70) ;
  cursors[Frames.EdgeNE] := XCreateFontCursor (dpy, 136) ;
  cursors[Frames.EdgeNW] := XCreateFontCursor (dpy, 134) ;
  cursors[Frames.EdgeSE] := XCreateFontCursor (dpy, 14) ;
  cursors[Frames.EdgeSW] := XCreateFontCursor (dpy, 12)
END CreateCursors ;

PROCEDURE FreeCursors ;
VAR
  p: Part ;
BEGIN
  FOR p := Frames.Nowhere TO MAX (Part) DO
    IF (p # Frames.CloseBox) AND (p # Frames.MinimizeBox) AND
       (p # Frames.MaximizeBox)
    THEN
      IF XFreeCursor (dpy, cursors[p]) = 0 THEN END
    END
  END
END FreeCursors ;

PROCEDURE SetupDesktops ;
VAR
  current: LONGCARD ;
  names: ARRAY [0..255] OF CHAR ;
  list: ARRAY [0..255] OF CHAR ;
  i, n: CARDINAL ;
  number: ARRAY [0..3] OF CHAR ;
  ok: BOOLEAN ;
BEGIN
  desktopCount := Config.GetInt ("desktops", 4, 1, 9) ;
  (* a restarted manager returns to the desktop it left *)
  IF Props.GetCardinal (root, Atoms.NetCurrentDesktop, XA_CARDINAL, current) AND
     (current < VAL (LONGCARD, desktopCount))
  THEN
    currentDesktop := VAL (INTEGER, current)
  END ;
  Config.Get ("desktop.names", "", names) ;
  ok := TRUE ;
  n := 0 ;
  list[0] := 0C ;
  IF names[0] = 0C
  THEN
    FOR i := 1 TO VAL (CARDINAL, desktopCount) DO
      Str.IntToStr (i, number) ;
      ok := ok AND Str.Append (number, list) AND Str.Append (",", list)
    END ;
    names := list
  ELSE
    ok := Str.Append (",", names)
  END ;
  (* commas become the nul separators the property wants *)
  n := Str.Length (names) ;
  FOR i := 1 TO n DO
    IF names[i - 1] = ',' THEN names[i - 1] := 0C END
  END ;
  IF ok
  THEN
    Props.SetTextList (root, Atoms.NetDesktopNames, names, n)
  END ;
  Ewmh.SetDesktops (desktopCount, currentDesktop)
END SetupDesktops ;

PROCEDURE Start () : BOOLEAN ;
BEGIN
  IF mx_become_wm (dpy, root, RootMask) = 0
  THEN
    Log.Error ("another window manager is already running") ;
    RETURN FALSE
  END ;
  SetupDesktops ;
  Ewmh.Setup ;
  UpdateWorkarea ;
  CreateCursors ;
  IF XDefineCursor (dpy, root, cursors[Frames.Nowhere]) = 0 THEN END ;
  Desktop.Paint ;
  Keys.Grab ;
  IF XGrabServer (dpy) = 0 THEN END ;
  ScanExisting ;
  IF XUngrabServer (dpy) = 0 THEN END ;
  FocusFallback ;
  RETURN TRUE
END Start ;

PROCEDURE Stop ;
VAR
  c: Client ;
BEGIN
  WHILE Clients.first # NIL DO
    c := Clients.first ;
    Unmanage (c, TRUE, FALSE)
  END ;
  IF XSetInputFocus (dpy, PointerRoot, RevertToPointerRoot,
                     CurrentTime) = 0 THEN END ;
  Ewmh.Teardown ;
  FreeCursors ;
  Desktop.Release ;
  IF XSelectInput (dpy, root, 0) = 0 THEN END ;
  IF XSync (dpy, False) = 0 THEN END
END Stop ;

BEGIN
  quit := FALSE ;
  focused := NIL ;
  workX := 0 ;
  workY := 0 ;
  workWidth := -1 ;
  workHeight := -1 ;
  currentDesktop := 0 ;
  desktopCount := 1 ;
  cascade := 0 ;
  lastTime := CurrentTime ;
  scanning := FALSE ;
  cycling := FALSE ;
  drag := DragNone ;
  dragClient := NIL ;
  titleClickClient := NIL ;
  titleClickTime := 0 ;
  hoverFrame := NIL ;
  hoverPart := Frames.Nowhere
END Wm.
