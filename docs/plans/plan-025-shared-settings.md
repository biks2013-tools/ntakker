# plan-025: one settings file for ntakker, ntakker-cli and ntakker studio

Request (2026-10-17): "can you expose them through ui — can you unify ntakker, cli and ntakker-studio settings - make them to use the same file?"
Decisions with the user: one shared Settings in each app (every shared setting, grouped); real settings only in the file — UI state (window sizes, expanded sections, appearance, last tab, privacy acknowledgements, next basename) stays per-app.

## Design

- **The file:** `~/.tool-agents/ntakker/.env`, read and written by all three. The CLI's own `~/.tool-agents/ntakker-cli/.env` is merged in once (keys the shared file lacks) and no longer read. The CLI's precedence is unchanged: flag > `./.env` > shared file > shell.
- **Keys** (CLI names where one exists):

  | Key | Was (app preference) | Meaning |
  |---|---|---|
  | `NTAKKER_RECORDINGS_DIR` | `com.ntakker-cli.ui.outputFolder`, studio `studio.libraryFolder` | Where ntakker saves and the studio reads recordings (convo-coach's name). |
  | `NTAKKER_FORMAT` | `…ui.format` | m4a / wav / caf |
  | `NTAKKER_LAYOUT` | `…ui.layout` | mixed / split / stereo-split |
  | `NTAKKER_MIC_DEVICE` | `…ui.micUID` (`__default__` → unset) | Mic device UID; unset = system default |
  | `NTAKKER_MIC_AEC` | `…ui.micAEC` | Mic echo cancellation while recording |
  | `NTAKKER_TRANSCRIBE` | `…ui.transcriptionEnabled` + `…ui.transcribeProvider` | Provider id, or `none` = off |
  | `NTAKKER_TRANSCRIBE_SOURCE` | `…ui.transcribeSource` | |
  | `NTAKKER_TRANSCRIBE_FORMAT` | `…ui.transcriptFormat` | |
  | `NTAKKER_TRANSCRIBE_LANGUAGE` | `…ui.transcribeLanguage{,2,3}` | Comma-separated list |
  | `NTAKKER_STUDIO_ECHO_STRENGTH` / `_SUPPRESSION` / `_ADAPTATION` | studio `studio.echo.*` | Studio echo filter |

  Provider keys and `NTAKKER_ASK_*` etc. are already in the file.
- **Store:** `SharedSettingsStore` (observable, one per app) over the file, watching its folder so a change by another app or by hand shows up at once; `@SharedSetting` property wrapper replaces `@AppStorage` for the keys above.
- **Migration:** once per app, values from the app preferences are copied into the file for keys the file does not have.
- **UI:** a new library `NtakkerSettingsUI` holds the row helpers and the provider / Ask panes (moved from the ntakker app), new Recording, Transcription and Studio panes, and `SharedSettingsView`, embedded by both apps' Settings windows with their app-specific panes alongside.

## Tasks

- [x] T1 Core: `SharedSettings` (file location, key names, migrations); CLI reads the shared file and merges its old file once.
- [x] T2 `NtakkerSettingsUI`: store + `@SharedSetting`, moved panes, new panes, `SharedSettingsView`.
- [x] T3 ntakker: `@AppStorage` → `@SharedSetting` for the keys above; preference migration; Settings window uses the shared view.
- [x] T4 Studio: library = `NTAKKER_RECORDINGS_DIR`, echo settings in the file, Settings window uses the shared view.
- [x] T5 Tests, docs (tool docs, configuration, design), build, live check.

## Result (2026-10-17)

- All five tasks done. Tests: 3 core (adopt, CLI-file merge, app-preference mapping accepted by the CLI resolver) + 1 studio (echo settings round-trip); full suite: only the 5 known failures.
- Live: the studio's Settings window shows the shared panes; the recordings folder was carried into the file (only that key was added; every other value unchanged, mode 600). A hand edit of the file appeared in the open window within a second — after fixing the watcher, which first watched only the folder and missed in-place edits.
- Seen once: a hand-appended line was lost; most likely two writers racing (read-modify-write). Registered.

