# kopad

Gamepad control for KOReader: structured sentence/word navigation for reading with a game controller.

Requires a gamepad connected via SDL3 (the desktop emulator, or any KOReader
build that uses the SDL frontend).

## Install

Copy the `kopad.koplugin/` directory into KOReader's `plugins/` folder:

```bash
git clone https://github.com/sypianski/kopad
cp -r kopad/kopad.koplugin ~/.config/koreader/plugins/
```

Restart KOReader. Enable in *Settings → More tools → kopad → Enable kopad*.

### SDL3 gamepad patch

KOReader's SDL3 frontend doesn't expose the right stick or shoulder buttons
by default. Apply `sdl3_gamepad.patch` to `ffi/SDL3.lua` in the KOReader
source tree to map them:

```bash
cd /path/to/koreader
patch -p1 < /path/to/kopad/sdl3_gamepad.patch
```

## Controls

### Reading mode (kopad enabled, no overlay)

| Input          | Action        |
|----------------|---------------|
| LT / RT        | Page back / forward |
| L-stick        | Opens sentence selector |
| Y              | Open menu     |
| A              | Confirm / tap |
| B              | Back / close  |

### Sentence selection (L-stick opens overlay)

| Input          | Action                              |
|----------------|-------------------------------------|
| L-stick ↕      | Jump to prev / next paragraph       |
| L-stick ←→     | Move sentence selection             |
| X              | Toggle extend mode (→↓ extend, ←↑ trim) |
| R-stick        | Enter word mode (first input selects word 1) |
| Y              | Dictionary (single word) or AI (multi-word) |
| A              | Action menu (dictionary, copy, highlight, note, AI) |
| B              | Close overlay                       |

### Word mode (R-stick active)

| Input          | Action                              |
|----------------|-------------------------------------|
| R-stick ←→     | Move word cursor                    |
| R-stick ↕      | Jump to word on line above / below  |
| X              | Toggle word extend mode             |
| Y              | Dictionary lookup                   |
| A              | Action menu                         |
| B              | Close overlay                       |

## Cross-page sentences

Sentences that span a visual page break are automatically completed in both
directions. The status bar shows ↑ when the selected sentence continues from
the previous page, and ↓ when it extends past the current page. Copy,
highlight, and dictionary actions operate on the full sentence text regardless
of what's visible on screen.

## Layout

```
kopad.koplugin/
├── _meta.lua        plugin manifest
├── main.lua         umbrella plugin: loads sub-controllers
├── padnav.lua       gamepad key mapping + reading/selection controls
├── selector.lua     two-layer overlay (structured modes)
└── wordsource.lua   CRengine word/sentence collection (shared with keyreader)
```

## Other files

- `sdl3_gamepad.patch` — patches KOReader's SDL3 frontend to expose right
  stick, shoulder buttons, and triggers as key events.
- `selection_analysis.py` — design analysis script: simulates a realistic
  book page and calculates average button presses needed to select arbitrary
  text spans with the two-layer interaction model.

## License

MIT.
