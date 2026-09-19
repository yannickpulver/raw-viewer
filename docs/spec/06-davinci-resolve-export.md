# 06 — DaVinci Resolve Export

Source module: `resolve_export.py`, triggered from `viewer.py:2104`.

---

## 1. Read this first if you are rewriting in Swift

DaVinci Resolve's scripting API is exposed **only to Python 3 and Lua**. There
is no C, Objective-C or Swift binding. The connection works by importing a
Python module (`DaVinciResolveScript`) which dynamically loads a native library
(`fusionscript.so`) that speaks Blackmagic's own IPC protocol to the running
Resolve process. The protocol is undocumented.

A Swift rewrite has four options. **D is the recommended one.**

| Option | How | Trade-off |
|---|---|---|
| A. Shell out to Python | Bundle or locate a Python 3, write a generated script to a temp file, run it with the Resolve env vars set | Keeps the exact current behaviour. Requires Python on the user's machine or a bundled interpreter, which re-introduces the dependency and code-signing pain the rewrite is meant to escape. |
| B. `dlopen` `fusionscript.so` directly | Load the dylib from Swift and call its exported symbols | The exported API is a Python C extension entry point, not a clean C API. Not practical. |
| C. Export a CSV, let the user import it | Write a CSV with a `File Name` column plus metadata columns, tell the user to run `File > Import Metadata To > Media Pool` | No dependency, works in the free version of Resolve. Loses clip colours and flags entirely (see section 8). Adds a manual step. |
| **D. Run a Lua script through Resolve's own `fuscript`** | Ship one `.lua` file as an app resource. Spawn Resolve's bundled interpreter with `Process`, pass the project name and a path to a JSON or line-based job file as arguments, read progress and the result from stdout. | Full feature parity with today (colours, keywords, Good Take). **No Python, no bundled interpreter, nothing extra to sign.** The interpreter is part of every Resolve install. Same Studio-only limitation as today. |

### Option D in detail

Resolve ships a standalone script interpreter inside its app bundle:

```
/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript
```

Invocation:

```sh
fuscript -l lua /path/to/export.lua <arg1> <arg2> ...
```

Verified on 2026-09-19 against the Resolve install on the author's machine,
with Resolve **not** running:

| Check | Result |
|---|---|
| `fuscript` exists next to `fusionscript.so` and is executable | yes |
| Runs a plain Lua file from outside Resolve | yes, Lua 5.1, exit code 0 |
| Script arguments arrive in the global `arg` table (`arg[1]`, `arg[2]`, ...) | yes |
| `bmd.scriptapp` and `Resolve` are predefined functions | yes |
| `bmd.scriptapp("Resolve")` when Resolve is not running | returns `nil` immediately, no hang, no error |

**Not verified:** a live connection to a running Resolve Studio and the actual
API calls from Lua. The Lua API is the same object model as the Python one
documented in the rest of this file. Method calls use a colon instead of a dot
(`resolve:GetProjectManager()`, `mediaPool:ImportMedia({...})`,
`clip:SetClipColor("Green")`). The rewrite agent must test this end to end with
Resolve Studio open before calling the feature done.

Mapping from the current Python flow:

| Python today | Lua under `fuscript` |
|---|---|
| Add module path to `sys.path`, set `RESOLVE_SCRIPT_API` / `RESOLVE_SCRIPT_LIB`, `import DaVinciResolveScript` (section 2) | Not needed. `fuscript` finds `fusionscript.so` itself. Only the `fuscript` path must be located. |
| `dvr.scriptapp("Resolve")` returning `None` means Resolve is not running or external scripting is off (section 3) | `bmd.scriptapp("Resolve")` returning `nil`, same meaning. Print a marker line and exit non-zero so Swift can show the same message. |
| Python lists of paths and dicts of metadata | Lua tables. Pass the file list and ratings in via a job file, since argv gets long for a full shoot. Lua 5.1 has no JSON parser built in, so use a trivial line format (`rating<TAB>absolute path` per line) or embed a tiny parser. |
| Progress and result strings returned to the UI thread | `print()` lines on stdout, parsed by Swift. Flush with `io.stdout:flush()` after each line. |

If `fuscript` is missing (non-standard install location, or a future Resolve
drops it), fall back to option C and say so in the UI.

Whichever is chosen, the rating → colour / keyword / Good Take mapping in
section 4 is the user-visible contract and must not change.

---

## 2. Locating Resolve

`is_resolve_installed()` requires **both** of these to exist
(`resolve_export.py:52`):

| Thing | Exact path checked | Source |
|---|---|---|
| Scripting modules directory | `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules/` | `resolve_export.py:33` |
| Native library file | `/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so` | `resolve_export.py:44` |

Both are written as single-entry `candidates` lists, so adding alternative
install locations later is trivial, but today only these two paths are checked.
A non-default install location is not found.

---

## 3. Connecting

`_connect_to_resolve()` (`resolve_export.py:57`):

1. Set the process environment variable `RESOLVE_SCRIPT_API` to the modules
   directory's grandparent, i.e.
   `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/`.
   Note: the path ends with a trailing slash, so `Path(...).parent.parent`
   climbs one level less than the literal path suggests. From
   `.../Developer/Scripting/Modules/` the parents are `.../Scripting/Modules`
   then `.../Scripting`. So `RESOLVE_SCRIPT_API` is actually set to
   `.../Developer/Scripting`, not `.../Developer`. Blackmagic's own
   documentation says it should be the `Developer/Scripting` directory, so this
   is correct — but it is correct by accident of the trailing slash. Note:
   fragile.
2. Set `RESOLVE_SCRIPT_LIB` to the `fusionscript.so` path.
3. Prepend the modules directory to `sys.path` if not already there.
4. `import DaVinciResolveScript` and call `scriptapp("Resolve")`.
5. Any exception returns `None`.

`_launch_resolve()` (`resolve_export.py:76`): if
`/Applications/DaVinci Resolve/DaVinci Resolve.app` is a directory, run
`open -a "DaVinci Resolve"` and return `True`; otherwise `False`.

---

## 4. Rating mapping

The contract. From `resolve_export.py:13` and `:21`.

| Rating | Clip colour | Keywords | Good Take | Comments | Description |
|---|---|---|---|---|---|
| 1 | `Blue` | `1star` | no | `Rating: 1/5` | `★☆☆☆☆` |
| 2 | `Teal` | `2stars` | no | `Rating: 2/5` | `★★☆☆☆` |
| 3 | `Yellow` | `3stars` | no | `Rating: 3/5` | `★★★☆☆` |
| 4 | `Orange` | `4stars` | **yes** | `Rating: 4/5` | `★★★★☆` |
| 5 | `Green` | `5stars,keeper` | **yes** | `Rating: 5/5` | `★★★★★` |
| 0 or -1 | untouched | untouched | no | untouched | untouched |

The keyword string is passed verbatim, so a 5-star clip gets the single
comma-separated string `5stars,keeper` with no space after the comma
(`resolve_export.py:26`).

"Good Take" is set with `clip.SetMetadata("Good Take", "true")` — a two-argument
call, separate from the batch `SetMetadata` dict
(`resolve_export.py:189`).

Colour and metadata are set only when `rating > 0`, so unrated and rejected
clips are imported but left completely unmarked (`resolve_export.py:172`).

---

## 5. Export flow

`export_to_resolve(files, ratings, all_files, folder_name, on_status)`
(`resolve_export.py:85`). Runs entirely on a background thread
(`viewer.py:2129`); status strings are pushed to the UI through a signal.

| Step | Status text shown | Failure result |
|---|---|---|
| Check installation | — | `"DaVinci Resolve not found.\nRequires Resolve Studio (paid) for scripting."` |
| Connect | `"Connecting to DaVinci Resolve..."` | falls through to launch |
| Launch if not connected | `"Launching DaVinci Resolve..."` | `"Could not launch DaVinci Resolve."` |
| Wait for startup | `"Waiting for Resolve to start... (Ns)"` | after 30 attempts: `"Could not connect to DaVinci Resolve.\nMake sure Resolve Studio is running."` |
| Get project manager | `"Creating project..."` | `"Could not access Project Manager."` |
| Create or load project | — | `"Could not create or load project '{name}'."` |
| Import media | `"Importing N files..."` | `"No files were imported. Check file formats."` |
| Set metadata | `"Setting metadata on N clips..."` | — |
| Save | `""` (clears the status label) | — |

The startup wait is a loop of 30 iterations, each sleeping 1 second then
retrying the connection, so up to 30 seconds (`resolve_export.py:115`).

### Project naming

`f"RV - {folder_name}"` where `folder_name` is the basename of the currently
open folder, or `"Untitled"` when no folder is open
(`resolve_export.py:131`, `viewer.py:2115`).

If `CreateProject` returns falsy the code tries `LoadProject` with the same
name, so re-exporting the same shoot reuses the existing project
(`resolve_export.py:134`).

### Media import

Every file in the list is imported in one `media_pool.ImportMedia([...])` call
with absolute path strings (`resolve_export.py:144`). The media pool's root
folder is fetched but never used (`resolve_export.py:141`). Note: dead
variable; no bin structure is created, everything lands in the root bin.

### Filter respect

The files exported are `list(self.files)` — the **currently filtered** list, not
`all_files` (`viewer.py:2118`). So a `4+` filter exports only the four- and
five-star shots. This is the documented behaviour in `README.md` ("export all
visible files (respecting current filter)").

Ratings are looked up first from the in-memory map via the `all_files` index,
and fall back to reading the sidecar from disk if a file is somehow not in the
index (`resolve_export.py:155`).

### Clip matching

Resolve returns `MediaPoolItem`s in an unspecified order, so ratings are matched
back to clips **by filename** (`clip.GetName()` against `Path.name`)
(`resolve_export.py:163`, `:168`).

Note: this breaks when two files in the export set have the same filename but
live in different subfolders — a very common shape for multi-camera or
multi-card shoots, which this app explicitly supports via subfolder chips. Both
clips get whichever rating was written into the dict last. Note: likely
unintended. A rewrite should match on `clip.GetClipProperty("File Path")`.

### Result message

On success (`resolve_export.py:195`):

```
Exported to Resolve project '{project_name}'
{len(clips)} clips imported, {rated_count} with ratings
```

Shown in a snackbar for 4 seconds. Failures are shown for 5 seconds.

---

## 6. Guards in the UI

`_export_to_resolve` (`viewer.py:2104`):

- No files → snackbar `"No files to export"`.
- Already exporting → snackbar `"Export already in progress"`.
- Otherwise sets a busy flag, does a full blocking `_load_all_ratings()` sweep
  on the UI thread, then snapshots `files`, `ratings` and `all_files` into local
  copies and hands them to the background thread.

The busy flag is cleared in `_on_resolve_done` (`viewer.py:2144`). Note: if the
export thread raises an unhandled exception, `resolve_done` never fires, the
flag stays set, and no further export is possible until restart. Note: likely
unintended.

---

## 7. Studio-only limitation

`README.md` and the error message both state that Resolve Studio is required.
This is the historical position: Blackmagic restricted the scripting API to
Studio. More recent Resolve versions expose a subset of scripting to the free
version, but clip colour and metadata writes are among the Studio-gated
features in practice. The app does not detect Studio versus free; it simply
fails to connect and shows the Studio message.

---

## 8. Findings from the research note

Condensed from `.research/davinci-resolve-metadata-import.md`. These constrain
what is and is not possible and should inform the rewrite's choice between
options A and C above.

### Resolve cannot read XMP

Resolve does not read XMP sidecars or embedded XMP, at all. `xmp:Rating`,
`xmp:Label` and `dc:subject` are ignored. This is why the export exists: the
ratings the app has already written next to the files are invisible to Resolve,
so they have to be pushed in through the API.

### Resolve has no star rating field

There is no native rating or stars concept. The closest equivalents, in
decreasing fidelity:

| Mechanism | Settable by API | Settable by CSV | Notes |
|---|---|---|---|
| Clip colour (`SetClipColor`) | yes | **no** | per clip instance; what this app uses |
| Flags (`AddFlag`) | yes | **no** | propagate to all instances of a media pool source; multiple allowed |
| `Good Take` metadata | yes | yes | boolean-ish; this app sets it for 4+ |
| `Keywords` metadata | yes | yes | single comma-separated text field |
| `Comments` / `Description` | yes | yes | free text |
| `SetThirdPartyMetadata` | yes | no | arbitrary key/value; would be the "correct" home for a numeric rating |

Available flag and clip colours: Blue, Cyan, Green, Yellow, Red, Pink, Purple,
Fuchsia, Rose, Lavender, Sky, Mint, Lemon, Sand, Cocoa, Cream. The five the app
uses (Blue, Teal, Yellow, Orange, Green) include `Teal` and `Orange`, which are
not in that list but are accepted by `SetClipColor`. Clip colours and flag
colours are separate enumerations.

### CSV import

The supported non-scripting route: `File > Import Metadata To > Media Pool`,
with a header row of Resolve field names and a `File Name` column for matching.
Matching options include ignoring file extensions and using source file paths —
the latter would fix the duplicate-filename problem noted in section 5.

Limitations: no scripting API for CSV import (GUI only), column names must match
Resolve's field names exactly, and flags and clip colours cannot be set this
way.

### Newer Resolve versions

- 19.0.2 added scripting for per-clip custom metadata.
- 20.3 added ALE import for media pool metadata and custom metadata fields as
  bin columns, including creating custom fields for unrecognised columns during
  import. That makes a CSV/ALE route meaningfully better than it was when this
  app was written.

### What not to do

Writing directly into Resolve's PostgreSQL database or editing `.drp` project
files (ZIP archives of XML) is technically possible and strongly discouraged:
undocumented proprietary schema, BLOB storage, no version compatibility, high
corruption risk.
