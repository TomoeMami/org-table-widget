# org-table-widget

Display Org tables as responsive, pixel-aligned widgets inside ordinary Org
buffers, powered by [TextUI](https://github.com/yibie/textui).

- Align mixed CJK, Latin text, emoji and inline code using pixel widths.
- Wrap long cells and reflow after window resizing or text scaling.
- Keep the Org source table's own look: `| cell | cell |` rows, `|---+---|`
  rules, bold header rows and alternating row backgrounds.
- Preserve Org cell faces and links; support `<l>`, `<c>` and `<r>` alignment
  and horizontal separators.
- Hide alignment and column-group declaration rows from the rendered table.

Rendering uses one overlay per source row, leaving the source table intact for
Org editing, export, formulas and Babel. The row under point is not rendered: it
shows the ordinary Org source, so point moves inside it and cells are edited
right there, with no key to press first. The other rows stay rendered, and they
keep their drawings while you type. Moving from row to row inside a table only
destroys the overlay of the row point enters and rebuilds the overlay of the row
point leaves, instead of revealing and laying out the whole table again.

The correction that keeps line motion from stepping over a drawn row is adapted
from [karthink's org-latex-preview fix](https://github.com/karthink/org-mode/blob/olp/lisp/org-latex-preview.el#L670).
Thanks to karthink for the fix and for explaining the multi-line preview edge case.

## Requirements

Emacs **29.1+**, Org **9.6+**, [TextUI **0.8.0+**](https://github.com/yibie/textui),
and a **graphical Emacs frame** for rendered widgets by default. In a terminal,
the mode can be enabled, but automatic rendering is skipped and tables stay as
editable Org source unless `org-table-widget-enable-in-terminal` is non-nil.

Terminal rendering is much slower to enable on large tables. After the terminal
is resized, tables are laid out again on the next key press. Alignment of emoji
rows may depend on the terminal emulator.

## Installation

Not on MELPA yet. Install TextUI first, then this package:

```elisp
(require 'package-vc)
(package-vc-install "https://github.com/yibie/textui")
(package-vc-install "https://github.com/yibie/org-table-widget" "v0.3.1")
```

Alternatively, clone both repositories and add their directories manually:

```elisp
(add-to-list 'load-path "/path/to/textui")
(add-to-list 'load-path "/path/to/org-table-widget")
(require 'org-table-widget)
```

## Usage

Enable automatically in Org buffers:

```elisp
(require 'org-table-widget)
(add-hook 'org-mode-hook #'org-table-widget-mode)
```

Use `M-x org-table-widget-mode` to enable or disable it in the current buffer,
`M-x org-table-widget-toggle` to reveal or render the table at point, and
`M-x org-table-widget-refresh` to refresh the buffer's tables.

Line motion stops on every row of a table, so long tables can be walked
through and scrolled like ordinary text. The row that point is on shows its Org
source rather than the rendering, and point moves inside it character by
character like any other line, so cells can be edited directly with no key to
press first. All other rows of the table, and every other table in the buffer,
remain rendered. Moving up or down inside a table renders the row you left and
shows the source of the row you enter.

Editing a cell keeps the rest of the table rendered: only the row under point
is source, and the other rows keep their drawings while you type. An edit can
change how wide a column is, and every row is drawn from the widths of all the
table's cells, so the table is laid out again once point leaves the row you
edited, whether it moves to another row or out of the table; the row you move
to is then the only one left as source. The table is deliberately not laid out
while point stays on that row: redrawing it there makes the rows around the
cursor jump, and a run of edits then costs one layout when the row is left
instead of one per character.

`M-x org-table-widget-toggle` reveals the whole table at point as source, so
that a command can work on several rows at once, for example `org-table`
alignment or `#+TBLFM` recalculation. Running it again on the table renders it,
and moving point out of the table renders it as well; either way the row under
point still shows its source. This is the only command that turns a whole table
back into source: editing alone never does. A search that lands inside a table
therefore leaves point on its Org source line.

When a table's header, the rows above its first horizontal rule, scrolls out of
view while the rest of the table is still on screen, the window's header line
shows it, aligned with the columns below. The header line holds one line, so a
header that wraps or spans several rows shows only its first line. Any other
header line comes back once the header scrolls into view again. The sticky
header makes scrolling through large tables noticeably less smooth; set
`org-table-widget-sticky-header` to nil if that matters more.

### Options

Customize with `M-x customize-group RET org-table-widget RET`.

| Option | Default | Meaning |
| --- | --- | --- |
| `org-table-widget-enable-in-terminal` | `nil` | Render table widgets on text terminals as well. |
| `org-table-widget-zebra-stripe` | `t` | Alternate the background of the drawn rows. |
| `org-table-widget-wrap-columns` | `t` | Wrap cell content; nil uses natural widths. |
| `org-table-widget-max-width-fraction` | `1.0` | Fraction of the window body width available to the table. |
| `org-table-widget-relayout-delay` | `0.15` | Idle seconds before a relayout after a resize or a font change; zero or negative means immediate. |
| `org-table-widget-sticky-header` | `t` | Keep a scrolled-off table header in the header line. |
| `org-table-widget-cell-properties` | `(face font-lock-face invisible display mouse-face help-echo keymap follow-link htmlize-link org-emphasis)` | Text properties retained in rendered cells. |

### Faces

The rendered table takes three faces, all customizable with
`M-x customize-group RET org-table-widget RET`:

| Face | Default | Used for |
| --- | --- | --- |
| `org-table-widget-row` | `gray98` / `gray13` background | Drawn rows that are not zebra striped, rules included. |
| `org-table-widget-zebra` | `gray95` / `gray20` background | Every second drawn row, rules and header rows included, when `org-table-widget-zebra-stripe` is non-nil. |
| `org-table-widget-header` | inherits `bold` | Header rows, the rows above the first horizontal rule. |

The bands alternate over every row the rendering draws, so the header rows and
the horizontal rules are striped along with the data rows and the stripes run
unbroken through the whole table. A header row keeps its bold face on top of
its band. Both backgrounds are taken from the buffer background, so the table
reads as a block of banded rows instead of dissolving into the surrounding
text. Change them to match your theme; set `org-table-widget-zebra-stripe` to
`nil` for a single flat band, which leaves the header bold and the rules
unbanded.

### Compatibility

- **`org-modern`:** Set `org-modern-table` to `nil` so the two packages do not
  style the same table. Non-table styling has been smoke-tested in both
  mode-enabling orders, including through `org-mode-hook`, with Emacs 31.0.91,
  Org 9.8.7 and org-modern 1.15. A reported load-order conflict has not yet been
  reproduced; please include package versions and a minimal configuration when
  reporting it.
- **`visual-line-mode`:** Cursor motion is tested with the mode both enabled
  and disabled: Down and Up stop on the table rows, then step past the table.
  A narrow-window layout smoke test also passed with the mode enabled. This
  does not eliminate the minimum-width overflow limitation noted below.

## Compared with valign

`org-table-widget` and [Valign](https://github.com/casouri/valign) share a basic
promise: both use pixel measurements to align tables without rewriting their
source text. They work at different layers. Valign visually aligns the existing
table in place. `org-table-widget` covers the source with a separate, responsive
rendering and shows the source row by row as point moves through the table.

| Capability | `org-table-widget` | Valign |
| --- | --- | --- |
| Display model | Builds a row-by-row overlay rendering on top of the source table. | Adds display properties and overlays to spaces and separators in the existing table. |
| Table formats | Org pipe tables. | Org, Markdown and `table.el` tables. |
| Editing | Stops on each row; the row under point shows ordinary Org source and is edited in place, with no key to press, while the other rows stay rendered. | Keeps the visually aligned source visible and editable. |
| Mixed-width text | Pixel-aligns CJK, Latin text, emoji and inline code inside a fixed-pitch table. | Pixel-aligns the table as displayed, including variable-pitch text, CJK and images. |
| Narrow windows | Allocates columns within the window budget, wraps cell content and reflows after resizing. | Keeps cells on one source line at their natural width; it does not provide responsive cell wrapping. |
| Alignment | Supports explicit `<l>`, `<c>` and `<r>` Org cookies, including centered cells. | Infers left or right alignment from the source layout; Markdown center alignment is treated as left alignment. |
| Presentation | Keeps the Org source table's own look: pipe-delimited cells, ruled divider rows, bold header rows and optional zebra striping across whole rows. | Preserves the source table's shape, with an optional fancy vertical-bar style. |
| Large tables | Caches measurements and unchanged renderings and has no fixed source-size cutoff. | Defaults to a fixed-pitch fallback for tables larger than 4,000 characters. |
| Requirements | Emacs 29.1+, Org 9.6+ and TextUI 0.8.0+; currently installed from source or with `package-vc`. | Emacs 26+ with no extra package dependency; available from GNU ELPA. |

Choose Valign when the main goal is to keep an Org or Markdown table aligned
while editing it, especially with variable-pitch text or inline images. Choose
`org-table-widget` when an Org buffer needs a reading-oriented table that wraps
to narrow windows, styles header and alternating rows, and still lets the row
under point be edited as plain Org source.

The packages should be treated as alternatives for the same Org table. Running
both modes on one table is untested, and both manage display properties or
overlays in that region.

## Status

**0.3.1 is an early release.** It is developed and used day to day on Emacs 32
(the development branch), so display behavior on earlier versions gets less
testing. Reports from Emacs 29, 30 and 31 users are very welcome; please open an
issue with your Emacs version.

Known limitations:

- Org width cookies are ignored.
- Very wide tables can overflow the window when minimum column widths do not fit.
  Overflow is truncated when `truncate-lines` is non-nil (the Org default), or
  wraps when nil; the widget does not change `truncate-lines`.
- After an edit the rows keep their old drawings until point leaves the edited
  row; a cell that got much wider can push the rest of the row past the window
  edge in the meantime, until the table is laid out again on the next move.
- Numeric columns are not automatically right-aligned; use an explicit `<r>` cookie.
- The sticky header slows scrolling through large tables, in both directions;
  set `org-table-widget-sticky-header` to nil to avoid it.
- Coexistence with `valign` is untested; see above for `org-modern` test coverage.

See [CHANGELOG.md](CHANGELOG.md) for release changes.

## Performance

Measured with `demos/bench.el` on macOS, Apple M4 Max,
Emacs 31.0.91 GUI, with Iosevka at height 150. Times are seconds.

| Table | First display | Refresh | Resize relayout | Leave table |
| --- | ---: | ---: | ---: | ---: |
| 500 × 8 (`large.org`) | 0.355002 | 0.007237 | 0.279066 | 0.007163 |
| 3000 × 6 (generated `huge.org`) | 1.339867 | 0.034297 | 1.052924 | 0.034108 |

Refresh and leave-table timings reuse unchanged content; edits require rebuilding.
These are single-run measurements on this machine, not guarantees for other setups.

## Demos and tests

Browse [demos/](demos/) for example tables, benchmarks and visual checks.
With TextUI checked out alongside this repository, generate the benchmark inputs
(including the untracked `huge.org`), then run each GUI script in a separate Emacs:

```sh
emacs -Q --batch -l /absolute/path/to/org-table-widget/demos/gen-large.el -f org-table-widget-demo-generate
emacs -Q -l /absolute/path/to/org-table-widget/demos/bench.el
emacs -Q -l /absolute/path/to/org-table-widget/demos/visual-check.el
```

Replace `/absolute/path/to` with your checkout's parent directory. Scripts write
ignored logs/profiles under `demos/` and screenshots under `demos/shots/`, then exit.

With TextUI checked out alongside this repository, run the full ERT suite:

```sh
cd /path/to/org-table-widget
emacs -Q --batch -L . -L ../textui -L test -l org-table-widget.el \
  -l test/org-table-widget-tests.el -l test/org-table-widget-demo-tests.el \
  -f ert-run-tests-batch-and-exit
```

The redisplay-dependent motion tests are skipped in batch mode. In a graphical
Emacs, load `test/org-table-widget-tests.el` and run
`M-x ert RET vertical-interactive RET`.
For the optional org-modern compatibility test, put org-modern and its
dependencies on `load-path`, load `test/org-table-widget-compat-tests.el`, then
run `M-x ert RET org-table-widget-compat- RET`.

Prefer `--batch` when real pixels are unnecessary. On macOS, the Emacs.app
launcher ignores the shell working directory, hence the absolute paths above.
For GUI invocations, use absolute paths for every `-l`, file name in `--eval`,
and log path, or pass `--chdir /absolute/path/to/org-table-widget` before loading scripts.
