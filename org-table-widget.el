;;; org-table-widget.el --- Display Org tables as responsive pixel-aligned widgets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 yibie

;; Author: yibie <https://github.com/yibie>
;; Assisted-by: OpenAI Codex
;; Maintainer: yibie <https://github.com/yibie>
;; URL: https://github.com/yibie/org-table-widget
;; Version: 0.3.1
;; Package-Requires: ((emacs "29.1") (org "9.6") (textui "0.8.0"))
;; Keywords: outlines, wp, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `org-table-widget-mode' shows every Org table in the buffer as a
;; block widget whose columns are aligned in pixels rather than in
;; characters.  Cells that mix CJK text, emoji, inline code and
;; proportional fonts stay aligned, long cells wrap inside their
;; column, and the table reflows when the window width changes.
;;
;; The buffer text is never modified.  Each row of a table is covered
;; by an overlay whose `before-string' holds that row of the laid-out
;; widget, so `org-element', export, `#+TBLFM' evaluation and Babel
;; keep seeing the original table.
;;
;; A table is drawn in the shape Org gives it: cells separated by
;; pipes, rules of dashes with a plus at each column boundary, and no
;; outer frame.  Header rows are bold.  Every drawn row, header rows and
;; rules included, alternates between two background faces, so the table
;; reads as one block of bands.
;;
;; Each row is drawn on its own.  The row point rests on is left as
;; source, so point moves through a table one row at a time and the
;; row under point can be read and edited in place.  Moving between
;; rows deletes the overlay of the row point arrives on and draws the
;; one it left, so a move inside a table costs two overlays rather than
;; a relayout of the table.  `org-table-widget-toggle' reveals the
;; whole table while it is edited.
;;
;; Cell contents are copied from the fontified buffer, so links,
;; emphasis and code markup keep the faces Org gives them.
;;
;; Layout is provided by TextUI (https://github.com/yibie/textui),
;; which lays out block widgets inside ordinary Emacs buffers.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'wid-edit)
(require 'org)
(require 'org-table)
(require 'org-element)

(declare-function textui-layout-widget "textui" (widget width))
(defvar org-table-widget-mode)

;;;; Options and faces

(defgroup org-table-widget nil
  "Display Org tables as responsive pixel-aligned widgets."
  :group 'org
  :prefix "org-table-widget-")

(defcustom org-table-widget-enable-in-terminal nil
  "When non-nil, render table widgets on text terminals as well.
Otherwise tables on a terminal stay as editable Org source."
  :type 'boolean)

(defcustom org-table-widget-zebra-stripe t
  "When non-nil, alternate the background of the drawn rows.
Every row the rendering draws takes its place in the bands, so header
rows and horizontal rules are striped along with the data rows and the
stripes run through the whole table."
  :type 'boolean)

(defcustom org-table-widget-wrap-columns t
  "When non-nil, wrap cells so the table fits the window width.
When nil, lay every column out at its natural width."
  :type 'boolean)

(defcustom org-table-widget-max-width-fraction 1.0
  "Fraction of the window body width available to a table."
  :type 'number)

(defcustom org-table-widget-relayout-delay 0.15
  "Idle seconds to wait after a window resize before laying tables out.
Resizing a frame by dragging fires many configuration changes in a row;
waiting until they stop produces one relayout instead of one per step.
A value of zero or less relays out immediately."
  :type 'number)

(defcustom org-table-widget-cell-properties
  '(face font-lock-face invisible display mouse-face help-echo keymap
         follow-link htmlize-link org-emphasis)
  "Text properties copied from the buffer into widget cells.
Every other property is dropped so that the widget does not inherit
line prefixes, fontification state or private markers."
  :type '(repeat symbol))

(defcustom org-table-widget-sticky-header t
  "When non-nil, keep the header of a table scrolled past in the header line.
A table's header is the rows above its first horizontal rule.  While
the top of a window shows a table whose header is scrolled out of view,
the window's header line shows the header aligned with the columns
below, replacing any other header line until the header scrolls back
into view.  The header line holds a single line, so a header that wraps
or spans several rows shows only its first line.

Showing the header line slows scrolling through large tables; set this
to nil when smooth scrolling matters more."
  :type 'boolean)

(defface org-table-widget-header
  '((t :inherit bold))
  "Face for header rows.")

(defface org-table-widget-zebra
  '((((class color) (background light)) :background "gray95")
    (((class color) (background dark)) :background "gray20")
    (t :inherit highlight))
  "Face for every second drawn row of a table.
Header rows and horizontal rules take it as well, so the bands run
through the whole table rather than restarting after the header.")

(defface org-table-widget-row
  '((((class color) (background light)) :background "gray98")
    (((class color) (background dark)) :background "gray13"))
  "Face for the drawn rows that do not take `org-table-widget-zebra'.
Header rows and horizontal rules take it as well.")

;;;; Pixel measurement

(defconst org-table-widget--measure-x-limit 100000
  "X limit for `window-text-pixel-size' so wide cells are not clipped.")

(defvar-local org-table-widget--char-pixel-cache nil
  "Cons cell (FONT-SIGNATURE . SPACE-PIXELS) caching the width of a space.")

(defvar-local org-table-widget--measure-cache nil
  "Cons cell (VALIDITY . HASH-TABLE) caching string measurements.
VALIDITY records the fonts the measurements were taken with.")

(defconst org-table-widget--measure-cache-limit 50000
  "Number of cached measurements after which the cache is rebuilt.")

(define-hash-table-test 'org-table-widget--string-properties
  #'equal-including-properties #'sxhash-equal-including-properties)

(defun org-table-widget--font-signature (window)
  "Return the font and face-remapping state affecting layout in WINDOW."
  (with-current-buffer (window-buffer window)
    (let ((frame (window-frame window)))
      (list (ignore-errors (window-font-width window))
            (ignore-errors (face-font 'default frame))
            (ignore-errors (face-font 'fixed-pitch frame))
            (copy-tree face-remapping-alist)))))

(defun org-table-widget--measure-string (str window)
  "Return the pixel width of STR rendered at the end of WINDOW's buffer.
STR is pinned to `fixed-pitch' so the result does not depend on
`variable-pitch-mode' remapping the default face.  It is measured on a
line of its own: overlay strings displayed at the end of the buffer
would otherwise be measured along with every non-empty STR."
  (let ((str (copy-sequence str)))
    (add-face-text-property 0 (length str) 'fixed-pitch nil str)
    (with-current-buffer (window-buffer window)
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t)
            (after-change-functions nil)
            (before-change-functions nil)
            (buffer-undo-list t)
            (modified (buffer-modified-p))
            (deactivate-mark nil)
            (line-prefix nil)
            (wrap-prefix nil)
            ;; Otherwise the probe's pixel size includes the number area.
            (display-line-numbers nil))
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-max))
            (let ((beg (point)) end)
              (unwind-protect
                  (progn
                    (insert "\n" str "\n")
                    (setq end (point))
                    (put-text-property beg end 'fontified t)
                    (remove-text-properties beg end
                                            '(line-prefix nil wrap-prefix nil))
                    (car (window-text-pixel-size
                          window (1+ beg) (1- end)
                          org-table-widget--measure-x-limit)))
                ;; Redisplay/fontification may move point.  Delete only the
                ;; inserted probe, even if measurement signals an error.
                (when end (delete-region beg end))
                (set-buffer-modified-p modified)))))))))

(defun org-table-widget--char-pixel-width (window)
  "Return the pixel width of one space in WINDOW, cached per buffer."
  (with-current-buffer (window-buffer window)
    (let ((fw (org-table-widget--font-signature window)))
      (if (and org-table-widget--char-pixel-cache
               (equal fw (car org-table-widget--char-pixel-cache)))
          (cdr org-table-widget--char-pixel-cache)
        (let ((sw (org-table-widget--measure-string " " window)))
          (setq org-table-widget--char-pixel-cache (cons fw sw))
          sw)))))

(defun org-table-widget--measurements (window)
  "Return the measurement cache for WINDOW's buffer.
The cache survives relayouts and is dropped when the window font or
the `fixed-pitch' font changes."
  (with-current-buffer (window-buffer window)
    (let ((validity (org-table-widget--font-signature window)))
      (unless (and org-table-widget--measure-cache
                   (equal (car org-table-widget--measure-cache) validity)
                   (< (hash-table-count (cdr org-table-widget--measure-cache))
                      org-table-widget--measure-cache-limit))
        (setq org-table-widget--measure-cache
              (cons validity (make-hash-table
                              :test 'org-table-widget--string-properties))))
      (cdr org-table-widget--measure-cache))))

(defmacro org-table-widget--with-cached-measurements (window &rest body)
  "Run BODY with `org-table-widget--measure-string' cached for WINDOW."
  (declare (indent 1) (debug (form body)))
  (let ((measure (make-symbol "measure"))
        (table (make-symbol "table")))
    `(let* ((,measure (symbol-function 'org-table-widget--measure-string))
            (,table (org-table-widget--measurements ,window)))
       (cl-letf (((symbol-function 'org-table-widget--measure-string)
                  (lambda (string destination)
                    (let ((cached (gethash string ,table 'missing)))
                      (if (eq cached 'missing)
                          ;; Own the key: later property edits must not change
                          ;; its hash or overwrite a previously measured style.
                          (puthash (copy-sequence string)
                                   (funcall ,measure string destination) ,table)
                        cached)))))
         ,@body))))

(defun org-table-widget--prefix-width (beg window)
  "Return the wider effective line or wrap prefix at BEG in WINDOW, in pixels."
  (with-current-buffer (window-buffer window)
    (apply #'max
           (mapcar
            (lambda (property)
              (let ((prefix (or (get-text-property beg property)
                                (symbol-value property))))
                (if prefix
                    (org-table-widget--measure-string
                     (if (stringp prefix) prefix
                       (propertize " " 'display prefix))
                     window)
                  0)))
            '(line-prefix wrap-prefix)))))

(defun org-table-widget--reserves-continuation-p (window)
  "Return non-nil when WINDOW keeps its last column for a continuation glyph.
Unless both fringes are shown and `overflow-newline-into-fringe' is
non-nil, a line as wide as the text area is continued, so a full-width
table would push its right border onto the next screen line.
`window-max-chars-per-line' leaves out the same column."
  (let ((fringes (window-fringes window)))
    (not (and (bound-and-true-p overflow-newline-into-fringe)
              (> (nth 0 fringes) 0)
              (> (nth 1 fringes) 0)))))

(defun org-table-widget--line-number-width (window)
  "Return the pixels line numbers take at the start of WINDOW's lines.
Redisplay sizes the number area for the largest line number its rows
could reach from the window start, so the area widens as WINDOW scrolls
down.  Leave room for the widest it can become."
  (with-current-buffer (window-buffer window)
    (if (not display-line-numbers)
        0
      (with-selected-window window
        (let* ((pixels (line-number-display-width t))
               (digits (line-number-display-width))
               ;; Redisplay rows add a partial line at each edge and
               ;; the tab, header and mode lines to the body lines.
               (largest (+ (line-number-at-pos (point-max) t)
                           (window-body-height window) 5))
               (widest (max digits (length (number-to-string largest)))))
          ;; The digits and the blank on each side are glyphs of one width.
          (ceiling (* pixels (+ widest 2)) (+ digits 2)))))))

(defun org-table-widget--pixel-budget (width window)
  "Return the pixel budget for a table laid out at WIDTH columns in WINDOW.
WIDTH counts columns of the frame's default font; converting it with
the `fixed-pitch' space width overshoots when the two faces use
different fonts, so the result never exceeds the window's real body
pixel width when WIDTH fills the window."
  (let* ((measured (org-table-widget--measure-string
                    (make-string width ?\s) window))
         (body-pixels (and (window-live-p window)
                           (window-body-width window t)))
         (budget (if (and body-pixels
                          (> body-pixels width)
                          (>= width (window-body-width window)))
                     (min measured body-pixels)
                   measured)))
    (floor (* org-table-widget-max-width-fraction budget))))

;;;; Graphemes and wrapping

(defun org-table-widget--break-after-p (text i)
  "Return non-nil when a line may break after index I in TEXT.
I + 1 must be a valid index.  Breaks are allowed after line-breakable
characters (CJK ideographs, kana, Hangul) unless the next character is
zero-width and must stay attached."
  (and (aref (char-category-set (aref text i)) ?|)
       (> (char-width (aref text (1+ i))) 0)))

(defun org-table-widget--regional-indicator-p (char)
  "Return non-nil when CHAR is a regional-indicator symbol."
  (<= #x1F1E6 char #x1F1FF))

(defun org-table-widget--grapheme-extension-p (char)
  "Return non-nil when CHAR extends the preceding grapheme."
  (or (zerop (char-width char))
      (<= #x1F3FB char #x1F3FF)))

(defun org-table-widget--next-grapheme-end (text start)
  "Return the end of the extended grapheme in TEXT starting at START."
  (let* ((length (length text))
         (end (1+ start)))
    (when (and (org-table-widget--regional-indicator-p (aref text start))
               (< end length)
               (org-table-widget--regional-indicator-p (aref text end)))
      (setq end (1+ end)))
    (while (and (< end length)
                (org-table-widget--grapheme-extension-p (aref text end))
                (not (= (aref text end) #x200D)))
      (setq end (1+ end)))
    (while (and (< end length) (= (aref text end) #x200D))
      (setq end (min length (+ end 2)))
      (while (and (< end length)
                  (org-table-widget--grapheme-extension-p (aref text end))
                  (not (= (aref text end) #x200D)))
        (setq end (1+ end))))
    end))

(defun org-table-widget--grapheme-ends (text start)
  "Return grapheme end positions in TEXT following START."
  (let ((position start)
        ends)
    (while (< position (length text))
      (setq position (org-table-widget--next-grapheme-end text position))
      (push position ends))
    (nreverse ends)))

(defun org-table-widget--fit-end (text start pixels window)
  "Return the longest end of TEXT after START fitting PIXELS in WINDOW."
  (let* ((ends (vconcat (org-table-widget--grapheme-ends text start)))
         (low 0)
         (high (1- (length ends)))
         (best (aref ends 0)))
    (while (<= low high)
      (let* ((mid (/ (+ low high) 2))
             (end (aref ends mid))
             (measured (org-table-widget--measure-string
                        (substring text start end) window)))
        (if (<= measured pixels)
            (setq best end low (1+ mid))
          (setq high (1- mid)))))
    best))

(defun org-table-widget--break-end (text start end)
  "Move END back to a natural break in TEXT without crossing START."
  (let ((scan (1- end))
        break)
    (while (and (> scan start) (not break))
      (when (or (memq (aref text scan) '(?\s ?\t))
                (and (< scan (1- (length text)))
                     (org-table-widget--break-after-p text scan)))
        (setq break (1+ scan)))
      (setq scan (1- scan)))
    (or break end)))

(defun org-table-widget--wrap-pixels (text pixels window)
  "Wrap TEXT into lines no wider than PIXELS in WINDOW."
  (if (or (string-empty-p text)
          (<= (org-table-widget--measure-string text window) pixels))
      (list text)
    (let ((position 0)
          (text-length (length text))
          lines)
      (while (< position text-length)
        (let* ((fit (org-table-widget--fit-end text position pixels window))
               (end (if (< fit text-length)
                        (org-table-widget--break-end text position fit)
                      fit)))
          (push (string-trim-right (substring text position end)) lines)
          (setq position end)
          (while (and (< position text-length)
                      (memq (aref text position) '(?\s ?\t)))
            (setq position (1+ position)))))
      (nreverse lines))))

(defun org-table-widget--longest-token-pixels (text window)
  "Return the pixel width of the widest unbreakable token in TEXT in WINDOW."
  (let ((length (length text))
        (start 0)
        (widest 0))
    (cl-flet ((measure-token (end)
                (when (> end start)
                  (setq widest
                        (max widest
                             (org-table-widget--measure-string
                              (substring text start end) window))))))
      (dotimes (index length)
        (cond
         ((memq (aref text index) '(?\s ?\t))
          (measure-token index)
          (setq start (1+ index)))
         ((and (< index (1- length))
               (org-table-widget--break-after-p text index))
          (measure-token (1+ index))
          (setq start (1+ index)))))
      (measure-token length))
    widest))

;;;; Column widths

(defconst org-table-widget--width-cap-fraction 0.5
  "Fraction of the available width that bounds one column's claims.
Without the cap a single huge cell takes nearly the whole table and
starves the short columns down to one character per line.")

(defun org-table-widget--widths (rows columns pixel-budget boundary-pixels
                                      window)
  "Allocate pixel widths for COLUMNS over ROWS in WINDOW.
ROWS is a list of cell lists; `hline' entries are ignored.
PIXEL-BUDGET includes the BOUNDARY-PIXELS between columns.

Each column claims a minimum (its widest grapheme, or its widest
unbreakable token up to the cap) and a natural width (its widest
cell).  When the natural widths do not fit, columns are settled at
their natural width cheapest first: a column whose growth above its
minimum fits either an equal share or its proportional share of the
remaining space keeps its natural width, and the shares are
recomputed after each one.  The remaining columns wrap regardless;
they share what is left in proportion to their natural width above
the minimum, capped so one giant cell cannot starve the others, and
are rounded so the widths sum exactly to the available pixels."
  (let* ((space-pixels (org-table-widget--char-pixel-width window))
         (base-minimum (+ 1 (* 2 space-pixels)))
         (available (- pixel-budget (* (1+ columns) boundary-pixels)))
         (cap (floor (* org-table-widget--width-cap-fraction available)))
         (minimums (make-list columns base-minimum))
         (natural (make-list columns base-minimum)))
    (dolist (row rows)
      (unless (eq row 'hline)
        (cl-loop for cell in row
                 for column from 0
                 do (let ((cell-pixels
                           (org-table-widget--measure-string cell window))
                          (cluster-maximum 1)
                          (token-maximum
                           (org-table-widget--longest-token-pixels
                            cell window))
                          (start 0))
                      (dolist (end (org-table-widget--grapheme-ends cell 0))
                        (setq cluster-maximum
                              (max cluster-maximum
                                   (org-table-widget--measure-string
                                    (substring cell start end) window)))
                        (setq start end))
                      (setf (nth column natural)
                            (max (nth column natural)
                                 (+ (* 2 space-pixels) cell-pixels)))
                      (setf (nth column minimums)
                            (max (nth column minimums)
                                 (+ (* 2 space-pixels)
                                    (max cluster-maximum
                                         (min token-maximum cap)))))))))
    (let ((natural-total (apply #'+ natural))
          (minimum-total (apply #'+ minimums)))
      (cond
       ((not org-table-widget-wrap-columns) natural)
       ((<= natural-total available) natural)
       ((<= available minimum-total) minimums)
       (t
        ;; Settle the cheapest columns at their natural width first, so
        ;; short cells stay whole while a long column wraps anyway.
        ;; Recompute the shares after every grant: settling a whole pass
        ;; against stale shares can overflow AVAILABLE.
        (let* ((flexible (- available minimum-total))
               (growths (seq-mapn #'- natural minimums))
               (weights (seq-mapn (lambda (width minimum)
                                    (max 1 (- (min width cap) minimum)))
                                  natural minimums))
               (widths (copy-sequence minimums))
               ;; `sort' is stable, so equal growths keep column order.
               (unresolved (sort (number-sequence 0 (1- columns))
                                 (lambda (a b)
                                   (< (nth a growths) (nth b growths))))))
          (cl-flet ((weight-total ()
                      (apply #'+ (mapcar (lambda (column) (nth column weights))
                                         unresolved))))
            (while-let
                ((column
                  (let ((count (length unresolved))
                        (total (weight-total)))
                    (seq-find (lambda (column)
                                (<= (nth column growths)
                                    (max (/ flexible count)
                                         (/ (* flexible (nth column weights))
                                            total))))
                              unresolved))))
              (setf (nth column widths) (nth column natural))
              (setq flexible (- flexible (nth column growths))
                    unresolved (delq column unresolved)))
            ;; The rest wrap regardless.  Round cumulatively so the widths
            ;; sum exactly to AVAILABLE instead of the last column taking
            ;; every leftover pixel.
            (let ((total (weight-total))
                  (cumulative 0)
                  (previous 0))
              (dolist (column (sort unresolved #'<))
                (setq cumulative (+ cumulative (nth column weights)))
                (let ((target (/ (* flexible cumulative) total)))
                  (setf (nth column widths)
                        (+ (nth column minimums) (- target previous)))
                  (setq previous target)))))
          widths))))))

;;;; Rendering

(defun org-table-widget--pixel-space (pixels)
  "Return an invisible display space occupying PIXELS."
  (if (> pixels 0)
      (propertize "\u200B" 'display `(space :width (,pixels))
                  'org-table-widget-spacing t)
    ""))

(defun org-table-widget--boundary-pixels (window)
  "Return the pixel advance of the glyphs that draw a table's frame in WINDOW.
The package draws tables as ordinary Org tables do, so the pipe, the
plus and the dash must all advance by the same number of pixels."
  (apply #'max
         (mapcar (lambda (glyph)
                   (max 1 (org-table-widget--measure-string glyph window)))
                 '("|" "+" "-"))))

(defun org-table-widget--rule-segment (pixels window)
  "Return a run of dashes occupying PIXELS in WINDOW."
  (let* ((glyph-pixels (org-table-widget--boundary-pixels window))
         (count (floor (/ (float pixels) glyph-pixels)))
         (remainder (- pixels (* count glyph-pixels))))
    (concat (make-string count ?-)
            (org-table-widget--pixel-space remainder))))

(defun org-table-widget--rule (widths window)
  "Return the rule Org puts below a row of WIDTHS in WINDOW."
  (concat "|"
          (mapconcat (lambda (width)
                       (org-table-widget--rule-segment width window))
                     widths "+")
          "|"))

(defun org-table-widget--add-face (string faces)
  "Return STRING with FACES added after the faces it already carries.
FACES is a face or a list of faces.  Adding them one at a time keeps a
row's faces flat: a face list handed to `add-face-text-property' whole
would be nested rather than merged into the row's own faces."
  (dolist (face (ensure-list faces))
    (add-face-text-property 0 (length string) face t string))
  string)

(defun org-table-widget--band-face (index header rule)
  "Return the face to draw on the row at INDEX among its table's drawn rows.
The bands alternate across everything the rendering draws, so a table's
header rows and horizontal rules sit in the same stripe as its data
rows instead of starting a stripe of their own.  HEADER marks a header
row, which keeps its bold face and takes its band underneath it; RULE
marks a horizontal rule.  Return nil for a rule when zebra striping is
off: it then keeps the buffer background, and so does a header row,
which stays bold."
  (let ((band (and org-table-widget-zebra-stripe
                   (if (= (mod index 2) 1)
                       'org-table-widget-zebra
                     'org-table-widget-row))))
    (cond (header (if band
                      (list 'org-table-widget-header band)
                    'org-table-widget-header))
          (rule band)
          (t (or band 'org-table-widget-row)))))

(defun org-table-widget--padding-widths (padding alignment)
  "Split PADDING pixels into left and right widths for ALIGNMENT."
  (pcase alignment
    ('right (cons padding 0))
    ('center (let ((left (/ padding 2)))
               (cons left (- padding left))))
    (_ (cons 0 padding))))

(defun org-table-widget--pad (text pixels window alignment)
  "Pad TEXT to PIXELS in WINDOW according to ALIGNMENT."
  (let* ((used (org-table-widget--measure-string text window))
         (padding (max 0 (- pixels used)))
         (widths (org-table-widget--padding-widths padding alignment)))
    (concat (org-table-widget--pixel-space (car widths))
            text
            (org-table-widget--pixel-space (cdr widths)))))

(defun org-table-widget--row (cells widths alignments row-face window)
  "Render CELLS at pixel WIDTHS with ALIGNMENTS and ROW-FACE in WINDOW.
The result has the shape of an Org table row: one pipe on either side
and one between neighbouring cells."
  (let* ((space-pixels (org-table-widget--char-pixel-width window))
         (content-widths (mapcar (lambda (width)
                                   (max 1 (- width (* 2 space-pixels))))
                                 widths))
         (wrapped (seq-mapn (lambda (cell width)
                              (org-table-widget--wrap-pixels cell width window))
                            cells content-widths))
         (height (apply #'max 1 (mapcar #'length wrapped)))
         lines)
    (dotimes (line-index height)
      (let (parts)
        (seq-mapn
         (lambda (cell-lines content-width alignment)
           (let* ((line (or (nth line-index cell-lines) ""))
                  (content (org-table-widget--pad line content-width window
                                                  alignment)))
             (push (concat " " content " ") parts)))
         wrapped content-widths alignments)
        (push (concat "|" (string-join (nreverse parts) "|") "|") lines)))
    (let ((row (string-join (nreverse lines) "\n")))
      (org-table-widget--add-face row row-face))))

(defun org-table-widget--source-line (string line)
  "Mark STRING as drawn for source LINE and return it.
LINE is an offset from the first line of the table, or nil."
  (when line
    (put-text-property 0 (length string) 'org-table-widget-line line string))
  string)

(defun org-table-widget--render-rows (table window width &optional pixel-budget)
  "Lay TABLE out in WINDOW at WIDTH and return one (LINE . STRING) per row.
LINE is the offset of the row's source line from the table start.  A
row whose cells wrap occupies several lines of its STRING.
Every drawn row, rules and header rows included, takes its place in the
table's alternating bands.  PIXEL-BUDGET, when non-nil, overrides the
column-derived pixel budget."
  (let* ((rows (plist-get table :rows))
         (lines (plist-get table :lines))
         (alignments (plist-get table :alignments))
         (header-rows (plist-get table :header-rows))
         (columns (length alignments))
         (pixel-budget (or pixel-budget
                           (org-table-widget--pixel-budget width window)))
         (boundary-pixels (org-table-widget--boundary-pixels window))
         (widths (org-table-widget--widths rows columns pixel-budget
                                           boundary-pixels window))
         (band-index 0)
         (row-index 0)
         rendered)
    (cl-loop for row in rows
             for line = (pop lines)
             do (push
                 (cons line
                       (org-table-widget--source-line
                        (if (eq row 'hline)
                            (org-table-widget--add-face
                             (org-table-widget--rule widths window)
                             (org-table-widget--band-face band-index nil t))
                          (org-table-widget--row
                           row widths alignments
                           (org-table-widget--band-face
                            band-index (< row-index header-rows) nil)
                           window))
                        line))
                 rendered)
             do (setq band-index (1+ band-index))
             unless (eq row 'hline)
             do (setq row-index (1+ row-index)))
    (nreverse rendered)))

(defun org-table-widget--render (table window width &optional pixel-budget)
  "Lay TABLE out for WINDOW at WIDTH columns and return the string.
TABLE is a plist with :rows (cell lists or `hline'), :alignments,
:header-rows, the number of leading rows before the first `hline',
and optionally :lines, the source line offset of each row.
PIXEL-BUDGET, when non-nil, overrides the column-derived pixel budget."
  (string-join (mapcar #'cdr
                       (org-table-widget--render-rows table window width
                                                      pixel-budget))
               "\n"))

;;;; TextUI widget

(defun org-table-widget--layout (widget width)
  "Lay out table WIDGET within WIDTH columns for TextUI."
  (let* ((table (widget-get widget :value))
         (window (or (widget-get widget :window)
                     (get-buffer-window (current-buffer))
                     (selected-window)))
         (rendered (org-table-widget--with-cached-measurements window
                     (org-table-widget--render table window width
                                               (widget-get widget :pixel-budget)))))
    ;; A table of one row renders one line; TextUI wants a block.
    (if (string-match-p "\n" rendered) rendered (concat rendered "\n"))))

(define-widget 'org-table-widget 'default
  "A width-aware Org table."
  :format "%v"
  :textui-layout #'org-table-widget--layout)

;;;; Parsing Org tables

(defconst org-table-widget--cookie-regexp "\\`<\\([lrc]\\)?\\([0-9]+\\)?>\\'"
  "Regexp matching an Org alignment or width cookie.")

(defun org-table-widget--cookie-alignment (cell)
  "Return the alignment declared by cookie CELL, or nil."
  (when (string-match org-table-widget--cookie-regexp cell)
    (pcase (match-string 1 cell)
      ("r" 'right)
      ("c" 'center)
      ("l" 'left)
      (_ nil))))

(defun org-table-widget--cookie-row-p (cells)
  "Return non-nil when CELLS form a cookie-only row."
  (and (seq-some (lambda (cell) (string-match-p org-table-widget--cookie-regexp
                                                cell))
                 cells)
       (seq-every-p (lambda (cell)
                      (or (string-empty-p cell)
                          (string-match-p org-table-widget--cookie-regexp cell)))
                    cells)))

(defun org-table-widget--group-row-p (cells)
  "Return non-nil when CELLS declare Org column groups."
  (and (equal (car cells) "/")
       (seq-every-p (lambda (cell) (member cell '("" "<" ">" "<>")))
                    (cdr cells))))

(defun org-table-widget--clean-cell (text)
  "Return TEXT trimmed, keeping only `org-table-widget-cell-properties'."
  (let ((cell (string-trim text)))
    (let ((position 0)
          (length (length cell)))
      (while (< position length)
        (let* ((next (or (next-property-change position cell) length))
               (plist (text-properties-at position cell))
               (drop (cl-loop for (key _value) on plist by #'cddr
                              unless (memq key org-table-widget-cell-properties)
                              collect key)))
          (when drop
            (remove-list-of-text-properties position next drop cell))
          (setq position next))))
    cell))

(defun org-table-widget--line-cells ()
  "Return the propertized cells of the table row on the current line."
  (let ((end (line-end-position))
        cells)
    (save-excursion
      (beginning-of-line)
      (skip-chars-forward " \t")
      (when (eq (char-after) ?|)
        (forward-char)
        (let ((start (point)))
          (while (re-search-forward "|" end 'move)
            (push (org-table-widget--clean-cell
                   (buffer-substring start (1- (point))))
                  cells)
            (setq start (point)))
          (when (< start end)
            (let ((tail (buffer-substring start end)))
              (unless (string-blank-p tail)
                (push (org-table-widget--clean-cell tail) cells)))))))
    (nreverse cells)))

(defun org-table-widget--parse (beg end)
  "Parse the Org table between BEG and END.
Return a plist with :rows, :alignments, :header-rows and :lines, or
nil when the region holds no data rows.  :lines holds, for each row,
the offset of its source line from the first line of the table."
  (let ((line 0)
        rows alignments cookie-row)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (cond
         ((looking-at-p org-table-hline-regexp)
          (push (cons line 'hline) rows))
         ((looking-at-p org-table-dataline-regexp)
          (let ((cells (org-table-widget--line-cells)))
            (cond
             ((org-table-widget--cookie-row-p cells) (setq cookie-row cells))
             ((org-table-widget--group-row-p cells))
             (t (push (cons line cells) rows))))))
        (forward-line 1)
        (setq line (1+ line))))
    (setq rows (nreverse rows))
    ;; Drop leading and trailing rules and merge adjacent ones.
    (while (eq (cdar rows) 'hline) (setq rows (cdr rows)))
    (setq rows (nreverse rows))
    (while (eq (cdar rows) 'hline) (setq rows (cdr rows)))
    (setq rows (nreverse rows))
    (let (merged previous)
      (dolist (row rows)
        (unless (and (eq (cdr row) 'hline) (eq previous 'hline))
          (push row merged))
        (setq previous (cdr row)))
      (setq rows (nreverse merged)))
    (when rows
      (let* ((lines (mapcar #'car rows))
             (rows (mapcar #'cdr rows))
             (columns (apply #'max (mapcar (lambda (row)
                                             (if (eq row 'hline) 0 (length row)))
                                           rows)))
             (header-rows (or (cl-position 'hline rows) 0)))
        (setq rows (mapcar (lambda (row)
                             (if (eq row 'hline)
                                 row
                               (append row (make-list (- columns (length row))
                                                      ""))))
                           rows))
        (setq alignments
              (cl-loop for column below columns
                       collect (or (and cookie-row
                                        (org-table-widget--cookie-alignment
                                         (or (nth column cookie-row) "")))
                                   'left)))
        (list :rows rows :alignments alignments :header-rows header-rows
              :lines lines)))))

;;;; Overlays

(defvar-local org-table-widget--overlays nil
  "Overlays drawing the rows of table widgets in the current buffer.
There is one overlay for each rendered row; the row point rests on is
left as source and has none.")

(defvar-local org-table-widget--row-index nil
  "Hash table mapping (BEG . LINE) to the overlay drawing that row.
BEG is the start of the row's table and LINE its source line offset.")

(defvar-local org-table-widget--render-cache nil
  "Table start positions mapped to (KEY WIDGET SPANS BEG END) entries.
SPANS is the laid-out table: (LINE STRING START END) for each row, where
LINE is the row's source line offset, STRING the text drawn for it and
START and END the buffer range it covers.  Only the most recent
rendering of each table is retained.")

(defvar-local org-table-widget--width nil
  "Window width in columns the widgets were last laid out for.")

(defvar-local org-table-widget--timer nil
  "Idle timer for a pending relayout.")

(defvar-local org-table-widget--revealed nil
  "Tables whose source `org-table-widget-toggle' reveals.
Each entry is a (BEG . END) cons.  Those tables stay as Org source until
point leaves them or the command runs on one of them again.")

(defvar-local org-table-widget--point-row nil
  "The (BEG . LINE) row whose source is shown because point rests on it.
That row has no overlay; the rest of its table stays drawn.")

(defvar-local org-table-widget--point-row-table nil
  "The table whose row point rested on before the current command.
That row has no overlay, so once an edit turns its line into something
other than a table row, neither the buffer text nor the overlays still
show which table the edit broke.  Recording the table beforehand lets
`org-table-widget--after-change' report the edit to it anyway.")

(defvar-local org-table-widget--dirty nil
  "Starts of the tables edited since their last layout.
Their rows keep the overlays they have until point moves through the
table or the relayout runs; the row point rests on stays as source.")

(defvar-local org-table-widget--previous-point nil
  "Marker recording point before the current command.")

(defun org-table-widget--window ()
  "Return the window to lay tables out for, or nil."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (or (and (memq (selected-window) windows) (selected-window))
        (car windows))))

(defun org-table-widget--layout-width (window)
  "Return the column width available for widgets in WINDOW."
  (if (window-live-p window)
      (apply #'min (mapcar #'window-body-width
                           (get-buffer-window-list (current-buffer) nil t)))
    80))

(defun org-table-widget--tables ()
  "Return (BEG . END) for every Org table in the accessible buffer."
  (let (tables)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-table-any-line-regexp nil t)
        (if (org-at-table.el-p)
            (goto-char (org-table-end))
          (if (org-at-table-p)
              (let ((beg (org-table-begin))
                    (end (org-table-end)))
                (push (cons beg end) tables)
                (goto-char end))
            (forward-line 1)))))
    (nreverse tables)))

;;;; Overlay bookkeeping

(defun org-table-widget--overlay-at (position)
  "Return the widget row overlay covering POSITION, or nil."
  (seq-find (lambda (overlay) (overlay-get overlay 'org-table-widget-row))
            (overlays-in position (1+ position))))

(defun org-table-widget--table-overlays (beg)
  "Return the row overlays drawn for the table starting at BEG.
They are in buffer order."
  (sort (seq-filter (lambda (overlay)
                      (and (overlay-buffer overlay)
                           (eql (overlay-get overlay 'org-table-widget-table)
                                beg)))
                    org-table-widget--overlays)
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun org-table-widget--segments (overlay)
  "Return the overlays drawing the table OVERLAY is part of, in order."
  (org-table-widget--table-overlays
   (overlay-get overlay 'org-table-widget-table)))

(defun org-table-widget--drop-table (beg)
  "Delete every row overlay drawn for the table starting at BEG."
  (when beg
    (setq org-table-widget--dirty (delq beg org-table-widget--dirty))
    (when org-table-widget--row-index
      (maphash (lambda (key overlay)
                 (when (eql (car key) beg)
                   (delete-overlay overlay)
                   (remhash key org-table-widget--row-index)))
               org-table-widget--row-index))
    (setq org-table-widget--overlays
          (seq-filter #'overlay-buffer org-table-widget--overlays))))

(defun org-table-widget--remove-overlay (overlay)
  "Delete the row overlays drawing the table OVERLAY is part of."
  (org-table-widget--drop-table (overlay-get overlay 'org-table-widget-table)))

(defun org-table-widget--invalidate-render-cache (&rest _)
  "Discard laid-out tables after edits, including edits to revealed source.
An edit can move subsequent table starts, so discard all position keys.
The row overlays live on until the next relayout redraws them."
  (setq org-table-widget--render-cache nil))

(defun org-table-widget--modified (overlay &rest _)
  "Plan a relayout of the edited table under OVERLAY.
The rows keep their overlays, so the drawing around the edit stays as it
was until the table is laid out again."
  (when (overlay-buffer overlay)
    (with-current-buffer (overlay-buffer overlay)
      (org-table-widget--edited (overlay-get overlay 'org-table-widget-table)))))

(defun org-table-widget--edited (beg)
  "Note that the table starting at BEG was edited.
The rows of the table keep the overlays they have, so the rest of the
table stays drawn while the row point rests on is edited as source.  An
edit can change a column's width, and every row is drawn from the widths
of all the table's cells, so the table is laid out again.

That happens once point leaves the edited row, not while it stays
there: laying the table out mid-edit would redraw the rows around the
cursor and make the table jump under the person typing.  Waiting for
point to move also covers a whole run of edits, however long, with a
single layout.  The drawing the other rows keep until then is the one
they had when the edit began."
  (add-to-list 'org-table-widget--dirty beg)
  (org-table-widget--invalidate-render-cache))

(defun org-table-widget--edited-p (beg)
  "Return non-nil when an edit touched the table starting at BEG."
  (or (org-table-widget--table-overlays beg)
      (and org-table-widget--render-cache
           (gethash beg org-table-widget--render-cache))))

(defun org-table-widget--point-row-table-at (_beg _end)
  "Return the table point rested in before the current command, or nil.
The row point rests on keeps no overlay, so a deletion on it is reported
by neither the buffer text, once the line no longer reads as a table
row, nor by an overlay.  Remembering the table from before the command
lets that edit reach it."
  (when-let* ((beg org-table-widget--point-row-table)
              ((org-table-widget--table-still-starts-p beg)))
    beg))

(defun org-table-widget--table-still-starts-p (beg)
  "Return non-nil when BEG is still the start of a table in the buffer.
An edit may have turned the line at BEG into something else, or removed
it altogether, while the table it used to start is still drawn."
  (save-excursion
    (goto-char (min beg (point-max)))
    (org-at-table-p)))

(defun org-table-widget--after-change (beg end &rest _)
  "Note that an edit between BEG and END touched a table.
The row point rests on has no overlay, so an edit inside it is reported
here rather than by an overlay hook.  Look for the table at the edit, in
the overlays covering it, and in the table point rested in before the
command, instead of scanning the buffer."
  (when org-table-widget-mode
    (let* ((beg (min beg (point-max)))
           (end (min end (point-max)))
           (table (or (org-table-widget--table-at beg)
                      (org-table-widget--table-at end)
                      (org-table-widget--point-row-table-at beg end)
                      (when-let* ((overlay
                                   (seq-find
                                    (lambda (overlay)
                                      (and (overlay-buffer overlay)
                                           ;; A deletion reports BEG equal to
                                           ;; END, so an overlay that starts
                                           ;; exactly there still covers the
                                           ;; edit; a strict comparison would
                                           ;; miss it and leave the table's
                                           ;; layout pointing at moved source.
                                           (<= (overlay-start overlay) end)
                                           (> (overlay-end overlay) beg)))
                                    org-table-widget--overlays)))
                        (overlay-get overlay 'org-table-widget-table)))))
      (when (and table (org-table-widget--edited-p table))
        (org-table-widget--edited table)))))

(defconst org-table-widget--layout-gc-threshold (* 64 1024 1024)
  "Minimum GC allocation threshold while building a table widget.")

;;;; Layout

(defun org-table-widget--table-key (beg end window width)
  "Return a cache key for the table between BEG and END in WINDOW.
WIDTH is the number of columns the table is laid out at.  The key
covers every layout input other than the table text: window geometry,
fonts, prefixes and the options that change the drawing."
  (list (secure-hash 'sha1 (current-buffer) beg end)
        ;; Preserve changes to faces, hidden links and other properties
        ;; even when source characters stay the same.
        (sxhash-equal-including-properties (buffer-substring beg end))
        width
        (window-body-width window)
        (window-body-width window t)
        (org-table-widget--prefix-width beg window)
        (org-table-widget--line-number-width window)
        (org-table-widget--reserves-continuation-p window)
        (org-table-widget--font-signature window)
        org-table-widget-zebra-stripe org-table-widget-wrap-columns
        org-table-widget-max-width-fraction
        (copy-sequence org-table-widget-cell-properties)))

(defun org-table-widget--row-spans (beg end rows)
  "Return (LINE STRING START END) for each rendering of ROWS in BEG..END.
ROWS is a list of (LINE . STRING) in source order.  A row covers its
source line and, up to the next row, the lines without a rendering of
their own such as alignment cookies."
  (let ((line 0)
        entries)
    (save-excursion
      (goto-char beg)
      (dolist (row rows)
        (forward-line (- (car row) line))
        (setq line (car row))
        (push (list (car row) (cdr row) (point)) entries)))
    (setq entries (nreverse entries))
    ;; The first row covers any leading rule the parser dropped, so that
    ;; every line of the table is replaced by a row.
    (let ((bounds (append (mapcar #'cl-third entries) (list end))))
      (when bounds (setcar bounds beg))
      (cl-loop for entry in entries
               for start in bounds
               for next in (cdr bounds)
               collect (list (nth 0 entry) (nth 1 entry) start next)))))

(defun org-table-widget--layout-table (beg end window width)
  "Return the laid-out rows of the table between BEG and END in WINDOW.
WINDOW is used at WIDTH columns.  The result is a list of
\\(LINE STRING START END), one for each row, or nil when the region holds
no table.  Layout is cached per table and reused across relayouts."
  (let ((gc-cons-threshold (max gc-cons-threshold
                                org-table-widget--layout-gc-threshold)))
    (font-lock-ensure beg end)
    (unless org-table-widget--render-cache
      (setq org-table-widget--render-cache (make-hash-table :test 'eql)))
    (let* ((column-pixels (max 1 (or (ignore-errors (window-font-width window))
                                     (frame-char-width (window-frame window)))))
           (prefix (org-table-widget--prefix-width beg window))
           ;; Line prefixes, line numbers and a reserved continuation
           ;; column narrow the space the table's lines can use.
           (inset (+ prefix
                     (org-table-widget--line-number-width window)
                     (if (org-table-widget--reserves-continuation-p window)
                         column-pixels
                       0)))
           (columns (max 1 (- width (ceiling inset column-pixels))))
           (pixel-budget (max 1 (- (org-table-widget--pixel-budget width window)
                                   inset)))
           (key (org-table-widget--table-key beg end window width))
           (cached (gethash beg org-table-widget--render-cache)))
      (unless (equal key (car cached))
        (setq cached nil)
        (when-let* ((table (org-table-widget--parse beg end)))
          (let* ((widget (widget-convert 'org-table-widget :value table
                                         :window window
                                         :pixel-budget pixel-budget))
                 (rows (org-table-widget--rows
                        (textui-layout-widget widget columns)))
                 (spans (org-table-widget--row-spans beg end rows)))
            (widget-put widget :sticky-header
                        (org-table-widget--sticky-header table spans))
            (setq cached (list key widget spans beg end))))
        (puthash beg cached org-table-widget--render-cache))
      (when cached
        (let ((widget (nth 1 cached)))
          (widget-put widget :window window)
          ;; Measured here: the header line cannot measure during redisplay.
          (widget-put widget :sticky-indent prefix))
        cached))))

(defun org-table-widget--rows (rendered)
  "Split RENDERED, one line per row, into (LINE . STRING) pairs.
RENDERED is the TextUI rendering of a table; lines a row wraps into stay
with that row, and their text is joined with newlines."
  (let (rows)
    (dolist (text (split-string rendered "\n"))
      (unless (string-empty-p text)
        (let ((line (or (get-text-property 0 'org-table-widget-line text) 0)))
          (if (eql line (caar rows))
              (push text (cdar rows))
            (push (list line text) rows)))))
    (nreverse (mapcar (lambda (row)
                        (cons (car row)
                              (string-join (nreverse (cdr row)) "\n")))
                      rows))))

(defun org-table-widget--table-at (position)
  "Return the start of the Org table containing POSITION, or nil."
  (save-excursion
    (goto-char position)
    (when (org-at-table-p)
      (org-table-begin))))

(defun org-table-widget--row-line (position)
  "Return the source line offset of POSITION within its table, or nil."
  (when-let* ((beg (org-table-widget--table-at position)))
    (save-excursion
      (goto-char beg)
      (let ((start (line-number-at-pos)))
        (goto-char position)
        (- (line-number-at-pos) start)))))

(defun org-table-widget--row-at-position (position)
  "Return the (BEG . LINE) row POSITION is in, or nil."
  (when-let* ((beg (org-table-widget--table-at position))
              (line (org-table-widget--row-line position)))
    (cons beg line)))

(defun org-table-widget--revealed-p (beg)
  "Return non-nil when the table starting at BEG is revealed."
  (seq-some (lambda (table) (eql (car table) beg))
            org-table-widget--revealed))

;;;; Drawing rows

(defun org-table-widget--make-row-overlay (beg span widget)
  "Draw SPAN, a row of the table starting at BEG, and return its overlay.
WIDGET is the laid-out table the rendering of the row belongs to."
  (let ((overlay (make-overlay (nth 2 span) (nth 3 span) nil t nil))
        (line (car span)))
    (overlay-put overlay 'org-table-widget-row t)
    (overlay-put overlay 'org-table-widget-table beg)
    (overlay-put overlay 'org-table-widget widget)
    (overlay-put overlay 'org-table-widget-line line)
    ;; Unlike replacement strings, before-strings honor pixel spaces.
    (overlay-put overlay 'before-string (nth 1 span))
    ;; Point cannot rest where a replacement starts, so the row's final
    ;; newline, or a space when it has none, replaces the source.  Each row
    ;; gets a string of its own: redisplay extends a replacement to the next
    ;; change of the `display' value and compares values with `eq', so one
    ;; shared literal would replace a whole table as a single stretch.
    (overlay-put overlay 'display
                 (copy-sequence (if (eq (char-before (nth 3 span)) ?\n)
                                    "\n" " ")))
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'modification-hooks
                 (list #'org-table-widget--modified))
    (overlay-put overlay 'insert-in-front-hooks
                 (list #'org-table-widget--modified))
    (unless org-table-widget--row-index
      (setq org-table-widget--row-index (make-hash-table :test 'equal)))
    (puthash (cons beg line) overlay org-table-widget--row-index)
    (push overlay org-table-widget--overlays)
    overlay))

(defun org-table-widget--row-overlay (row)
  "Return the overlay drawing ROW, a (BEG . LINE) pair, or nil."
  (when (and org-table-widget--row-index row)
    (let ((overlay (gethash row org-table-widget--row-index)))
      (and overlay (overlay-buffer overlay) overlay))))

(defun org-table-widget--hide-row (row)
  "Delete the overlay drawing ROW, a (BEG . LINE) pair."
  (when-let* ((overlay (org-table-widget--row-overlay row)))
    (delete-overlay overlay)
    (remhash row org-table-widget--row-index)
    (setq org-table-widget--overlays
          (delq overlay org-table-widget--overlays))))

(defun org-table-widget--table-layout (beg)
  "Return the layout of the table starting at BEG, laying it out if needed."
  (or (and org-table-widget--render-cache
           (gethash beg org-table-widget--render-cache))
      (when-let* ((table (seq-find (lambda (table) (eql (car table) beg))
                                   (org-table-widget--tables)))
                  (window (org-table-widget--window)))
        (org-table-widget--layout-table
         beg (cdr table) window
         (or org-table-widget--width
             (org-table-widget--layout-width window))))))

(defun org-table-widget--span-table-p (span)
  "Return non-nil when SPAN begins on a line of table text.
An edit can turn the row a span was laid out for into something else, or
move it, leaving the span over the lines below.  Drawing that span back
would put those lines' text where the edited row is."
  (let ((start (nth 2 span)))
    (and (integer-or-marker-p start)
         (<= start (point-max))
         (save-excursion
           (goto-char start)
           (org-at-table-p)))))

(defun org-table-widget--show-row (row)
  "Draw ROW, a (BEG . LINE) pair, when its table is not revealed.
The row's rendering comes from the table's last layout, so drawing it
again costs no measuring.  A layout that no longer matches the buffer,
as after an edit moved or broke the row, is left out: the table is laid
out again once point leaves the edited row, and its rows are drawn from
that layout."
  (when (and row
             (not (org-table-widget--revealed-p (car row)))
             (not (org-table-widget--row-overlay row)))
    (when-let* ((cached (org-table-widget--table-layout (car row)))
                (span (seq-find (lambda (span) (eql (car span) (cdr row)))
                                (nth 2 cached)))
                ((org-table-widget--span-table-p span)))
      (org-table-widget--make-row-overlay (car row) span (nth 1 cached)))))

(defun org-table-widget--display-table (beg end window width)
  "Draw the table between BEG and END for WINDOW at WIDTH columns.
Each row gets an overlay of its own.  Return the overlay of the first
row.  Revealing the row point rests on is left to
`org-table-widget--sync-row', so that a caller may draw a table without
looking at point."
  (when-let* ((cached (org-table-widget--layout-table beg end window width))
              (widget (nth 1 cached))
              (spans (nth 2 cached)))
    (org-table-widget--drop-table beg)
    (unless (org-table-widget--revealed-p beg)
      (let (first)
        (dolist (span spans)
          (let ((overlay (org-table-widget--make-row-overlay
                          beg span widget)))
            (setq first (or first overlay))))
        first))))

(defun org-table-widget--clear ()
  "Remove every widget overlay from the current buffer."
  (mapc #'delete-overlay org-table-widget--overlays)
  (setq org-table-widget--overlays nil
        org-table-widget--row-index nil
        org-table-widget--point-row nil
        org-table-widget--dirty nil))

(defun org-table-widget--renderable-p (window)
  "Return non-nil when widgets may be rendered in WINDOW."
  (and (window-live-p window)
       (or org-table-widget-enable-in-terminal
           (display-graphic-p (window-frame window)))))

(defun org-table-widget-refresh ()
  "Lay out every table in the current buffer as a widget.
The row point rests on keeps its source visible; a table revealed with
`org-table-widget-toggle' stays as source."
  (interactive)
  (org-table-widget--cancel-relayout)
  (org-table-widget--clear)
  (let ((window (org-table-widget--window)))
    (when (org-table-widget--renderable-p window)
      (let ((width (org-table-widget--layout-width window)))
        (save-excursion
          (dolist (table (org-table-widget--tables))
            (unless (org-table-widget--revealed-p (car table))
              (org-table-widget--display-table (car table) (cdr table)
                                               window width))))
        (setq org-table-widget--width width))))
  (setq org-table-widget--point-row nil)
  (org-table-widget--sync-row)
  (org-table-widget--update-sticky-header))

(defun org-table-widget--draw-table (beg)
  "Draw the whole table starting at BEG, except the row point rests on."
  (when-let* ((end (save-excursion
                     (goto-char beg)
                     (org-table-end)))
              (window (org-table-widget--window)))
    (org-table-widget--display-table
     beg end window
     (or org-table-widget--width
         (org-table-widget--layout-width window)))))

(defun org-table-widget--lay-out-edited (beg)
  "Lay the edited table starting at BEG out again, unless it is revealed.
BEG leaves the dirty list, so point moving around the table does not lay
it out a second time.  A table the edit left without a start is simply
cleared, since it can no longer be parsed from that position."
  (let ((revealed (org-table-widget--revealed-p beg)))
    (org-table-widget--drop-table beg)
    (unless revealed
      (org-table-widget--draw-table beg))))

(defun org-table-widget--sync-row ()
  "Keep the drawn rows in step with point.
Draw the row point left, delete the row point arrived on, and draw a
table again after an edit dropped its rows.  A move inside a table
touches two rows: the rest of the table keeps the overlays it has."
  (let* ((beg (org-table-widget--table-at (point)))
         (row (and beg (org-table-widget--row-at-position (point))))
         (previous org-table-widget--point-row)
         (previous-point (and (markerp org-table-widget--previous-point)
                              (marker-position
                               org-table-widget--previous-point)))
         (previous-line (and previous-point
                             (line-number-at-pos previous-point))))
    ;; An edit can leave the table point rested in no longer starting where
    ;; its rows were laid out from, as deleting the leading pipe of its first
    ;; row or the newline before it does.  Every span of that layout then
    ;; covers other text, so drop the table instead of drawing its rows back
    ;; over the line point is editing; it is laid out again from the buffer.
    (when (and previous
               (not (org-table-widget--revealed-p (car previous)))
               (not (org-table-widget--table-still-starts-p (car previous))))
      (org-table-widget--drop-table (car previous))
      (setq previous nil))
    ;; Lay edited tables out once point has left the line it was edited on,
    ;; rather than as the characters arrive.  Redrawing the table under the
    ;; cursor while it is being typed into makes the rows around it jump, and
    ;; a run of edits then costs one layout instead of one per character.
    (when (and org-table-widget--dirty
               (or (null previous-line)
                   (/= previous-line (line-number-at-pos))))
      (dolist (table (copy-sequence org-table-widget--dirty))
        (org-table-widget--lay-out-edited table)))
    ;; A table whose rows an edit dropped is drawn again even while point
    ;; stays on the row being edited, so the rows around it never stay stale.
    (when (and beg
               (not (org-table-widget--revealed-p beg))
               (null (org-table-widget--table-overlays beg)))
      (org-table-widget--draw-table beg))
    ;; Both calls are no-ops when the row is already in the wanted state,
    ;; so a relayout that redrew the row under point is corrected here.
    (setq org-table-widget--point-row row)
    (unless (equal row previous)
      (org-table-widget--show-row previous))
    (when row
      (org-table-widget--hide-row row))))

(defun org-table-widget--forget-revealed ()
  "Draw a revealed table again once point has left it."
  (when org-table-widget--revealed
    (let* ((point (point))
           (window (org-table-widget--window))
           (width (or org-table-widget--width
                      (org-table-widget--layout-width window))))
      (dolist (table (copy-sequence org-table-widget--revealed))
        (unless (and (>= point (car table)) (< point (cdr table)))
          (setq org-table-widget--revealed
                (delq table org-table-widget--revealed))
          (when (org-table-widget--renderable-p window)
            (org-table-widget--display-table (car table) (cdr table)
                                             window width)))))))

(defun org-table-widget--cancel-relayout ()
  "Cancel a pending relayout."
  (when org-table-widget--timer
    (cancel-timer org-table-widget--timer)
    (setq org-table-widget--timer nil)))

(defun org-table-widget--run-relayout (buffer)
  "Relayout BUFFER's widgets when its window width changed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq org-table-widget--timer nil)
      (when org-table-widget-mode
        (org-table-widget-refresh)))))

(defun org-table-widget--schedule-relayout ()
  "Relayout after the window configuration settles."
  (when org-table-widget-mode
    (org-table-widget--cancel-relayout)
    (if (<= org-table-widget-relayout-delay 0)
        (org-table-widget--run-relayout (current-buffer))
      (setq org-table-widget--timer
            (run-with-idle-timer org-table-widget-relayout-delay nil
                                 #'org-table-widget--run-relayout
                                 (current-buffer))))))

(defun org-table-widget--window-changed ()
  "Schedule a relayout when the window width changed."
  (let ((window (org-table-widget--window)))
    (when (and (window-live-p window)
               (not (equal (org-table-widget--layout-width window)
                           org-table-widget--width)))
      (org-table-widget--schedule-relayout))))

;;;; Sticky header

(defconst org-table-widget--sticky-header-format
  '(:eval (org-table-widget--sticky-header-line))
  "The `header-line-format' installed while a table header is scrolled past.")

(defvar-local org-table-widget--saved-header-line nil
  "The `header-line-format' the sticky header replaced.")

(defun org-table-widget--escape-mode-line (string)
  "Return STRING with every `%' doubled, keeping its text properties.
Header line constructs read `%' as the start of a directive."
  (let ((start 0)
        parts)
    (while (string-match "%" string start)
      (push (substring string start (match-end 0)) parts)
      (push (substring string (match-beginning 0) (match-end 0)) parts)
      (setq start (match-end 0)))
    (push (substring string start) parts)
    (apply #'concat (nreverse parts))))

(defun org-table-widget--sticky-header (table spans)
  "Return the header line string for TABLE displayed as SPANS, or nil.
SPANS is the result of `org-table-widget--layout-table'.  Its first row
holds the header, of which only the first line fits in a header line.
Return nil when TABLE has no header."
  (when-let* (((> (plist-get table :header-rows) 0))
              (line (car (split-string (nth 1 (car spans)) "\n"))))
    (remove-list-of-text-properties 0 (length line)
                                    '(cursor org-table-widget-line) line)
    ;; Header line text takes unspecified attributes from the `header-line'
    ;; face.  Take them from the buffer's remapped default face instead, so
    ;; the columns keep the widths of the rows below, text scaling included.
    (add-face-text-property 0 (length line) 'default t line)
    (org-table-widget--escape-mode-line line)))

(defun org-table-widget--sticky-widget (window &optional start)
  "Return the widget whose header WINDOW has scrolled past, or nil.
That is the widget drawn from START, which defaults to WINDOW's start,
when it has a header and its first row starts above START."
  (let ((start (or start (window-start window))))
    (when-let* ((overlay (org-table-widget--overlay-at start))
                (widget (overlay-get overlay 'org-table-widget))
                ((widget-get widget :sticky-header))
                (first (car (org-table-widget--table-overlays
                             (overlay-get overlay 'org-table-widget-table))))
                ((> start (overlay-start first))))
      widget)))

(defun org-table-widget--sticky-header-line ()
  "Return the header line of the selected window.
Show the header of the table the window has scrolled past, aligned with
the table's columns, or else the header line the sticky header replaced."
  (if-let* ((widget (org-table-widget--sticky-widget (selected-window))))
      (concat (propertize " " 'display
                          `(space :align-to
                                  (,(+ (line-number-display-width t)
                                       (widget-get widget :sticky-indent)))))
              (widget-get widget :sticky-header))
    org-table-widget--saved-header-line))

(defun org-table-widget--update-sticky-header (&optional window start)
  "Install the sticky header while a window has scrolled past a table header.
Otherwise restore the header line it replaced, so no empty header line
is left behind.  WINDOW, when non-nil, is about to be displayed from
START, as for `window-scroll-functions'."
  (let ((installed (eq header-line-format
                       org-table-widget--sticky-header-format)))
    (if (and org-table-widget-mode
             org-table-widget-sticky-header
             (seq-some (lambda (shown)
                         (org-table-widget--sticky-widget
                          shown (and (eq shown window) start)))
                       (get-buffer-window-list (current-buffer) nil t)))
        (unless installed
          (setq org-table-widget--saved-header-line header-line-format
                header-line-format org-table-widget--sticky-header-format))
      (when installed
        (setq header-line-format org-table-widget--saved-header-line
              org-table-widget--saved-header-line nil)))))

(defun org-table-widget--indent-initialized (buffer)
  "Lay BUFFER's widgets out again once `org-indent-mode' has prefixed it.
The mode adds its line prefixes from an idle timer, usually after the
widgets were laid out without them, so tables would overrun the window
by one indentation.  Relayout from a timer of our own: org-indent runs
this hook with the buffer widened."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (org-table-widget--schedule-relayout))))

(defun org-table-widget--pre-command ()
  "Record point so line motion that skipped rows can be noticed.
Also remember the table point rests in: the row under point carries no
overlay, so once an edit turns that row into something other than table
text, this is the only record left of which table the edit broke."
  (set-marker org-table-widget--previous-point (point))
  (setq org-table-widget--point-row-table (org-table-widget--table-at (point))))

(defconst org-table-widget--line-motion-commands
  '(previous-line next-line
    evil-previous-line evil-next-line
    evil-previous-visual-line evil-next-visual-line)
  "Commands that move point by lines.
Evil sets `this-command' to `next-line' in jumps such as gg and G, so
the command invoked is checked as well.")

(defun org-table-widget--stop-on-row (previous)
  "Stop point on a widget row the line motion from PREVIOUS stepped over.
Display-based motion counts a widget row as a single character, so it can
cross several rows at once while the rows are drawn.  Return the row
nearest PREVIOUS when one was crossed, or nil."
  (let* ((point (point))
         (forward (> point previous))
         (low (min point previous))
         (high (max point previous))
         stop)
    (dolist (overlay (overlays-in low high))
      (when-let* (((overlay-get overlay 'org-table-widget-row))
                  (start (overlay-start overlay))
                  ((> start low))
                  ((< start high))
                  ;; Folded rows are stepped over by native line motion.
                  ((not (invisible-p start))))
        (setq stop (if forward
                       (if stop (min stop start) start)
                     (if stop (max stop start) start)))))
    (when stop
      (goto-char stop))))

(defun org-table-widget--post-command ()
  "Keep point and the table row overlays in step after a command.
The row point rests on keeps its source visible while the rows around it
stay drawn, so moving through a table deletes the overlay of the row point
arrives on and draws the one it left, one row at a time."
  (let ((previous (and org-table-widget--previous-point
                       (marker-position org-table-widget--previous-point))))
    (when (and previous
               (memq this-command '(previous-line next-line))
               (memq real-this-command org-table-widget--line-motion-commands)
               (eql (abs (prefix-numeric-value current-prefix-arg)) 1))
      (org-table-widget--stop-on-row previous)))
  (org-table-widget--sync-row)
  (org-table-widget--forget-revealed)
  (org-table-widget--update-sticky-header))

(defun org-table-widget-toggle ()
  "Toggle the widget for the table at point.
A drawn table becomes editable source; a table left as source is drawn
again, keeping the row point rests on as source."
  (interactive)
  (let* ((beg (org-table-widget--table-at (point)))
         (table (and beg (seq-find (lambda (table) (eql (car table) beg))
                                   (org-table-widget--tables))))
         (window (org-table-widget--window)))
    (unless (and beg table)
      (user-error "Not at an Org table"))
    (if (org-table-widget--revealed-p beg)
        (progn
          (setq org-table-widget--revealed
                (seq-remove (lambda (revealed) (eql (car revealed) beg))
                            org-table-widget--revealed))
          (org-table-widget--display-table
           beg (cdr table) (or window (selected-window))
           (or org-table-widget--width
               (org-table-widget--layout-width window))))
      (org-table-widget--drop-table beg)
      (push (cons beg (cdr table)) org-table-widget--revealed)
      (setq org-table-widget--point-row nil)))
  (org-table-widget--sync-row)
  (org-table-widget--update-sticky-header))

(defun org-table-widget--before-major-mode-change ()
  "Release previews and pending work before buffer-local state is reset."
  (org-table-widget-mode -1))

;;;###autoload
(define-minor-mode org-table-widget-mode
  "Show Org tables as responsive pixel-aligned widgets.
The buffer text is left untouched; each table row is covered by an
overlay displaying its row of the widget, in the shape Org gives the
table itself.  The row point rests on keeps its source, so it can be
read and edited in place while the rest of the table stays drawn."
  :lighter " OTW"
  (if org-table-widget-mode
      (progn
        (unless (derived-mode-p 'org-mode)
          (setq org-table-widget-mode nil)
          (user-error "Org table widgets require Org mode"))
        (unless (require 'textui nil t)
          (setq org-table-widget-mode nil)
          (user-error "Org table widgets require TextUI"))
        ;; Reverting normally reinitializes Org mode.  Overlays can survive
        ;; that reset even though the buffer-local ownership list does not.
        (add-hook 'change-major-mode-hook
                  #'org-table-widget--before-major-mode-change nil t)
        (add-hook 'after-change-functions
                  #'org-table-widget--after-change nil t)
        (unless org-table-widget--previous-point
          (setq org-table-widget--previous-point (make-marker)))
        (add-hook 'pre-command-hook #'org-table-widget--pre-command nil t)
        (add-hook 'post-command-hook #'org-table-widget--post-command nil t)
        (add-hook 'window-configuration-change-hook
                  #'org-table-widget--window-changed nil t)
        (add-hook 'text-scale-mode-hook #'org-table-widget--schedule-relayout
                  nil t)
        (add-hook 'display-line-numbers-mode-hook
                  #'org-table-widget--schedule-relayout nil t)
        (add-hook 'window-scroll-functions
                  #'org-table-widget--update-sticky-header nil t)
        (add-hook 'org-indent-post-buffer-init-functions
                  #'org-table-widget--indent-initialized nil t)
        (org-table-widget-refresh))
    (remove-hook 'change-major-mode-hook
                 #'org-table-widget--before-major-mode-change t)
    (remove-hook 'after-change-functions
                 #'org-table-widget--after-change t)
    (org-table-widget--invalidate-render-cache)
    (remove-hook 'pre-command-hook #'org-table-widget--pre-command t)
    (when org-table-widget--previous-point
      (set-marker org-table-widget--previous-point nil)
      (setq org-table-widget--previous-point nil))
    (remove-hook 'post-command-hook #'org-table-widget--post-command t)
    (remove-hook 'window-configuration-change-hook
                 #'org-table-widget--window-changed t)
    (remove-hook 'text-scale-mode-hook #'org-table-widget--schedule-relayout t)
    (remove-hook 'display-line-numbers-mode-hook
                 #'org-table-widget--schedule-relayout t)
    (remove-hook 'window-scroll-functions
                 #'org-table-widget--update-sticky-header t)
    (remove-hook 'org-indent-post-buffer-init-functions
                 #'org-table-widget--indent-initialized t)
    (org-table-widget--cancel-relayout)
    (org-table-widget--clear)
    (org-table-widget--update-sticky-header)))

(provide 'org-table-widget)
;;; org-table-widget.el ends here
