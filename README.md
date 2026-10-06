# Desktop Clock

A compact clock and weather widget for the Windows desktop, written in
PowerShell. No installation and no administrator rights needed.

- Date, ISO week number and time (HH:MM:SS)
- Current weather for a city you choose: temperature, feels-like,
  condition and a colour icon (data from [Open-Meteo](https://open-meteo.com/))
- Sits on the desktop behind your windows; wide or stacked layout
- Automatic light/dark text based on your wallpaper
- Remembers city, layout and position, also across monitors
- Optional start at Windows sign-in, optional update check

## Install

1. Open the [latest release](../../releases/latest) and download the zip
   (**Source code (zip)**).
2. Extract it anywhere, for example in Downloads.
3. Double-click **DesktopClock.bat**.
   - If Windows says the file was downloaded from another computer, the
     launcher offers to unblock it. Choose **Y** if you trust it.
   - If it reports that PowerShell scripts are not allowed, see
     *Execution policy* below.
4. On first start the widget installs itself for your account in
   `%LOCALAPPDATA%\DesktopClock\App` and adds **Desktop Clock** to the
   Start menu. From then on it always runs from there, so you can delete
   the downloaded zip and folder.
5. Hover the widget's top-right corner, click the gear and choose
   **Choose city...** (or right-click the widget).
6. Optional: gear -> **Launch at Windows sign-in**.

## Execution policy

Windows does not run PowerShell scripts by default. On a personal PC you
can allow scripts for your own account only (no admin rights needed):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

On a work computer, follow your organisation's rules and ask IT. Do not
bypass a policy set by your organisation.

## Using it

- **Move:** drag the widget.
- **Wide / stacked:** drag the resize grip (bottom-right) or use
  gear -> Size.
- **Settings and close:** hover the top-right corner, right-click the
  widget, or use the tray icon.
- **Refresh weather:** hover the bottom line of the widget to show
  "Updated ..." and click the circular arrow next to it. (The line stays
  visible on its own if the weather is out of date or a refresh failed.)

## Updates

Once a day the widget asks GitHub whether a newer release exists. If so,
it shows **Update to vX.Y.Z...** in its menu and tray icon. Nothing is
installed until you confirm; the previous version is kept as
`DesktopClock.ps1.bak`. Turn the daily check off under gear -> Updates.

## Network and privacy

- Weather: `api.open-meteo.com` every 15 minutes (city coordinates only).
- City search: `geocoding-api.open-meteo.com`, only while searching.
- Update check: this repository's release page on `github.com` once a
  day (can be turned off); updates are downloaded from
  `raw.githubusercontent.com` only after you confirm.

The program copy, settings and a small log are stored in
`%LOCALAPPDATA%\DesktopClock`.
Nothing else is collected or sent.

## Uninstall

Gear -> **Diagnostics** -> **Uninstall Desktop Clock...** removes the
program copy, its settings and its shortcuts.

## License

MIT - see [LICENSE](LICENSE).
