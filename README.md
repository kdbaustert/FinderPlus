<p align="center">
  <img src="Resources/Icon/AppIcon-1024.png" alt="FinderPlus app icon" width="160" height="160">
</p>

# FinderPlus

A file search app for macOS, in the spirit of EasyFind, with a Liquid Glass interface. It searches
the disk **live, without Spotlight's index**, so it finds what Spotlight skips: hidden files, system
files, and anything that was never indexed. Runs on macOS 26 and later.

> [!NOTE]
> FinderPlus is at the very beginning of development. Features and behavior may change from one
> version to the next.

## Features

### What to search

- File and folder **names**, file **contents**, Finder **tags** and Finder **comments** — any
  combination; an item matches when any ticked field does.
- Files and folders, only files, or only folders.
- Contents covers plain text and source code, PDF, RTF, Word (`.doc`, `.docx`) and OpenDocument
  text. Files with unknown extensions are read if they look like text.

### How to match

- **All Words**, **Any Word**, **Phrase**, **Wildcards** (`*.pdf`, `IMG_????`),
  **Boolean + Wildcards** (`*.pdf OR *.docx NOT *draft*`, also `&`, `|`, `!`) and
  **Regular Expressions**.
- `"quoted phrases"` and `-excluded` words in the word modes.
- Ignore case, ignore accents (é = e), whole words only.
- **Fuzzy** matching that tolerates a typo in longer words, counting a swapped pair of letters as a
  single typo.

### Where to search

- A folder you choose (⌘L), or the folder shown in the **active Finder window**.
- **All volumes**, **local volumes**, **removable volumes**, a single drive, or iCloud Drive.
- Home, Desktop, Documents, Downloads and Applications, plus any folders you add — drop a folder
  on the options panel to add it.
- Choose whether to include package contents, invisible files, applications, and system folders
  such as `/System` and `/Library`.

### Results

- Results stream in while the search runs, already sorted; sort by name, location, kind, size or
  date.
- Each result shows its **location**; content searches show the matching text with the match
  highlighted.
- Open, Show in Finder, Quick Look, Copy Path, Share and Move to Trash — from the toolbar, the
  context menu or the keyboard. Drag results into other apps.
- A live count of matches and items scanned, and a shortcut to Full Disk Access when some folders
  couldn't be read.
- Recent searches, one click away in the search field.

### Interface

- Liquid Glass throughout: a glass toolbar, a floating options panel and results panel over a
  translucent window.
- Searches start only when you press **Find** — nothing runs while you type or change options.
- A new search in the same place narrows the results already on screen instead of blanking them.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Focus the search field | ⌘F |
| Find | Return or ⌘↩ |
| Stop the search | ⌘. |
| Choose a folder to search | ⌘L |
| Show or hide the options panel | ⌃⌘S |
| Move from the search field into the results | ↓ |
| Open | ⌘O or double-click |
| Show in Finder | ⌘R |
| Quick Look | Space or ⌘Y |
| Copy path | ⌥⌘C |
| Move to Trash | ⌘⌫ |

## Permissions

FinderPlus needs no special permission to start. macOS asks for access the first time a search
reaches your Desktop, Documents or Downloads folder, or a removable or network volume. Searching
the **Active Finder Window** asks once for permission to control Finder.

To search everywhere — including other users' folders and protected system locations — grant
**Full Disk Access** in System Settings → Privacy & Security. The status bar counts the folders a
search couldn't read and opens that setting when clicked.

## Privacy

FinderPlus makes no network requests: no telemetry, analytics, crash reporting or account.
Everything it reads stays on your Mac. Content searches skip iCloud files that aren't downloaded,
so searching iCloud Drive never downloads your files.

## Building

```sh
./build.sh --install  # builds build/FinderPlus.app, copies it to /Applications and launches it
swift test            # the test suite
```

Building needs Xcode. To change the app icon, edit `Resources/Icon/make-icon.swift` and run
`swift Resources/Icon/make-icon.swift` from the repository root before building.

## License

FinderPlus is licensed under the [GNU General Public License v3.0](LICENSE).

Built by [@kdbaustert](https://github.com/kdbaustert).
