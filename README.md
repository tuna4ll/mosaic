# Mosaic

A lightweight, retro UNIX desktop environment for X11, written in Modula-2.

![Mosaic running glxgears, xeyes, xclock and the file manager](assets/screenshot.png)

Mosaic includes:

- `mosaic`: the window manager and desktop. It draws the window frames and handles virtual desktops, the EWMH/ICCCM conventions and the desktop menu.
- `mosaic-panel`: the panel, with a launcher button, desktop switcher, task list, clock and session menu.
- `mosaic-launcher`: an application launcher that reads freedesktop `.desktop` files.
- `mosaic-files`: a file manager that can copy, move, rename and delete.

## Installing

On x86_64 Linux, install the latest release with:

```sh
curl -fsSL https://github.com/tuna4ll/mosaic/releases/latest/download/install.sh | sh
```

It needs libX11, libXft and Imlib2, and installs to `/usr/local` (set `PREFIX` to change it) plus an X session entry in `/usr/share/xsessions`.

## Building

You need GNU Modula-2 (`gm2`), a C compiler, GNU Make, and the libX11, libXft and Imlib2 development files.

```sh
make
make install PREFIX=/usr/local   # DESTDIR is supported
```

`make install` also installs an X session entry, so a display manager can offer Mosaic at login.

## Trying it in Xephyr

```sh
Xephyr :91 -screen 1280x800 -nolisten tcp &
env -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS DISPLAY=:91 \
    dbus-run-session -- ./mosaic
```

## Keys

| Keys | Action |
| --- | --- |
| Alt+F1 / F2 / F3 | launcher / terminal / files |
| Alt+Tab, Alt+Shift+Tab | switch windows |
| Alt+F4 / F9 / F10 / F11 | close / minimize / maximize / fullscreen |
| Ctrl+Alt+Left/Right, Ctrl+Alt+1–9 | switch desktop |
| Ctrl+Alt+Shift+Left/Right | move window to the next desktop |
| Alt+drag, Alt+right drag | move, resize |

## Configuration

Settings go in `~/.config/mosaic/mosaicrc`, one `key = value` per line:

```
desktops = 4
desktop.names = Main,Web,Code,Misc
terminal = xterm
font = DejaVu Sans:size=9
color.active = #2e4a66
desktop.pattern = tiles
desktop.image = ~/Pictures/wallpaper.jpg
desktop.image.mode = fill   # fill | fit | center | tile
clock.format = %a %d %b  %H:%M
panel.position = top        # or bottom
```
