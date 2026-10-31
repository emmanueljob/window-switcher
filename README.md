# Window Switcher

A small native macOS menu bar app that uses Command + Tab to select individual windows across applications.

## Build and run

Requires macOS 13 or later and Apple's Command Line Tools (`xcode-select --install`).

```sh
./scripts/build.sh
open "build/Window Switcher.app"
```

On first launch, allow **Window Switcher** in the system's Accessibility privacy settings. If the app is missing from the list, use the + button and choose `build/Window Switcher.app`. Return to its menu bar menu and choose **Reconnect Keyboard Shortcut** if needed.

## Controls

- Hold Command and press Tab to move forward.
- Hold Command and Shift and press Tab to move backward.
- Release Command to activate the selected window.
- Escape cancels; arrow keys also move the selection while the panel is open.
- The menu bar's **Enable Window Switcher** toggle restores the native app switcher when disabled. Quitting also restores it.

Use **Settings…** in the menu bar to choose Command, Option, Control, or a combination, plus Tab, Space, backtick, a letter, number, or F1–F12. Save applies immediately and persists between launches. Shift reverses the selected shortcut. Restore Default returns to Command + Tab. Other uses of the chosen combination are overridden while the switcher is enabled.

The switcher uses a horizontal translucent strip with large icons. The rounded material has an alpha mask so the outer corners stay transparent. Its background is rendered at 72% opacity while icons and text stay fully opaque. Each window has its own icon; badges distinguish multiple windows from the same app. The selected app name and window title appear below the icons. Long lists scroll horizontally as you cycle. Running apps with no accessible windows appear once and can be activated without creating a window. **Preview Switcher** shows a sample strip that closes on click.

Window titles and icons are shown without capturing screenshots. The app remembers windows focused while it is running. For windows it has not observed, ordering falls back to the frontmost app followed by application name.

## Limits

This is an initial implementation, not a complete Witch replacement. App-provided Accessibility data determines which windows appear. Full-screen windows and windows on other Spaces depend on macOS activation behavior; this app does not force a Space change using private APIs. Browser tabs are not separate entries. No launch-at-login behavior is installed.

Builds are ad-hoc signed for local use. Rebuilding can require granting Accessibility permission again. No networking or telemetry is included.

## Verification

```sh
"build/Window Switcher.app/Contents/MacOS/WindowSwitcher" --self-test
```

This checks forward/reverse selection, wrapping, cancellation, unrelated-key passthrough, the disabled state, and releasing Command before discovery finishes. These checks do not inject keyboard input into other apps. Tests also cover shortcut persistence, modifier combinations, horizontal overflow, and windowless app display. Actual window activation and cross-Space behavior require a manual check after Accessibility permission is granted.

## Files

- `Sources/main.swift`: menu bar app, keyboard interception, window discovery, activation, and panel.
- `scripts/build.sh`: compiles and packages the local `.app` in `build/`.

## Troubleshooting

A connected event tap does not guarantee that keyboard events can reach it. macOS Secure Input prevents keyboard monitoring even when Accessibility is allowed. During local testing, Chrome held Secure Input active after focus left a secure field. A normal Chrome quit and relaunch released it, and Command + Tab events then reached the switcher.

The diagnostic log is `~/Library/Logs/WindowSwitcher/status.log`. It records permission and connection changes and switcher shortcut triggers, without window titles or general keystrokes. Self-tests do not write shortcut events to this log. The menu bar status explicitly reports when Secure Input blocks the keyboard.

## License

Released under the [Unlicense](LICENSE). You may use, modify, distribute, and sell this software for any purpose, without attribution. Provided without warranty.
