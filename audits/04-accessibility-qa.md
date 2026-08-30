# Accessibility QA checklist

This checklist covers Islet's expanded island, compact transient content, Home, overflow, and each
activity. The unit tests check policies and deterministic text. They do not prove WCAG conformance
or replace testing with macOS accessibility tools and real displays.

## Setup

- Test both interaction modes, Hover and Click to Pin.
- In System Settings, enable Keyboard Navigation under Keyboard, then enable VoiceOver.
- Run the pass once with Reduce Motion off and once with it on.
- Repeat the visual checks with every Appearance theme and both battery graph styles.
- Use a built-in notched display and an external display if both are available.

## Keyboard

- Expand the island and press Tab repeatedly. Focus should move through Home, visible activity tabs,
  More when present, Quick Actions, Settings, then the selected activity's controls in visual order.
- Open More and confirm every overflow activity can be selected with arrow keys and Return.
- Confirm Command-1 selects Home and Command-2 through Command-9 select the corresponding activity
  when it exists. Use Control-Tab and Control-Shift-Tab to reach every tab beyond Command-9.
- On Now Playing, Timer, Clipboard, Calendar, File Shelf, T3 Code, and iPhone, press
  Command-Return. Confirm the named primary action runs only when one is available.
- In Pulse, Tab to the action menu and open actions from their normal controls. Confirm the keyboard
  path does not skip the destination review and confirmation flow.
- Trigger a HUD, sneak, reminder error, completed timer, or activity error. Escape should dismiss the
  temporary item before affecting anything else.
- Press Command-W. The expanded island should close in both interaction modes.
- Open Quick Actions or a settings text field. Type the island shortcuts and confirm Islet does not
  take them from the editor.
- Confirm Space and Return still activate the currently focused native button or menu item.

## VoiceOver

- Navigate the activity switcher. Each tab should announce its name and selected state. More should
  announce the number of hidden activities.
- Enter Home. Calendar events and reminder rows should announce time, title, and overdue state.
  Complete and Snooze must remain separate actions.
- Check every activity: Battery, Calendar, Clipboard, iPhone, Now Playing, Ports, Pulse, File Shelf,
  System, T3 Code, and Timer. Decorative artwork, charts, sparklines, and animation glyphs should not
  add duplicate stops. Rows must announce their useful value or state before their actions.
- Change volume and brightness. VoiceOver should announce the control name and percentage because
  Islet suppresses the system HUD when its replacement is active.
- Trigger track, timer, battery, connection, and warning sneaks. Each visible transient should have
  one useful live announcement, without reading hidden underlying compact content.
- Verify external links, destructive actions, permission recovery, and empty states have labels that
  describe the result rather than only the icon.

## Reduce Motion

- Enable Reduce Motion before opening Islet. Expansion, closing, tab-size changes, HUD changes, and
  reminder completion should update without springs or scale transitions.
- Trigger every system-event motion profile. The icon and text should appear immediately with no
  bounce, wiggle, pulse, rotation, slide, or scale effect.
- Start playback. The compact equalizer should remain still, while elapsed time and timer countdowns
  continue to update because those values carry information.
- Check a long compact event title. It should truncate instead of scrolling.

## State and contrast

- For each theme, inspect normal, selected, disabled, warning, failed, paused, and completed states.
  Selected tabs and enabled playback modes must have a border, icon, or text cue in addition to color.
- Check Pulse failures and action-required items, overdue reminders, T3 Code connection states,
  thermal pressure, battery charging, low battery, shuffle, repeat, and playing or paused sources.
  Cover each color cue and confirm the adjacent symbol or text communicates the same state.
- In Battery, switch between Coloured and Monochrome. Labels, symbols, percentages, ribbon direction,
  and source or destination placement must remain readable without relying on ribbon color.
- Use Accessibility Inspector's contrast audit on text and controls. Also inspect thin graph strokes
  at normal display brightness. Record the macOS version, display, theme, and state for any failure.
