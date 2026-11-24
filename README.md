# meetings-bar

The **meetings section** of [MacBar](https://github.com/ainahtokyandry/mac-setup): today's
meetings in the dropdown, one click to join the call, and a notification 30 minutes before each
one starts.

In the menu bar it speaks for one meeting at a time, and only while there is one left today:

```
○ 14:00            the next meeting today
○ in 25m           one starts within 30 minutes, in colour
● until 14:30      one is under way
```

With **Compact Display** off, the meeting's title follows: `○ in 25m Design review`.

In the dropdown the section contributes its own block:

- **Every meeting today**, `14:00–15:00  Design review`. The ones that are over are dimmed, the
  one under way has a dot, and the next shows how long until it starts.
- **Join**: a meeting with a video call reads `…  —  Join Meet` (or Zoom, Teams, Webex, Jitsi,
  Whereby, FaceTime), and clicking it opens the call.
- **Reminder 30 min before each meeting**, or why reminders are not happening.
- **Open Calendar**

The reminder is a macOS notification with the meeting's title and start time. Its **Join**
button, or a click on the notification itself, opens the call.

### Details

- Events are read through EventKit, so every calendar the Calendar app syncs is included —
  Google, iCloud, Exchange — and there is nothing to sign in to here. Add an account under
  **System Settings > Internet Accounts** to have its meetings show up.
- All-day events, cancelled events and events you declined are left out.
- EventKit has no field for a video call, so the event's URL, location and notes are searched,
  in that order, for the address of a known call service. Google puts the Meet link in the notes;
  the "learn more about Meet" link beside it, documents and dial-in numbers are never taken for a
  call.
- A reminder that lies ahead is handed to the system in advance, so it arrives on the minute even
  if MacBar is busy or napping. If MacBar starts, or a meeting is added, after the reminder's
  moment has passed but before the meeting begins, the reminder is posted straight away, once:
  occurrences already reminded are remembered across restarts. A meeting that moves gets a new
  reminder, and the old one is withdrawn.
- The reading updates on the minute, whenever a calendar changes, after the Mac wakes, and when
  the menu opens.
- Switched off under **Sections** in MacBar's dropdown, the section stops reading and withdraws
  every reminder it had scheduled, so nothing arrives while it is off.
- Swift against AppKit, EventKit and UserNotifications. No third-party dependencies.

### Settings

The lead time is a preference of whichever app the section is built into:

```sh
defaults write local.macbar meetingReminderMinutes -int 10    # remind 10 minutes before
defaults write local.macbar meetingReminderMinutes -int 0     # no reminders
defaults delete local.macbar meetingReminderMinutes           # back to 30
```

The same number decides how close a meeting has to be before the menu bar turns it into a
countdown. For the standalone app the domain is `local.meetingsbar`.

### Permissions

The first launch asks for two things, and the section is useless without the first:

- **Calendars**, for reading the events. If it was refused, the section says so and links to
  **System Settings > Privacy & Security > Calendars**.
- **Notifications**, for the reminders. If they are blocked, the dropdown says so and links to
  **System Settings > Notifications**.

The calendar permission is asked for with a usage string from the app's `Info.plist`; without
one macOS refuses access without asking. MacBar's `Info.plist` carries it, and so does this
repository's for the standalone app.

MacBar is signed ad hoc, so macOS may treat a rebuilt copy as a new app and ask for calendar
access again.

## How it fits together

`MeetingsSection.swift` is the whole of it: one class conforming to `BarSection`, the protocol
the MacBar host defines. The host owns the status item, the dropdown, the colours and the date
formatting; this repository owns the meetings and the reminders.

```
MeetingsSection.swift   the section: one BarSection, the calendar, the reminders, its block of the menu
main.swift              a standalone entry point — Host.run(sections: [MeetingsSection()])
build.sh                builds MeetingsBar.app against a MacBar host checkout
Info.plist              bundle metadata for the standalone app, with the calendar usage string
```

There is deliberately **no copy of the host here**. `build.sh` compiles against a checkout of
[mac-setup](https://github.com/ainahtokyandry/mac-setup), found in `MACBAR_HOST`, or beside
this repository, or under `$HOME/Projects`.

The app has a single notification delegate and a single set of notification categories, and
this section takes both. A second section that wants notifications would need them moved into
the host.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (provides `swiftc` and `codesign`):
  ```sh
  xcode-select --install
  ```
- A checkout of [mac-setup](https://github.com/ainahtokyandry/mac-setup), which holds the host

## Usual install

You do not normally build this repository directly. MacBar's installer clones it, together with
the other sections, and builds the one app:

```sh
zsh -c "$(curl -fsSL https://raw.githubusercontent.com/ainahtokyandry/mac-setup/main/install.sh)"
```

With the checkouts already in place, rebuilding MacBar picks up this section from wherever it
sits under `$HOME/Projects`:

```sh
~/Projects/mac-setup/menubar/build.sh /Applications/MacBar.app --run
```

## Building it on its own

Useful when working on the section itself:

```sh
./build.sh --run
```

That yields `MeetingsBar.app`: one section, one menu bar item, no Dock icon. Today's meetings
are also available without the menu bar:

```sh
./MeetingsBar.app/Contents/MacOS/MeetingsBar --print
```

```
Meetings
  ✓ 09:30–10:00  Standup  Meet: https://meet.google.com/abc-defg-hij
  ● 11:00–11:45  Weekly sync  Meet: https://meet.google.com/klm-nopq-rst
    14:00–15:00  Design review  (in 2h 40m)  Zoom: https://us02web.zoom.us/j/81234567890
  Reminder 30 min before each meeting
```

Run from a terminal, `--print` reads the calendars with the terminal's own calendar
permission, not the app's.

## Uninstalling

The standalone bundle is self-contained:

```sh
pkill -x MeetingsBar
rm -rf MeetingsBar.app
defaults delete local.meetingsbar
```

To take the section out of MacBar, remove this checkout and rebuild MacBar.
