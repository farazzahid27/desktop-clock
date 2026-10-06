# Desktop Clock & Weather

A clean clock and current-weather widget that sits on your Windows desktop,
behind your other windows, like part of the wallpaper.

It runs on Windows PowerShell 5.1, which is built into Windows 10 and 11.
There is nothing to install system-wide and no administrator rights are needed.

## Features

- **Clock:** time with or without seconds, 24- or 12-hour format, date and week
  number.
- **Current weather:** temperature (°C or °F), "feels like" temperature and
  conditions for the city you choose, refreshed every 15 minutes. Cities in Finland use
  data from the Finnish Meteorological Institute (FMI); all other cities use
  Open-Meteo.
- **Wind and humidity:** current wind speed (m/s) and relative humidity.
- **Animated weather icons:** sun, moon, clouds, rain, snow, thunderstorms and
  fog move gently. Rain and snow follow the real precipitation amount, and the
  wind and humidity symbols follow the real values. Animations can be turned
  off.
- **Layouts:** wide or stacked, or the clock or weather on its own.
- **Automatic contrast:** switches between light and dark text based on the
  wallpaper behind the widget. Light and dark can also be set by hand.
- **Remembers its place:** position per layout and per monitor, and it returns
  to its monitor when the monitor is reconnected.
- **Automatic updates:** new versions install in the background.

## Download

**[Download Desktop Clock & Weather](https://github.com/farazzahid27/desktop-clock/releases/latest/download/DesktopClockWeather.zip)**

## Installation

1. Unzip the download.
2. Run the included `.bat` file.

The widget installs itself for your account only and starts right away. You
can delete the downloaded files afterwards.

To start the widget again later, use **Desktop Clock & Weather** in the Start
menu. To start it automatically, right-click the widget and choose
**Launch at Windows sign-in**.

## Getting started

Right-click the widget and choose **Choose city**, search for your city and
select it. The weather appears within a few seconds.

Drag the widget to move it. Drag the small corner at the bottom right to
switch between the wide and stacked layouts.

## Settings

Right-click anywhere on the widget, or use the gear button that appears in its
top-right corner:

| Menu item | What it does |
| --- | --- |
| Choose city | Search for and select the city for the weather |
| Refresh weather | Fetch the weather right now |
| Appearance | Auto (follows the wallpaper), Light or Dark |
| Background opacity | How visible the widget's background is |
| Show | Clock and weather, clock only, or weather only |
| Layout | Wide or stacked |
| Time | Show seconds, 24-hour clock |
| Temperature unit | Celsius (°C, the default) or Fahrenheit (°F) |
| Animate weather icons | Turn icon animations on or off |
| Keep on monitor | Choose which monitor the widget stays on |
| Launch at Windows sign-in | Start the widget automatically |
| Show in Start menu | Add or remove the Start menu entry |
| Updates | Check now, or turn automatic updates on or off |
| Diagnostics | Technical information, the settings folder, and uninstall |
| Close widget | Close the widget until you start it again |

The widget also has an icon in the notification area (system tray).
Left-click it to bring the widget to the front for 5 seconds; right-click it
for settings and to close the widget.

## Updates

The widget checks for a new version once a day and installs it
automatically, then shows a short notification about what changed. Your
settings, city and position are kept.

You can check right away, or turn automatic updates off, under
**Updates** in the right-click menu. Each update keeps the previous version as
a backup in the program folder.

## Privacy

Desktop Clock & Weather does not collect, store or send any personal
information, and it contains no tracking or analytics.

It connects to the internet only for:

- **Weather:** the coordinates of the city you choose are sent every
  15 minutes to get the current weather: to the
  [Finnish Meteorological Institute (FMI)](https://en.ilmatieteenlaitos.fi/open-data)
  for cities in Finland, and to [Open-Meteo](https://open-meteo.com) for all
  other cities (and for Finnish cities if FMI cannot be reached). City
  searches are sent to Open-Meteo.
- **Updates:** once a day it checks this GitHub repository for a new version
  and, if there is one, downloads it from GitHub.

Your settings stay on your own PC, in `%LOCALAPPDATA%\DesktopClock`.

GitHub shows the project owner how many times the download file has been
downloaded, as a single total. No information about who downloaded it is
available to the owner.

## For IT administrators

- Installs per user in `%LOCALAPPDATA%\DesktopClock`. No administrator rights,
  services, scheduled tasks or system-wide changes are needed. Shortcuts are
  only created in the user's own Start menu and, if the user chooses, the
  user's Startup folder.
- Automatic updates can be turned off for all users of a PC with this registry
  value:

      HKLM\Software\Policies\DesktopClock
      DisableAutoUpdate (DWORD) = 1

  The same value under `HKCU` turns them off for one user. Users are then told
  when a new version is available, but nothing is installed.
- If your organisation enforces signed scripts or restricts PowerShell
  (for example Constrained Language Mode), the widget does not try to work
  around it. It stops or skips updates and tells the user instead.
- Network access: `opendata.fmi.fi` (weather for cities in Finland),
  `api.open-meteo.com` and `geocoding-api.open-meteo.com` (weather elsewhere
  and city search), `github.com` and `raw.githubusercontent.com` (update
  check and download). The system proxy is used.

## Uninstall

Right-click the widget and choose
**Diagnostics → Uninstall Desktop Clock & Weather**. This removes the program,
its settings, its log and its shortcuts.

## Troubleshooting

**"The file is not digitally signed" or "running scripts is disabled".**
Windows blocks scripts downloaded from the internet. In PowerShell, in the
folder with the downloaded files, run:

    Unblock-File .\DesktopClock.ps1

If it still does not run, your organisation may restrict PowerShell scripts.
Please ask your IT team rather than trying to work around it.

**The weather does not load.** Check that a city is chosen and that your
network allows access to `open-meteo.com` (and `opendata.fmi.fi` for cities
in Finland). The line under the weather shows
when the last update succeeded; hover over it for details.

**Something else.** Right-click the widget, choose
**Diagnostics → Open settings and log folder**, and include `widget.log` when
you report the problem in this repository's Issues.

## Credits

Weather data for cities in Finland: Finnish Meteorological Institute (FMI)
[open data](https://en.ilmatieteenlaitos.fi/open-data), licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

Weather data for other cities and city search: [Open-Meteo.com](https://open-meteo.com),
licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## License

See the [LICENSE](LICENSE) file in this repository.
