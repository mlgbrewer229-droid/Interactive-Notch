# Interactive Notch

A native macOS 26 background app that turns a MacBook camera notch into a compact live-activity surface and hover dashboard.

## What it does

- Keeps the physical notch visually unchanged while idle, then shows a slim artwork/waveform activity while music plays.
- On play/pause changes, the same eight bars ripple left to right into a small transport glyph using a short, low-bounce spring. Play feedback returns to the live spectrum after 300 ms; pause feedback collapses the compact music activity after 300 ms. A quick resume interrupts the pending collapse. Repeated metadata updates do not extend the feedback, and a missing track retains a separate 1.5-second hand-off grace period. Other active timers and hovered dashboards remain open. Reduce Motion switches the glyph without movement.
- Shows a small launch confirmation once per app launch: a short loading stroke morphs into a green checkmark, then returns to the current activity. It takes about 1.5 seconds, respects Reduce Motion, and yields immediately to hover navigation. This confirms the notch has started; media and permission availability keep their own status indicators.
- Slides outward and down from the physical notch after a continuous 200 ms hover, then collapses 300 ms after the pointer leaves.
- Detects the pointer globally in screen coordinates, including over the physical camera cutout.
- Uses a fixed transparent panel and morphs only its black silhouette, preventing the notch from floating below the menu bar.
- Starts with media and calendar on Home. Move the pointer back into the physical notch while Home is open, or choose **Widgets & Settings** from the right-click menu, to open a gallery of Media, Today, Timer, Battery, Weather, and Mirror. Open any preview and check a tile to pin it to Home, up to four. Two widgets sit side by side; three use three equal columns; four use large–stacked pair–large. Pins are saved between launches. Existing Health pins are removed without discarding other choices.
- Move the pointer into the physical notch area from a detail or Mirror to return to its source (Home or the widget gallery). Moving away from the surface still collapses it after 300 ms.
- Lets you play, pause, skip, and go back directly from the home dashboard without opening Media detail.
- Shows a slim, seekable track-progress bar on the home dashboard.
- Lets you select days and move backward or forward through the Calendar directly from the home dashboard.
- Gives every Calendar day a full-cell click target that changes the selected date without leaving Home. The month and event-summary area open Calendar detail. Narrow Home widgets show five nearby dates for comfortable targets; Calendar detail retains its full seven-day strip and week navigation.
- Uses smaller selected-date circles with separate weekday labels so calendar text stays clear in narrow Home layouts and details.
- Zooms each dashboard widget outward from its Home position when opened and back into that position when closed.
- Shows a real eight-band system-audio spectrum whenever media is playing, from 20–47 Hz sub-bass on the left to 8.4–20 kHz treble on the right.
- Shows real upcoming Calendar events after an explicit permission request, including Google calendars connected through macOS Internet Accounts. Calendar detail has a selectable week strip, previous/next week controls, a Today shortcut, and a scrollable event list. The large date rolls smoothly as days change. Clicking the event area tucks the date strip away and gives events more space; clicking the large red date restores it with a short, non-bouncy spring. Reopening Calendar restores the strip.
- Includes persistent 5-, 10-, 25-minute, and custom timers with pause, add-time, cancel, and a completion activity. Timer uses a digital countdown in every Home size and detail; the analog clock and format toggle have been removed. Digits retain directional numeric transitions and a short, non-bouncy spring. Clicking the Home countdown or Timer label opens controls.
- Shows system-wide now-playing artwork, metadata, seeking and playback controls, plus animated battery percentage and estimated time remaining.
- Clicking the album art or title in Media detail opens the reported media source—Music, Spotify, or the browser playing a video. It never defaults to Spotify. If the source is missing or unavailable, it does not open an unrelated app. Browser metadata identifies the browser, not an exact video-page URL.
- Video thumbnails and music artwork use the same fixed square crop in compact, Home, gallery, and detail views; wide or tall artwork cannot overflow the controls.
- Mirror extends the notch to show the front camera. Camera permission is asked only when Mirror is opened; capture stops when Mirror closes.
- Mirror waits for its preview surface before starting capture, preserves the view briefly after the macOS permission sheet closes, and offers a retry button if the camera reports a runtime failure.
- Keeps compact music and timer activities visible when another app is full-screen.
- Uses a pure-black silhouette and system typography, with album-derived media color and semantic red, orange, cyan, and green for calendar, timer, weather, and battery. Battery stays green whether plugged in or not.
- Shows the standard battery symbol, percentage, and a green charge bar in every Home size, including the small stacked widget. Battery detail contains only power status and estimated remaining time; audio-integration troubleshooting remains in the management menu.
- Gives each of the eight frequency bars its own narrow, spaced shape. The most common visible artwork color is used; very dark colors are skipped. New artwork colors crossfade from left to right over three seconds total, independently of the live audio-level movement. The visual fade starts when new artwork arrives; it approximates the configured Spotify crossfade, since the current media integration does not expose the audio crossfade's exact timing. Reduce Motion changes the color immediately.
- Briefly extends the notch into a green charging ring when external power is connected, including at full charge.
- Shows current local conditions and a coming-days forecast after opening Weather and granting location access. Mini daily forecast icons show only the day's high, without low temperatures; hourly icons still show that hour's temperature. Weather uses tight spacing, system symbols, and a sliding blue Liquid Glass Days/Hours selector. Both modes retain the same forecast-row position and cell identities, with animated symbol and temperature changes. Clicking a forecast day on Home or in detail opens its hourly timeline, with previous/next day controls. Today begins at the current hour; future days begin at midnight. Forecast pages fit exactly five columns with safe edge padding, and a horizontal swipe advances one whole page. A partial final page retains empty slots rather than stretching its icons. Use one finger on a Magic Mouse or two fingers on a Mac trackpad. Day/night icons follow forecast daylight data.
- Keeps the area beside the physical notch clear of status text. Widgets & Settings uses a compact two-row gallery with the same footprint as detail views, so selecting a lower-row preview does not trigger hover collapse. Each entire tile opens its preview, including its icon and padding; the pin button is a separate sibling control. Gallery and date buttons use subtle press feedback, and the fog symbol combines a smaller cloud with horizontal mist instead of rain-like marks.
- Uses restrained, interruptible spring motion with a slight overshoot and staggered detail reveals.
- Honors Reduce Motion for custom press feedback, transport glyphs, and numeric countdown changes. Seeking and volume sliders support VoiceOver adjustment, and interrupted mouse drags release hover-collapse holds.
- Covers menu-bar items inside the expanded top-center surface while leaving the rest of the menu bar untouched.
- Follows the built-in display across Spaces and full-screen apps.
- Runs without a Dock or menu-bar icon.
- Opens its management menu with a right-click on the notch or `Control–Option–Command–N`.

- Shows volume feedback only while the notch is already expanded: a speaker, slim animated bar, and percentage beside the physical notch. The fill follows changes with a short, non-bouncy spring; the readout gently slides and fades in/out and expires 1.25 seconds after the last change. Closing immediately clears it; reopening never replays changes made while closed. Music, timers, and widget layouts are untouched. Reduce Motion uses near-instant fades. The native macOS volume HUD is not suppressed.

## Run it

Open `outputs/InteractiveNotch-4.18.dmg`, drag InteractiveNotch into Applications, and launch it there. Xcode is not required for this installation. The DMG contains version 4.18 (build 45), an Applications shortcut, and installation notes. Its app and embedded framework pass code-signature verification with the available Apple Development certificate, but Gatekeeper rejects this build for normal public distribution: Developer ID signing and notarization are still required. Downloaded copies may need explicit approval in Privacy & Security.

For development, open `InteractiveNotch.xcodeproj`, select the **InteractiveNotch** scheme and **My Mac**, and press **Run**. Quit any older copy first; an old Xcode build can remain running even after the project is updated. Do not run a numbered duplicate such as `InteractiveNotch 6.app` at the same time; its invisible panel can overlap the current app and intercept clicks.

The management menu opens the **Widgets & Settings** gallery and also contains **Launch at Login**, **Restart Media Integration**, **Restart Audio Spectrum**, **System Audio Recording Settings**, and **Quit Interactive Notch**. Launch at Login remains off until enabled.

The first time music plays in the signed app, macOS asks for **System Audio Recording** access. Grant it once, then use **Restart Audio Spectrum** if the app was already open. Keep using the same signed app in Applications; an ad-hoc Xcode build has a different privacy identity. To launch the notch after a full Mac restart, enable **Launch at Login** in its management menu.


## Test it

Use **Product → Test** in Xcode, or run:

```sh
xcodebuild test -project InteractiveNotch.xcodeproj -scheme InteractiveNotch -destination 'platform=macOS'
```

The suite includes exact playback-feedback timing, repeated snapshots, rapid pause/resume interruption, track hand-off grace, timer activity preservation, eight-bar glyph bounds, calendar navigation without leaving Home, hourly-summary selection and page bounds, stale-date recovery, digital countdown rounding, invalid-time handling, interrupted drag recovery, widget selection limits, timer restoration, 200/300 ms hover timing, media mapping, and eight-band frequency analysis. Native layout snapshots cover the four-widget Home, gallery, and Calendar/Timer/Battery/Weather details. Test fixtures do not request camera, Calendar, location, or audio permission and keep preferences isolated.

For live acceptance on this Mac, quit old copies, run the current app, and check: play briefly forms a play glyph before waving, pause forms a pause glyph and collapses, and rapid resume never hides an active spectrum; mini forecasts show only daily highs; Timer is digital in large/small layouts; Home days change in place while the month/events open Calendar; Hours shows “Now” on its first page and the visible hour on later pages rather than the daily high; Battery has no audio diagnostics; hover collapse still works after seeking; and music/camera/timers recover through sleep, wake, Spaces, and full-screen transitions. Passing tests and layout snapshots do not substitute for these hardware checks. This remains a personal local app, not an Apple-certified or App Store release.

The brief transport ripple follows the restrained approach in [Apple's motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion), using a [native duration/bounce spring](https://developer.apple.com/documentation/swiftui/animation/spring(duration:bounce:blendduration:)) rather than a separate overlay or looping decoration. The same bar identities and geometry allow an interrupted play/pause transition to redirect in place.

## Implementation notes

- The app targets Apple silicon and macOS 26 or newer.
- Calendar data stays local. macOS asks for full event access only when Today is first opened. Google Calendar is read through the Google account configured in macOS, so the app does not handle Google credentials.
- Weather asks for location only when Weather is explicitly opened. It uses MapKit to show the nearby city; approximate coordinates rounded to two decimal places are sent to [Open-Meteo](https://open-meteo.com/) over HTTPS for a forecast. The app does not save location history. Weather data © Open-Meteo, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). An internet connection is required.
- The signed app includes Hardened Runtime entitlements for Camera, Location, and Calendar. These allow macOS to present the corresponding consent prompts; they do not grant access without your approval. If you previously denied access, enable it in System Settings → Privacy & Security → Camera or Location Services.
- The compact visualization uses Apple’s Core Audio process-tap API and keeps all analysis on-device. The audio callback only copies samples into a preallocated buffer; frequency analysis runs on a separate queue.
- The frequency bars follow audio produced on this Mac; song metadata can also arrive from an iPhone, but audio played through AirPods connected to the iPhone is not available to the Mac's process tap.
- The tap and aggregate device are fully rebuilt after wake, output-device changes, and sample-rate changes. Transient capture failures get three bounded retries; permission failures are not automatically retried, preventing prompt loops.
- The now-playing helper is recreated after wake and automatically relaunches after an unexpected exit. A one-shot read at launch and periodic reconciliation recover playback when MediaRemote's notification stream misses its initial or post-wake state.
- Release bundles use the configured Apple Development team and Hardened Runtime so macOS can retain System Audio Recording permission for the app’s stable team-and-bundle identity.
- During trackpad Space swipes, the panel briefly reasserts its shielding level so compact and expanded activities remain attached to the active display.
- Apple does not provide a public API for reading or controlling Clock timers. The Timer detail can open Clock, but its persistent countdown remains independent.
- MediaRemote is a private Apple framework. Access is isolated behind a provider so a missing or changed symbol leaves the rest of the notch functional instead of crashing.
- The app has no analytics or media history. Weather is its only direct network feature. It bundles the BSD-licensed MediaRemote Adapter source and builds it as an embedded framework; no Homebrew package or separate runtime installation is required.
- App Store distribution is not supported because of the private MediaRemote integration.

### Why the helper exists

macOS 15.4 and newer reject direct third-party reads from MediaRemote with `Operation not permitted`. Interactive Notch therefore launches the bundled adapter through Apple’s `/usr/bin/perl` process and consumes its local JSON stream. The app does not request or fake Apple-private entitlements. Adapter attribution and license terms are included in `Vendor/MediaRemoteAdapter/LICENSE` and in the built app’s resources.
