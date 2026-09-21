# MeetingCurtain

A tiny macOS menu bar app that covers every screen with a full-screen "curtain" shortly before each
meeting in your Google Calendar: meeting name, a big countdown, and a **Join** button for Meet, Zoom,
Teams or Webex.

- Reads your calendar through macOS Calendar (EventKit), so you don't need a Google API key or OAuth.
- Idle cost is close to zero: one timer, no polling, and nothing is drawn until a curtain is due.
- Starts at login and checks itself on a routine, so it keeps working without you having to watch it.

## Setup

1. **Connect Google Calendar to your Mac.** Go to System Settings → Internet Accounts → Add Account → Google,
   sign in and turn on **Calendars**. Check that your events show up in the Calendar app.
2. **Build and install.**
   ```sh
   ./build.sh install
   ```
   This runs the tests, builds a release version, installs it to `~/Applications/MeetingCurtain.app`
   and starts it.
3. **Allow access when macOS asks.** Calendar access (**Allow Full Access**) is required.
   Notifications are optional, for alerts on the lock screen.
4. The Settings window opens on first launch with a **self-check** list. Once every line is green,
   you're done. The menu bar icon (📅 with a clock) is the only visible part.

Needs macOS 14.4 or newer, with Xcode or the Command Line Tools installed.

## How it behaves

| Situation | What happens |
|---|---|
| Meeting in 2 minutes (default, adjustable 0–30 min) | Curtain on every display, sound, display wakes up |
| Mac is locked | Display wakes, a notification appears on the lock screen, and the curtain is waiting after unlock |
| You open the lid / wake the Mac | Immediate check. A meeting that started up to 10 minutes ago still shows (marked **Started +3:05**) |
| Mac was shut down | Starts at login and checks right away |
| Two meetings at once | One curtain, with the second one listed below it |
| Meeting moved or cancelled | Picked up through calendar change notifications; the curtain updates or disappears |
| Full-screen app / other Space | The curtain still covers it |

Keyboard on the curtain: **Return** joins, **S** snoozes 1 minute, **Esc** dismisses.

All-day events are skipped by default. If you turn them on, they are shown once at 9:00. Declined
events are included by default and can be skipped in Settings.

## The self-check routine

The app checks itself at launch, after each wake, every 15 minutes, and when you open Settings.
It checks:

- calendar permission (and resets its calendar cache if permission changes)
- that a Google (online) calendar account is actually synced
- that the next curtain is scheduled ("Next curtain at 14:58 · Standup")
- that the login item is registered, and re-registers it if it has disappeared
- that the app runs from `~/Applications` (a stable path for the login item)
- notification permission and the alert sound

Three minutes before each curtain it also asks macOS to sync Google, so last-minute changes are caught.
Problems turn the menu bar icon into a warning badge. The menu shows each problem with a one-click fix.

## Resource use

- **Idle:** 0% CPU. A single wall-clock timer waits for whichever comes first: the next curtain, the
  pre-meeting sync, or the 15-minute routine check. Its tolerance (up to 90 s) lets macOS batch wake-ups.
- **No rendering while idle:** the menu is built only when you click it. Curtain and Settings windows
  exist only while they're open.
- **No network of its own:** macOS already syncs Google Calendar. The app reads the local copy.
- App Nap is only turned off in the ~3 minutes before a curtain, so it appears on time.

Check with Activity Monitor: CPU 0.0, Energy Impact ≈ 0.

## Troubleshooting

- **Logs:** `log show --last 1h --info --predicate 'subsystem == "com.manu.meetingcurtain"'`
- **Asked for Calendar access again after a rebuild:** with ad-hoc signing (the default) macOS sees
  each build as a new app. Build with a real identity to avoid this:
  `SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build.sh install`
- **Events missing or late:** in Calendar → Settings → Accounts, set Google's *Refresh Calendars* to
  *Every 5 minutes* or *Automatically*.
- **Mac asleep with the lid closed at meeting time:** no app can run then. The curtain appears as soon
  as you open the lid, if the meeting started less than 10 minutes ago.

## Uninstall

Quit from the menu bar icon, turn off launch at login in Settings (or remove it in
System Settings → General → Login Items), then delete `~/Applications/MeetingCurtain.app`.

## Development

```sh
swift test                                   # scheduling and link-detection tests
swift build && .build/debug/MeetingCurtain --render-curtain /tmp/c.png multi   # render the curtain (single|started|multi|nolink)
open Package.swift                           # work in Xcode
```

Code layout:

- `Sources/MeetingCurtainCore`: pure logic (when a curtain is due, finding join links). Unit-tested.
- `Sources/MeetingCurtain`: the app.
  - `MeetingMonitor`: coordinator (timer, refresh, self-check)
  - `CalendarService`: EventKit
  - `CurtainController`/`CurtainView`: full-screen windows
  - `StatusMenuController`: menu bar
  - `HealthMonitor`: self-check
  - `Attention`: sound, display wake, notifications
