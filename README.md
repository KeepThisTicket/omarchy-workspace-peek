# Workspace peek for Omarchy

An overlay for the [Omarchy](https://omarchy.org) shell that shows live previews of all
your workspaces at once, so you can see what's on each one without switching to it.

- **Every occupied workspace**, plus the one you're on, plus the scratchpad when it holds
  windows, laid out in a grid sized to fit your screen.
- **To scale**: each window is drawn where it actually sits on its monitor, with floating
  and fullscreen windows on top.
- **Live**: previews keep updating while the overlay is open, including windows on
  workspaces you aren't looking at.
- **Jump**: click a workspace to go there, or click a window to focus it.
- **Keyboard**: `1`–`9` (and `0` for 10) go to that workspace, the arrows / `h j k l` /
  Tab move the selection, Enter goes there, Esc or `q` closes.
- Hover a window to see its title.

## Install

```sh
omarchy plugin add https://github.com/KeepThisTicket/omarchy-workspace-peek.git --enable
```

Then bind a key to it in `~/.config/hypr/bindings.lua`, for example Super + A:

```lua
o.rebind("SUPER + A", "Workspace peek", { panel = "kov.workspace-peek" })
-- Optional: open instantly instead of fading in.
hl.layer_rule({ match = { namespace = "^kov-workspace-peek$" }, no_anim = true, animation = "none" })
```

Pressing the key again closes it. Without a binding, open it with
`omarchy-shell shell toggle kov.workspace-peek`.

Update later with `omarchy plugin update kov.workspace-peek`.

## Requirements

- Omarchy with its Quickshell-based shell and plugin support.
- Hyprland with its Lua config (the `hl.dsp.*` dispatchers), as shipped by current Omarchy.
- A compositor that supports toplevel capture, so Quickshell's `ScreencopyView` can
  capture windows. Hyprland does.

## How it works

Window geometry comes from `hyprctl clients -j`, refreshed on every Hyprland event while
the overlay is open. Each window's picture is captured with Quickshell's `ScreencopyView`
on its Wayland toplevel, so windows on hidden workspaces render too. Captures only run
while the overlay is open.

## License

MIT
