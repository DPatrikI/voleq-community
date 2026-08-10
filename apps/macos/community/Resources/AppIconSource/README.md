# VolEq App Icon Sources

These first-party branding files and their generated outputs are not licensed
under MPL-2.0. `TRADEMARKS.md` records their copyright, the narrow permission
for unmodified official Community builds, and the restrictions on other use.

These two source layers come from the original VolEq Android application owned
by the VolEq project author:

- `voleq-mark.png` is the shared adaptive-icon foreground from
  `app/src/main/res/mipmap-xxxhdpi/ic_launcher_foregrounderer.png`.
- `premium-background.png` is the paid-flavor adaptive-icon background from
  `app/src/paid/res/mipmap-xxxhdpi/ic_launcher_backgrounderer.png`.

The original Android paid flavor overrides only the background, so these layers
together are the source of the current VolEq icon.
`scripts/generate-macos-icon.swift` composes them into a
macOS rounded-square icon without generative edits or changes to the mark or
colors. The generated `.icns` is the system application icon and supplies the
in-window brand mark through `NSApplication`. The generated PNG is an
alpha-preserving monochrome adaptation of the same foreground for native
light/dark menu-bar rendering. The application sets its intrinsic size to 18 by
18 points before passing it to `MenuBarExtra`; a regression test protects that
native status-item metric.

The generated filenames are declared once in `Resources/Info.plist`; the app,
generator, tests, and packaging script consume that resource contract.

Regenerate all derived assets from the repository root:

```sh
swift scripts/generate-macos-icon.swift
```

The command writes only the declared generated resources and a temporary
iconset directory under `.build` used by Apple's `iconutil`.
