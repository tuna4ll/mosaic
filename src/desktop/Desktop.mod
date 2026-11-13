IMPLEMENTATION MODULE Desktop ;

FROM Xlib IMPORT Time, Pixmap, None, XCreatePixmap, XFreePixmap,
                 XSetWindowBackgroundPixmap, XSetWindowBackground,
                 XClearWindow ;
FROM XServer IMPORT dpy, root, depth, visual, colormap, width, height ;
FROM Wallpaper IMPORT mx_wallpaper, Fill, Fit, Center, Tiled ;
FROM Menu IMPORT Dispatch ;
FROM Gfx IMPORT Surface ;
FROM Spawn IMPORT Args ;
IMPORT Gfx, Menu, Spawn, Config, Str, Log ;

CONST
  Tile = 32 ;
  ItemLauncher = 0 ;
  ItemTerminal = 1 ;
  ItemFiles = 2 ;
  FirstDesktop = 4 ;

VAR
  pattern: Pixmap ;

PROCEDURE ImageMode () : INTEGER ;
VAR
  mode: ARRAY [0..15] OF CHAR ;
BEGIN
  Config.Get ("desktop.image.mode", "fill", mode) ;
  IF Str.Equal (mode, "fit") THEN RETURN Fit END ;
  IF Str.Equal (mode, "center") THEN RETURN Center END ;
  IF Str.Equal (mode, "tile") THEN RETURN Tiled END ;
  IF NOT Str.Equal (mode, "fill")
  THEN
    Log.Error2 ("unknown desktop.image.mode, using fill", mode)
  END ;
  RETURN Fill
END ImageMode ;

PROCEDURE Paint ;
VAR
  s: Surface ;
  style: ARRAY [0..15] OF CHAR ;
  image: ARRAY [0..1023] OF CHAR ;
BEGIN
  Config.Get ("desktop.image", "", image) ;
  IF image[0] # 0C
  THEN
    pattern := mx_wallpaper (dpy, root, visual, colormap, depth, image,
                             ImageMode (), Gfx.Pixel (Gfx.Desk),
                             width, height) ;
    IF pattern # None
    THEN
      IF XSetWindowBackgroundPixmap (dpy, root, pattern) = 0 THEN END ;
      IF XClearWindow (dpy, root) = 0 THEN END ;
      RETURN
    END ;
    Log.Error2 ("cannot load desktop.image, using the pattern", image)
  END ;
  Config.Get ("desktop.pattern", "tiles", style) ;
  IF Str.Equal (style, "solid")
  THEN
    IF XSetWindowBackground (dpy, root, Gfx.Pixel (Gfx.Desk)) = 0 THEN END
  ELSE
    IF NOT Str.Equal (style, "tiles")
    THEN
      Log.Error2 ("unknown desktop.pattern, using tiles", style)
    END ;
    (* running-bond tesserae: grout lines offset by half a tile each row *)
    pattern := XCreatePixmap (dpy, root, Tile, Tile, depth) ;
    s := Gfx.NewSurface (pattern, FALSE) ;
    Gfx.Fill (s, 0, 0, Tile, Tile, Gfx.Desk) ;
    Gfx.Line (s, 0, Tile DIV 2 - 1, Tile - 1, Tile DIV 2 - 1, Gfx.DeskTile) ;
    Gfx.Line (s, 0, Tile - 1, Tile - 1, Tile - 1, Gfx.DeskTile) ;
    Gfx.Line (s, Tile - 1, 0, Tile - 1, Tile DIV 2 - 2, Gfx.DeskTile) ;
    Gfx.Line (s, Tile DIV 2 - 1, Tile DIV 2, Tile DIV 2 - 1, Tile - 2,
              Gfx.DeskTile) ;
    Gfx.FreeSurface (s) ;
    IF XSetWindowBackgroundPixmap (dpy, root, pattern) = 0 THEN END
  END ;
  IF XClearWindow (dpy, root) = 0 THEN END
END Paint ;

PROCEDURE Release ;
BEGIN
  IF pattern # None
  THEN
    IF XFreePixmap (dpy, pattern) = 0 THEN END ;
    pattern := None
  END
END Release ;

PROCEDURE Launch (p: Program) ;
VAR
  a: Args ;
  path: ARRAY [0..4095] OF CHAR ;
BEGIN
  Spawn.Clear (a) ;
  CASE p OF
    Launcher: Spawn.Sibling ("mosaic-launcher", path) |
    Files: Spawn.Sibling ("mosaic-files", path) |
    Terminal:
      IF NOT Spawn.Terminal (path)
      THEN
        Log.Error ("no terminal emulator found; set terminal in mosaicrc") ;
        RETURN
      END
  END ;
  IF Spawn.Add (a, path) AND (Spawn.Run (a, "") > 0) THEN END
END Launch ;

PROCEDURE RootMenu (x, y: INTEGER; t: Time; current, count: INTEGER;
                    other: Dispatch; VAR desktop: INTEGER) : Choice ;
VAR
  m: Menu.Menu ;
  i, choice: INTEGER ;
  label, number: ARRAY [0..31] OF CHAR ;
BEGIN
  Menu.Clear (m) ;
  Menu.Add (m, "Applications…", TRUE) ;
  Menu.Add (m, "Terminal", TRUE) ;
  Menu.Add (m, "Files", TRUE) ;
  Menu.AddSeparator (m) ;
  FOR i := 0 TO count - 1 DO
    Str.IntToStr (i + 1, number) ;
    IF Str.Assign ("Desktop ", label) AND Str.Append (number, label) THEN END ;
    Menu.AddChecked (m, label, i = current)
  END ;
  Menu.AddSeparator (m) ;
  Menu.Add (m, "Log Out", TRUE) ;
  choice := Menu.Popup (m, x, y, t, other) ;
  CASE choice OF
    ItemLauncher: Launch (Launcher) |
    ItemTerminal: Launch (Terminal) |
    ItemFiles: Launch (Files)
  ELSE
    IF (choice >= FirstDesktop) AND (choice < FirstDesktop + count)
    THEN
      desktop := choice - FirstDesktop ;
      RETURN SwitchTo
    ELSIF choice = FirstDesktop + count + 1
    THEN
      RETURN Logout
    END
  END ;
  RETURN Nothing
END RootMenu ;

BEGIN
  pattern := None
END Desktop.
