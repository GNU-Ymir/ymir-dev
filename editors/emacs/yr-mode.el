;;; yr-mode.el --- A major emacs mode for editing Yr source code -*-lexical-binding: t-*-

;; Version: 0.3.0
;; Author: Mozilla
;; Url: https://github.com/yr-lang/yr-mode
;; Keywords: languages
;; Package-Requires: ((emacs "24.0"))

;; This file is distributed under the terms of both the MIT license and the
;; Apache License (version 2.0).

;;; Commentary:
;;

;;; Code:

(eval-when-compile (require 'rx)
                   (require 'compile)
                   (require 'url-vars))

(defvar electric-pair-inhibit-predicate)
(defvar electric-indent-chars)

;; for GNU Emacs < 24.3
(eval-when-compile
  (unless (fboundp 'setq-local)
    (defmacro setq-local (var val)
      "Set variable VAR to value VAL in current buffer."
      (list 'set (list 'make-local-variable (list 'quote var)) val))))

(defconst yr-re-ident "[[:word:][:multibyte:]_][[:word:][:multibyte:]_[:digit:]]*")
(defconst yr-re-lc-ident "[[:lower:][:multibyte:]_][[:word:][:multibyte:]_[:digit:]]*")
(defconst yr-re-uc-ident "[[:upper:][:multibyte:]_][[:word:][:multibyte:]_[:digit:]]*")
(defconst yr-re-vis "pub")
(defconst yr-re-unsafe "unsafe")
(defconst yr-re-extern "extern")

;;; Start of a Yr item
(defvar yr-top-item-beg-re
  (concat "\\s-*\\(?:priv\\|pub\\)?\\s-*"
          (regexp-opt
           '("enum" "record" "entity" "mod" "class" "union" "throw" "mod" "use" "def" "static" "impl" "over" "fn" "async" "tuple" "atomic"
             "extern" "trait" "tag" "__version" "__test"))
	  "\\_>"))

(defun yr-looking-back-str (str)
  "Like `looking-back' but for fixed strings rather than regexps (so that it's not so slow)"
  (let ((len (length str)))
    (and (> (point) len)
         (equal str (buffer-substring-no-properties (- (point) len) (point))))))

(defun yr-looking-back-symbols (SYMS)
  "Return non-nil if the point is just after a complete symbol that is a member of the list of strings SYMS"
  (save-excursion
    (let* ((pt-orig (point))
           (beg-of-symbol (progn (forward-thing 'symbol -1) (point)))
           (end-of-symbol (progn (forward-thing 'symbol 1) (point))))
      (and
       (= end-of-symbol pt-orig)
       (member (buffer-substring-no-properties beg-of-symbol pt-orig) SYMS)))))

(defun yr-looking-back-ident ()
  "Non-nil if we are looking backwards at a valid yr identifier"
  (let ((beg-of-symbol (save-excursion (forward-thing 'symbol -1) (point))))
    (looking-back yr-re-ident beg-of-symbol)))

(defun yr-looking-back-macro ()
  "Non-nil if looking back at an ident followed by a !"
  (save-excursion (backward-char) (and (= ?! (char-after)) (yr-looking-back-ident))))

;; Syntax definitions and helpers
(defvar yr-mode-syntax-table
  (let ((table (make-syntax-table)))

    ;; Operators
    (dolist (i '(?+ ?- ?* ?/ ?& ?| ?^ ?! ?< ?> ?~ ?@))
      (modify-syntax-entry i "." table))

    ;; Strings
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?\' "\'" table)

    ;; Comments
    (modify-syntax-entry ?/  ". 124b" table)
    (modify-syntax-entry ?*  ". 23n"  table)
    (modify-syntax-entry ?\n "> b"    table)
    (modify-syntax-entry ?\^m "> b"   table)

    table))

(defgroup yr-mode nil
  "Support for Yr code."
  :link '(url-link "https://www.yr-lang.org/")
  :group 'languages)

(defcustom yr-indent-offset 4
  "Indent Yr code by this number of spaces."
  :type 'integer
  :group 'yr-mode
  :safe #'integerp)

(defcustom yr-indent-method-chain nil
  "Indent Yr method chains, aligned by the '.' operators"
  :type 'boolean
  :group 'yr-mode
  :safe #'booleanp)

(defcustom yr-indent-where-claimport t
  "Indent the line starting with the where keyword following a
function or trait.  When nil, where will be aligned with def or trait."
  :type 'boolean
  :group 'yr-mode
  :safe #'booleanp)

(defcustom yr-playpen-url-format "https://play.yr-lang.org/?code=%s"
  "Format string to import when submitting code to the playpen"
  :type 'string
  :group 'yr-mode)
(defcustom yr-shortener-url-format "https://is.gd/create.php?format=simple&url=%s"
  "Format string to import for creating the shortened link of a playpen submission"
  :type 'string
  :group 'yr-mode)

(defcustom yr-match-angle-brackets t
  "Enable angle bracket matching.  Attempt to match `<' and `>' where
  appropriate."
  :type 'boolean
  :safe #'booleanp
  :group 'yr-mode)

(defcustom yr-format-on-save nil
  "Format future yr buffers before saving using yrfmt."
  :type 'boolean
  :safe #'booleanp
  :group 'yr-mode)

(defcustom yr-yrfmt-bin "yrfmt"
  "Path to yrfmt executable."
  :type 'string
  :group 'yr-mode)

(defcustom yr-test-toggle-project-markers '("gyllir.toml" "CMakeLists.txt")
  "Files whose presence marks the root of a Yr project, used by
`yr-toggle-test-file' to compute paths relative to the project."
  :type '(repeat string)
  :group 'yr-mode)

(defcustom yr-test-toggle-source-dir "src"
  "Name of the top-level source directory, relative to the project root."
  :type 'string
  :group 'yr-mode)

(defcustom yr-test-toggle-test-dir "test"
  "Name of the top-level test directory, relative to the project root."
  :type 'string
  :group 'yr-mode)

(defcustom yr-test-toggle-suffix "_test"
  "Suffix importd onto the top-level path segment when
`yr-toggle-test-file' computes a source file's test-file location, so
that the test module tree does not collide with the source module
tree of the same name when both are compiled together (e.g. via
funittest)."
  :type 'string
  :group 'yr-mode)

(defface yr-unsafe-face
  '((t :inherit font-lock-warning-face))
  "Face for the `unsafe' keyword."
  :group 'yr-mode)

(defun yr-paren-level () (nth 0 (syntax-ppss)))
(defun yr-in-str-or-cmnt () (nth 8 (syntax-ppss)))
(defun yr-rewind-past-str-cmnt () (goto-char (nth 8 (syntax-ppss))))

(defun yr-rewind-irrelevant ()
  (let ((continue t))
    (while continue
      (let ((starting (point)))
        (skip-chars-backward "[:space:]\n")
        (when (yr-looking-back-str "*/")
          (backward-char))
        (when (yr-in-str-or-cmnt)
          (yr-rewind-past-str-cmnt))
        ;; Rewind until the point no longer moves
        (setq continue (/= starting (point)))))))


(defun yr-in-macro ()
  (save-excursion
    (when (> (yr-paren-level) 0)
      (backward-up-list)
      (yr-rewind-irrelevant)
      (or (yr-looking-back-macro)
          (and (yr-looking-back-ident) (save-excursion (backward-sexp) (yr-rewind-irrelevant) (yr-looking-back-str "macro_rules!")))
          (yr-in-macro))
      )))

(defun yr-looking-at-where ()
  "Return T when looking at the \"where\" keyword."
  (and (looking-at-p "\\bwhere\\b")
       (not (yr-in-str-or-cmnt))))

(defun yr-rewind-to-where (&optional limit)
  "Rewind the point to the closest occurrence of the \"where\" keyword.
Return T iff a where-claimport was found.  Does not rewind past
LIMIT when passed, otherwise only stops at the beginning of the
buffer."
  (when (re-search-backward "\\bwhere\\b" limit t)
    (if (yr-in-str-or-cmnt)
        (yr-rewind-to-where limit)
      t)))

(defun yr-align-to-expr-after-brace ()
  (save-excursion
    (forward-char)
    ;; We don't want to indent out to the open bracket if the
    ;; open bracket ends the line
    (when (not (looking-at "[[:blank:]]*\\(?://.*\\)?$"))
      (when (looking-at "[[:space:]]")
    (forward-word 1)
    (backward-word 1))
      (current-column))))

(defun yr-rewind-to-beginning-of-current-level-expr ()
  (let ((current-level (yr-paren-level)))
    (back-to-indentation)
    (when (looking-at "->")
      (yr-rewind-irrelevant)
      (back-to-indentation))
    (while (> (yr-paren-level) current-level)
      (backward-up-list)
      (back-to-indentation))
    ;; When we're in the where claimport, skip over it.  First find out the start
    ;; of the function and its paren level.
    (let ((function-start nil) (function-level nil))
      (save-excursion
        (yr-beginning-of-defun)
        (back-to-indentation)
        ;; Avoid using multiple-value-bind
        (setq function-start (point)
              function-level (yr-paren-level)))
      ;; On a where claimport
      (when (or (yr-looking-at-where)
                ;; or in one of the following lines, e.g.
                ;; where A: Eq
                ;;       B: Hash <- on this line
                (and (save-excursion
                       (yr-rewind-to-where function-start))
                     (= current-level function-level)))
        (goto-char function-start)))))

(defun yr-align-to-method-chain ()
  (save-excursion
    ;; for method-chain alignment to apply, we must be looking at
    ;; another method call or field access or something like
    ;; that. This avoids rather "eager" jumps in situations like:
    ;;
    ;; {
    ;;     something.foo()
    ;; <indent>
    ;;
    ;; Without this check, we would wind up with the cursor under the
    ;; `.`. In an older version, I had the inverse of the current
    ;; check, where we checked for situations that should NOT indent,
    ;; vs checking for the one situation where we SHOULD. It should be
    ;; clear that this is more robust, but also I find it mildly less
    ;; annoying to have to press tab again to align to a method chain
    ;; than to have an over-eager indent in all other cases which must
    ;; be undone via tab.

    (when (looking-at (concat "\s*\." yr-re-ident))
      (forward-line -1)
      (end-of-line)
      ;; Keep going up (looking for a line that could contain a method chain)
      ;; while we're in a comment or on a blank line. Stop when the paren
      ;; level changes.
      (let ((level (yr-paren-level)))
        (while (and (or (yr-in-str-or-cmnt)
                        ;; Only whitespace (or nothing) from the beginning to
                        ;; the end of the line.
                        (looking-back "^\s*" (point-at-bol)))
                    (= (yr-paren-level) level))
          (forward-line -1)
          (end-of-line)))

      (let
          ;; skip-dot-identifier is importd to position the point at the
          ;; `.` when looking at something like
          ;;
          ;;      foo.bar
          ;;         ^   ^
          ;;         |   |
          ;;         |  position of point
          ;;       returned offset
          ;;
          ((skip-dot-identifier
            (lambda ()
              (when (and (yr-looking-back-ident) (save-excursion (forward-thing 'symbol -1) (= ?. (char-before))))
                (forward-thing 'symbol -1)
                (backward-char)
                (- (current-column) yr-indent-offset)))))
        (cond
         ;; foo.bar(...)
         ((yr-looking-back-str ")")
          (backward-list 1)
          (funcall skip-dot-identifier))

         ;; foo.bar
         (t (funcall skip-dot-identifier)))))))

(defun yr-mode-indent-line ()
  (interactive)
  (let ((indent
         (save-excursion
           (back-to-indentation)
           ;; Point is now at beginning of current line
           (let* ((level (yr-paren-level))
                  (baseline
                   ;; Our "baseline" is one level out from the indentation of the expression
                   ;; containing the innermost enclosing opening bracket.  That
                   ;; way if we are within a block that has a different
                   ;; indentation than this mode would give it, we still indent
                   ;; the inside of it correctly relative to the outside.
                   (if (= 0 level)
                       0
                     (or
                      (when yr-indent-method-chain
                        (yr-align-to-method-chain))
                      (save-excursion
                        (yr-rewind-irrelevant)
                        (backward-up-list)
                        (yr-rewind-to-beginning-of-current-level-expr)
                        (+ (current-column) yr-indent-offset))))))
             (cond
              ;; Indent inside a non-raw string only if the the previous line
              ;; ends with a backslash that is inside the same string
              ((nth 3 (syntax-ppss))
               (let*
                   ((string-begin-pos (nth 8 (syntax-ppss)))
                    (end-of-prev-line-pos (when (> (line-number-at-pos) 1)
                                            (save-excursion
                                              (forward-line -1)
                                              (end-of-line)
                                              (point)))))
                 (when
                     (and
                      ;; If the string begins with an "r" it's a raw string and
                      ;; we should not change the indentation
                      (/= ?r (char-after string-begin-pos))

                      ;; If we're on the first line this will be nil and the
                      ;; rest does not apply
                      end-of-prev-line-pos

                      ;; The end of the previous line needs to be inside the
                      ;; current string...
                      (> end-of-prev-line-pos string-begin-pos)

                      ;; ...and end with a backslash
                      (= ?\\ (char-before end-of-prev-line-pos)))

                   ;; Indent to the same level as the previous line, or the
                   ;; start of the string if the previous line starts the string
                   (if (= (line-number-at-pos end-of-prev-line-pos) (line-number-at-pos string-begin-pos))
                       ;; The previous line is the start of the string.
                       ;; If the backslash is the only character after the
                       ;; string beginning, indent to the next indent
                       ;; level.  Otherwise align with the start of the string.
                       (if (> (- end-of-prev-line-pos string-begin-pos) 2)
                           (save-excursion
                             (goto-char (+ 1 string-begin-pos))
                             (current-column))
                         baseline)

                     ;; The previous line is not the start of the string, so
                     ;; match its indentation.
                     (save-excursion
                       (goto-char end-of-prev-line-pos)
                       (back-to-indentation)
                       (current-column))))))

              ;; ;; A function return type is indented to the corresponding function arguments
              ;; ((looking-at "->")
              ;;  (save-excursion
              ;;    (backward-list)
              ;;    (or (yr-align-to-expr-after-brace)
              ;;        (+ baseline yr-indent-offset))))

              ;; A line starting with `->` is unindented by one level relative
              ;; to its surrounding expression. The previous form `(- 1
              ;; baseline)` could produce negative indentation (e.g. baseline=5
              ;; => -4) and break `indent-line-to`.
              ((looking-at "->") (+ baseline 1))

              ((looking-at "[]|)]") baseline)

              ;; A closing brace is 1 level unindented
              ((looking-at "[]})]") (max 0 (- baseline yr-indent-offset)))

              ;; Doc comments in /** style with leading * indent to line up the *s
              ((and (nth 4 (syntax-ppss)) (looking-at "*"))
               (+ 1 baseline))

              ;; When the importr chose not to indent the start of the where
              ;; claimport, put it on the baseline.
              ((and (not yr-indent-where-claimport)
                    (yr-looking-at-where))
               baseline)

              ;; If we're in any other token-tree / sexp, then:
              (t
               (or
                ;; If we are inside a pair of braces, with something after the
                ;; open brace on the same line and ending with a comma, treat
                ;; it as fields and align them.
                (when (> level 0)
                  (save-excursion
                    (yr-rewind-irrelevant)
                    (backward-up-list)
                    ;; Point is now at the beginning of the containing set of braces
                    (yr-align-to-expr-after-brace)))

                ;; When where-claimports are spread over multiple lines, claimports
                ;; should be aligned on the type parameters.  In this case we
                ;; take care of the second and following claimports (the ones
                ;; that don't start with "where ")
                (save-excursion
                  ;; Find the start of the function, we'll import this to limit
                  ;; our search for "where ".
                  (let ((function-start nil) (function-level nil))
                    (save-excursion
                      ;; If we're already at the start of a function,
                      ;; don't go back any farther.  We can easily do
                      ;; this by moving to the end of the line first.
                      (end-of-line)
                      (yr-beginning-of-defun)
                      (back-to-indentation)
                      ;; Avoid using multiple-value-bind
                      (setq function-start (point)
                            function-level (yr-paren-level)))
                    ;; When we're not on a line starting with "where ", but
                    ;; still on a where-claimport line, go to "where "
                    (when (and
                           (not (yr-looking-at-where))
                           ;; We're looking at something like "F: ..."
                           (looking-at (concat yr-re-ident ":"))
                           ;; There is a "where " somewhere after the
                           ;; start of the function.
                           (yr-rewind-to-where function-start)
                           ;; Make sure we're not inside the function
                           ;; already (e.g. initializing a struct) by
                           ;; checking we are the same level.
                           (= function-level level))
                      ;; skip over "where"
                      (forward-char 5)
                      ;; Unless "where" is at the end of the line
                      (if (eolp)
                          ;; in this case the type parameters bounds are just
                          ;; indented once
                          (+ baseline yr-indent-offset)
                        ;; otherwise, skip over whitespace,
                        (skip-chars-forward "[:space:]")
                        ;; get the column of the type parameter and import that
                        ;; as indentation offset
                        (current-column)))))

                (progn
                  (back-to-indentation)
                  ;; Point is now at the beginning of the current line
                  (if (or
                       ;; If this line begins with "else" or "{", stay on the
                       ;; baseline as well (we are continuing an expression,
                       ;; but the "else" or "{" should align with the beginning
                       ;; of the expression it's in.)
                       ;; Or, if this line starts a comment, stay on the
                       ;; baseline as well.
                       (looking-at "\\<else\\>\\|{\\|/[/*]")

                       ;; If this is the start of a top-level item,
                       ;; stay on the baseline.
                       (looking-at yr-top-item-beg-re)

                       (save-excursion
                         (yr-rewind-irrelevant)
                         ;; Point is now at the end of the previous line
                         (or
                          ;; If we are at the start of the buffer, no
                          ;; indentation is needed, so stay at baseline...
                          (= (point) 1)
                          ;; ..or if the previous line ends with any of these:
                          ;;     { ? : ( , ; [ }
                          ;; then we are at the beginning of an expression, so stay on the baseline...
                          (looking-back "[(,:;?[{}]\\|[^|]|" (- (point) 2))
                          ;; or if the previous line is the end of an attribute, stay at the baseline...
                          (progn (yr-rewind-to-beginning-of-current-level-expr) (looking-at "#")))))
                      baseline

                    ;; Otherwise, we are continuing the same expression from the previous line,
                    ;; so add one additional indent level
                    (+ baseline yr-indent-offset))))))))))

    (when indent
      ;; If we're at the beginning of the line (before or at the current
      ;; indentation), jump with the indentation change.  Otherwise, save the
      ;; excursion so that adding the indentations will leave us at the
      ;; equivalent position within the line to where we were before.
      (if (<= (current-column) (current-indentation))
          (indent-line-to indent)
        (save-excursion (indent-line-to indent))))))


;; Font-locking definitions and helpers
(defface yr-fstring-delimiter-face
  '((((class color) (background dark)) :foreground "yellow")
    (((class color) (background light)) :foreground "dark goldenrod")
    (t :inherit font-lock-preprocessor-face))
  "Face of the `${' and `}' around an expression embedded in a format string."
  :group 'yr-mode)

(defface yr-tag-face
  '((t :inherit font-lock-preprocessor-face))
  "Face of the name of a tag, at its declaration and at its sites."
  :group 'yr-mode)

(defface yr-tag-delimiter-face
  '((t :inherit yr-tag-face))
  "Face of the `#[' and `]' around the tags put on a declaration."
  :group 'yr-mode)

(defconst yr--tag-path-re
  "[[:word:][:multibyte:]_][[:word:][:multibyte:]_[:digit:]]*\\(?:::[[:word:][:multibyte:]_][[:word:][:multibyte:]_[:digit:]]*\\)*"
  "A path naming a tag at a tag site, `route' or `web::route'.")

(defun yr--match-tag-site-start (limit)
  "Font-lock matcher of the `#[' opening a tag site, outside strings and comments."
  (let (found)
    (while (and (not found) (re-search-forward "#\\[" limit t))
      (unless (nth 8 (save-excursion (syntax-ppss (match-beginning 0))))
        (setq found t)))
    found))

(defun yr--tag-site-end ()
  "The position after the `]' closing the tag site whose `[' is before point,
the end of the line if it is not closed."
  (save-excursion
    (condition-case nil
        (progn (backward-char) (forward-sexp) (point))
      (error (line-end-position)))))

(defun yr--match-tag-site-part (limit)
  "Anchored font-lock matcher of the parts of a tag site ending at LIMIT: the
path of each tag in group 1, the closing `]' in group 2.  The arguments of a
tag are skipped, being highlighted as any expression."
  (let (found)
    (while (and (not found) (< (point) limit))
      (forward-comment (buffer-size))
      (cond
       ((>= (point) limit))
       ((looking-at yr--tag-path-re)
        (setq found (list (match-beginning 0) (match-end 0)
                          (match-beginning 0) (match-end 0) nil nil))
        (goto-char (match-end 0)))
       ((eq (char-after) ?\()
        (condition-case nil (forward-sexp) (error (goto-char limit))))
       ((eq (char-after) ?\])
        (setq found (list (point) (1+ (point)) nil nil (point) (1+ (point))))
        (goto-char limit))
       (t (forward-char))))
    (when found
      (set-match-data found)
      t)))

(defun yr--fstring-fence-p (pos)
  "Whether the character at POS opens or closes a part of a format string."
  (and (get-text-property pos 'yr-fstring)
       (equal (get-text-property pos 'syntax-table) (string-to-syntax "|"))))

(defun yr--match-fstring-delimiter (limit)
  "Font-lock matcher of the `${' and `}' around an expression embedded in a
format string."
  (let (found)
    (while (and (not found) (re-search-forward "\\${\\|}" limit t))
      (when (yr--fstring-fence-p (1- (match-end 0)))
        (setq found t)))
    found))

(defconst yr-mode-keywords
  '("break" "continue" "impl"
    "else" "enum" "extern"
    "def" "for" "is" "with"
    "if" "in" "over" "mod" "dg" "of"
    "let" "loop" "class" "future"
    "match" "cte" "throw" "lazy" "spawn"
    "prv" "pub" "prot" "__version" "__test" "union"
    "ref" "move" "return" "throws" "fn" "__pragma"
    "self" "static" "record" "entity" "super" "panic"
    "trait" "tag" "use" "while" "atomic" "yield"
    "async" "await"))

(defconst yr-special-types
  '("u8" "i8"
    "u16" "i16"
    "u32" "i32"
    "u64" "i64"

    "f32" "f64"
    "isize" "usize"
    "bool"
    "str" "c8" "c32"))

(defconst yr-re-type-or-constructor
  (rx symbol-start
      (group upper (0+ (any word nonascii digit "_")))
      symbol-end))

(defconst yr-re-pre-expression-operators "[-=!%&*/:<>[{(|.^;}]")
(defun yr-re-word (inner) (concat "\\<" inner "\\>"))
(defun yr-re-grab (inner) (concat "\\(" inner "\\)"))
(defun yr-re-shy (inner) (concat "\\(?:" inner "\\)"))
(defun yr-re-item-def (itype)
  (concat (yr-re-word itype) "[[:space:]]+" (yr-re-grab yr-re-ident)))
(defun yr-re-item-def-imenu (itype)
  (concat "^[[:space:]]*"
          (yr-re-shy (concat (yr-re-word yr-re-vis) "[[:space:]]+")) "?"
          (yr-re-shy (concat (yr-re-word "default") "[[:space:]]+")) "?"
          (yr-re-shy (concat (yr-re-word yr-re-unsafe) "[[:space:]]+")) "?"
          (yr-re-shy (concat (yr-re-word yr-re-extern) "[[:space:]]+"
                               (yr-re-shy "\"[^\"]+\"[[:space:]]+") "?")) "?"
          (yr-re-item-def itype)))

(defconst yr-re-special-types (regexp-opt yr-special-types 'symbols))


(defun yr-path-font-lock-matcher (re-ident)
  "Matches names like \"foo::\" or \"Foo::\" (depending on RE-IDENT, which should match
the desired identifiers), but does not match type annotations \"foo::<\"."
  `(lambda (limit)
     (catch 'yr-path-font-lock-matcher
       (while t
         (let* ((symbol-then-colons (rx-to-string '(seq (group (regexp ,re-ident)) "::")))
                (match (re-search-forward symbol-then-colons limit t)))
           (cond
            ;; If we didn't find a match, there are no more occurrences
            ;; of foo::, so return.
            ((null match) (throw 'yr-path-font-lock-matcher nil))
            ;; If this isn't a type annotation foo::<, we've found a
            ;; match, so a return it!
            ((not (looking-at (rx (0+ space) "<")))
	     (throw 'yr-path-font-lock-matcher match))))))))


(defvar yr-mode-font-lock-keywords
  (append
   `(
     ;; Keywords proper
     ("\\_<\\(default\\)[[:space:]]+def\\_>" 1 font-lock-keyword-face)
     (,(regexp-opt yr-mode-keywords 'symbols) . font-lock-keyword-face)

     ("\\_<true\\_>" . 'font-lock-constant-face)

     ("\\_<false\\_>" . 'font-lock-constant-face)

     ("\\_<null\\_>" . 'font-lock-constant-face)

     ("\\_<none\\_>" . 'font-lock-constant-face)

     ("\\_<mut\\_>" . 'font-lock-constant-face)

     ("\\_<dmut\\_>" . 'font-lock-constant-face)

     ("\\_<expand\\_>" . 'font-lock-constant-face)

     ("\\_<typeof\\_>" . 'font-lock-constant-face)

     ("\\_<pure\\_>" . 'font-lock-constant-face)

     ("\\_<alias\\_>" . 'font-lock-constant-face)

     ("\\_<copy\\_>" . 'font-lock-constant-face)

     ("\\_<dcopy\\_>" . 'font-lock-constant-face)


     ;; Syntax extension invocations like `foo!`, highlight including the !
     (,(concat (yr-re-grab (concat yr-re-ident "!")) "")
      1 font-lock-preprocessor-face)

     ;; Field names like `foo:`, highlight excluding the :
     (,(concat (yr-re-grab yr-re-ident) ":[^:]") 1 font-lock-type-face)

     ;; Field names like `:foo`, highlight excluding the :
     (,(concat "[^:]:[^:]" (yr-re-grab yr-re-ident) ) 1 font-lock-variable-name-face keep)

     ;; Type names like `Foo::`, highlight excluding the ::
     (,(yr-path-font-lock-matcher yr-re-uc-ident) 1 font-lock-constant-face)

     ;; Module names like `foo::`, highlight excluding the ::
     (,(yr-path-font-lock-matcher yr-re-lc-ident) 1 font-lock-constant-face)

     ("\\([0-9]+\\)" 1 font-lock-constant-face)

     ("@\\(unsafe\\)" 1 font-lock-constant-face)

     ("\\_<unsafe\\_>" . 'font-lock-keyword-face)

     ("@\\([a-zA-Z]+\\)" 1 font-lock-constant-face)

     ;; Lifetimes like `'foo`
     (,(concat "'" (yr-re-grab yr-re-ident) "[^']") 1 font-lock-variable-name-face)

     ;; CamelCase Means Type Or Constructor
     (,yr-re-type-or-constructor 1 font-lock-type-face)

     ;; Tag sites `#[a, b (12), web::route ("/x")]': the brackets and the
     ;; paths of the tags, their arguments being highlighted as expressions
     (yr--match-tag-site-start
      (0 'yr-tag-delimiter-face t)
      (yr--match-tag-site-part (yr--tag-site-end) nil
                               (1 'yr-tag-face t t)
                               (2 'yr-tag-delimiter-face t t)))

     ;; The `${' and `}' around the expressions embedded in a format string
     (yr--match-fstring-delimiter 0 'yr-fstring-delimiter-face t)
     )

   ;; Item definitions
   (mapcar #'(lambda (x)
               (list (yr-re-item-def (car x))
                     1 (cdr x)))
           '(("enum" . font-lock-type-face)
             ("record" . font-lock-type-face)
             ("union" . font-lock-type-face)
             ("entity" . font-lock-type-face)
             ("class" . font-lock-type-face)
             ("tag" . 'yr-tag-face)
	     ("impl" . font-lock-type-face)
             ("mod" . font-lock-constant-face)
             ("use" . font-lock-constant-face)
             ("def" . font-lock-function-name-face)
	     ("over" . font-lock-function-name-face)
             ("async" . font-lock-function-name-face)))))

(defun yr-syntax-class-before-point ()
  (when (> (point) 1)
    (syntax-class (syntax-after (1- (point))))))

(defun yr-rewind-qualified-ident ()
  (while (yr-looking-back-ident)
    (backward-sexp)
    (when (save-excursion (yr-rewind-irrelevant) (yr-looking-back-str "::"))
      (yr-rewind-irrelevant)
      (backward-char 2)
      (yr-rewind-irrelevant))))

(defun yr-rewind-type-param-list ()
  (cond
   ((and (yr-looking-back-str ">") (equal 5 (yr-syntax-class-before-point)))
    (backward-sexp)
    (yr-rewind-irrelevant))

   ;; We need to be able to back up past the Def(args) -> RT form as well.  If
   ;; we're looking back at this, we want to end up just after "Def".
   ((member (char-before) '(?\] ?\) ))
    (let* ((is-paren (yr-looking-back-str ")"))
           (dest (save-excursion
                  (backward-sexp)
                  (yr-rewind-irrelevant)
                  (or
                   (when (yr-looking-back-str "->")
                     (backward-char 2)
                     (yr-rewind-irrelevant)
                     (when (yr-looking-back-str ")")
                       (backward-sexp)
                       (point)))
                   (and is-paren (point))))))
      (when dest
        (goto-char dest))))))

(defun yr-rewind-to-decl-name ()
  "If we are before an ident that is part of a declaration that
  can have a where claimport, rewind back to just before the name of
  the subject of that where claimport and return the new point.
  Otherwise return nil"

  (let* ((ident-pos (point))
         (newpos (save-excursion
                   (yr-rewind-irrelevant)
                   (yr-rewind-type-param-list)
                   (cond
                       ((yr-looking-back-symbols '("def" "async" "trait" "enum" "class" "mod" "record" "union" "entity" "impl" "tag")) ident-pos)

                       ((equal 5 (yr-syntax-class-before-point))
                        (backward-sexp)
                        (yr-rewind-to-decl-name))

                       ((looking-back "[:,'+=]" (1- (point)))
                        (backward-char)
                        (yr-rewind-to-decl-name))

                       ((yr-looking-back-str "->")
                        (backward-char 2)
                        (yr-rewind-to-decl-name))

                       ((yr-looking-back-ident)
                        (yr-rewind-qualified-ident)
                        (yr-rewind-to-decl-name))))))
    (when newpos (goto-char newpos))
    newpos))

(defun yr-is-in-expression-context (token)
  "Return t if what comes right after the point is part of an
  expression (as opposed to starting a type) by looking at what
  comes before.  Takes a symbol that roughly indicates what is
  after the point.

  This function is importd as part of `yr-is-lt-char-operator' as
  part of angle bracket matching, and is not intended to be importd
  outside of this context."

  (save-excursion
    (let ((postchar (char-after)))
      (yr-rewind-irrelevant)

      ;; A type alias or ascription could have a type param list.  Skip backwards past it.
      (when (member token '(ambiguous-operator open-brace))
        (yr-rewind-type-param-list))

      (cond

       ;; Certain keywords always introduce expressions
       ((yr-looking-back-symbols '("if" "while" "match" "return" "box" "in" "is" "await")) t)

       ;; "as" introduces a type
       ((yr-looking-back-symbols '("as")) nil)

       ;; An open angle bracket never introduces expression context WITHIN the angle brackets
       ((and (equal token 'open-brace) (equal postchar ?<)) nil)

       ;; An ident! followed by an open brace is a macro invocation.  Consider
       ;; it to be an expression.
       ((and (equal token 'open-brace) (yr-looking-back-macro)) t)

       ;; An identifier is right after an ending paren, bracket, angle bracket
       ;; or curly brace.  It's a type if the last sexp was a type.
       ((and (equal token 'ident) (equal 5 (yr-syntax-class-before-point)))
        (backward-sexp)
        (yr-is-in-expression-context 'open-brace))

       ;; If a "for" appears without a ; or { before it, it's part of an
       ;; "impl X for y", so the y is a type.  Otherwise it's
       ;; introducing a loop, so the y is an expression
       ((and (equal token 'ident) (yr-looking-back-symbols '("for")))
        (backward-sexp)
        (yr-rewind-irrelevant)
        (looking-back "[{;]" (1- (point))))

       ((yr-looking-back-ident)
        (yr-rewind-qualified-ident)
        (yr-rewind-irrelevant)
        (cond
         ((equal token 'open-brace)
          ;; We now know we have:
          ;;   ident <maybe type params> [{([]
          ;; where [{([] denotes either a {, ( or [.  This character is bound as postchar.
          (cond
           ;; If postchar is a paren or square bracket, then if the brace is a type if the identifier is one
           ((member postchar '(?\( ?\[ )) (yr-is-in-expression-context 'ident))

           ;; If postchar is a curly brace, the brace can only be a type if
           ;; ident2 is the name of an enum, struct or trait being declared.
           ;; Note that if there is a -> before the ident then the ident would
           ;; be a type but the { is not.
           ((equal ?{ postchar)
            (not (and (yr-rewind-to-decl-name)
                      (progn
                        (yr-rewind-irrelevant)
                        (yr-looking-back-symbols '("enum" "record" "union" "entity" "trait" "class"))))))
           ))

         ((equal token 'ambiguous-operator)
          (cond
           ;; An ampersand after an ident has to be an operator rather than a & at the beginning of a ref type
           ((equal postchar ?&) t)

           ;; A : followed by a type then an = introduces an expression (unless it is part of a where claimport of a "type" declaration)
           ((and (equal postchar ?=)
                 (looking-back "[^:]:" (- (point) 2))
                 (not (save-excursion (and (yr-rewind-to-decl-name) (progn (yr-rewind-irrelevant) (yr-looking-back-symbols '("class"))))))))

           ;; "let ident =" introduces an expression--and so does "mut" and "cte"
           ((and (equal postchar ?=) (yr-looking-back-symbols '("let" "mut" "dmut" "cte"))) t)

           ;; As a specific special case, see if this is the = in this situation:
           ;;     enum EnumName<type params> { Ident =
           ;; In this case, this is a c-like enum and despite Ident
           ;; representing a type, what comes after the = is an expression
           ((and
             (> (yr-paren-level) 0)
             (save-excursion
               (backward-up-list)
               (yr-rewind-irrelevant)
               (yr-rewind-type-param-list)
               (and
                (yr-looking-back-ident)
                (progn
                  (yr-rewind-qualified-ident)
                  (yr-rewind-irrelevant)
                  (yr-looking-back-str "enum")))))
            t)

           ;; Otherwise the ambiguous operator is a type if the identifier is a type
           ((yr-is-in-expression-context 'ident) t)))

         ((equal token 'colon)
          (cond
           ;; If we see a ident: not inside any braces/parens, we're at top level.
           ;; There are no allowed expressions after colons there, just types.
           ((<= (yr-paren-level) 0) nil)

           ;; We see ident: inside a list
           ((looking-back "[{,]" (1- (point)))
            (backward-up-list)

            ;; If a : appears whose surrounding paren/brackets/braces are
            ;; anything other than curly braces, it can't be a field
            ;; initializer and must be denoting a type.
            (when (looking-at "{")
              (yr-rewind-irrelevant)
              (yr-rewind-type-param-list)
              (when (yr-looking-back-ident)
                ;; We have a context that looks like this:
                ;;    ident2 <maybe type params> { [maybe paren-balanced code ending in comma] ident1:
                ;; the point is sitting just after ident2, and we trying to
                ;; figure out if the colon introduces an expression or a type.
                ;; The answer is that ident1 is a field name, and what comes
                ;; after the colon is an expression, if ident2 is an
                ;; expression.
                (yr-rewind-qualified-ident)
                (yr-is-in-expression-context 'ident))))


           ;; Otherwise, if the ident: appeared with anything other than , or {
           ;; before it, it can't be part of a struct initializer and therefore
           ;; must be denoting a type.
	   (t nil)
           ))
         ))

       ;; An operator-like character after a string is indeed an operator
       ((and (equal token 'ambiguous-operator)
             (member (yr-syntax-class-before-point) '(5 7 15))) t)

       ;; A colon that has something other than an identifier before it is a
       ;; type ascription
       ((equal token 'colon) nil)

       ;; A :: introduces a type (or module, but not an expression in any case)
       ((yr-looking-back-str "::") nil)

       ((yr-looking-back-str ":")
        (backward-char)
        (yr-is-in-expression-context 'colon))

       ;; A -> introduces a type
       ((yr-looking-back-str "->") nil)

       ;; If we are up against the beginning of a list, or after a comma inside
       ;; of one, back up out of it and check what the list itself is
       ((or
         (equal 4 (yr-syntax-class-before-point))
         (yr-looking-back-str ","))
	(condition-case nil
	    (progn
	      (backward-up-list)
	      (yr-is-in-expression-context 'open-brace))
	  (scan-error nil)))

       ;; A =>x introduces an expression
       ((yr-looking-back-str "=>") nil)

       ;; A == introduces an expression
       ((yr-looking-back-str "==") t)

       ;; These operators can introduce expressions or types
       ((looking-back "[-+=!?&*]" (1- (point)))
        (backward-char)
        (yr-is-in-expression-context 'ambiguous-operator))

       ;; These operators always introduce expressions.  (Note that if this
       ;; regexp finds a < it must not be an angle bracket, or it'd
       ;; have been caught in the syntax-class check above instead of this.)
       ((looking-back yr-re-pre-expression-operators (1- (point))) t)
       ))))

(defun yr-is-lt-char-operator ()
  "Return t if the < sign just after point is an operator rather
  than an opening angle bracket, otherwise nil."

  (let ((case-fold-search nil))
    (save-excursion
      (yr-rewind-irrelevant)
      ;; We are now just after the character syntactically before the <.
      (cond

       ;; On the other hand, if we are after a closing paren/brace/bracket it
       ;; can only be an operator, not an angle bracket.  Likewise, if we are
       ;; after a string it's an operator.  (The string case could actually be
       ;; valid in yr for character literals.)
       ((member (yr-syntax-class-before-point) '(5 7 15)) t)

       ;; If we are looking back at an operator, we know that we are at
       ;; the beginning of an expression, and thus it has to be an angle
       ;; bracket (starting a "<Type as Trait>::" construct.)
       ((looking-back yr-re-pre-expression-operators (1- (point))) nil)

       ;; If we are looking back at a keyword, it's an angle bracket
       ;; unless that keyword is "self", "true" or "false"
       ((yr-looking-back-symbols yr-mode-keywords)
        (yr-looking-back-symbols '("mut" "dmut" "self" "true" "false" "null" "none")))

       ((yr-looking-back-str "?")
	(yr-is-in-expression-context 'ambiguous-operator))

       ;; If we're looking back at an identifier, this depends on whether
       ;; the identifier is part of an expression or a type
       ((yr-looking-back-ident)
        (backward-sexp)
        (or
         ;; The special types can't take type param lists, so a < after one is
         ;; always an operator
         (looking-at yr-re-special-types)

         (yr-is-in-expression-context 'ident)))

       ;; Otherwise, assume it's an angle bracket
       ))))

(defun yr-electric-pair-inhibit-predicate-wrap (char)
  "Wraps the default `electric-pair-inhibit-predicate' to prevent
  inserting a \"matching\" > after a < that would be treated as a
  less than sign rather than as an opening angle bracket."
  (or
   (when (= ?< char)
     (save-excursion
       (backward-char)
       (yr-is-lt-char-operator)))
   (funcall (default-value 'electric-pair-inhibit-predicate) char)))

(defun yr-ordinary-lt-gt-p ()
  "Test whether the `<' or `>' at point is an ordinary operator of some kind.

This returns t if the `<' or `>' is an ordinary operator (like
less-than) or part of one (like `->'); and nil if the character
should be considered a paired angle bracket."
  (cond
   ;; If matching is turned off suppress all of them
   ((not yr-match-angle-brackets) t)

   ;; We don't take < or > in strings or comments to be angle brackets
   ((yr-in-str-or-cmnt) t)

   ;; Inside a macro we don't really know the syntax.  Any < or > may be an
   ;; angle bracket or it may not.  But we know that the other braces have
   ;; to balance regardless of the < and >, so if we don't treat any < or >
   ;; as angle brackets it won't mess up any paren balancing.
   ((yr-in-macro) t)

   ((looking-at "<")
    (yr-is-lt-char-operator))

   ((looking-at ">")
    (cond
     ;; Don't treat the > in -> or => as an angle bracket
     ((member (char-before (point)) '(?- ?=)) t)

     ;; If we are at top level and not in any list, it can't be a closing
     ;; angle bracket
     ((>= 0 (yr-paren-level)) t)

     ;; Otherwise, treat the > as a closing angle bracket if it would
     ;; match an opening one
     ((save-excursion
	(backward-up-list)
	(not (looking-at "<"))))))))

(defun yr-mode-syntactic-face-function (state)
  "Syntactic face function to distinguish doc comments from other comments."
  (if (nth 3 state) 'font-lock-string-face
    (save-excursion
      (goto-char (nth 8 state))
      (if (looking-at "/\\([*][*!][^*!]\\|/[/!][^/!]\\)")
          'font-lock-doc-face
        'font-lock-comment-face
    ))))

(eval-and-compile
  (defconst yr--char-literal-rx
    (rx (seq
	 (group "'")
	 (or
	  (seq
	   "\\"
	   (or
	    (: "u{" (** 1 6 xdigit) "}")
	    (: "x" (= 2 xdigit))
	    (any "'nrt0\"\\")))
	  (not (any "'\\"))
	  )
	 (group "'")))
    "A regular expression matching a character literal."))

(defun yr--syntax-propertize-raw-string (end)
  "A helper for yr-syntax-propertize.

If point is already in a raw string, this will apply the
appropriate string syntax to the character up to the end of the
raw string, or to `end', whichever comes first."
  (let ((str-start (nth 8 (syntax-ppss))))
    (when str-start
      (when (save-excursion
	      (goto-char str-start)
	      (looking-at "r\\(#*\\)\\(\"\\)"))
	;; In a raw string, so try to find the end.
	(let ((hashes (match-string 1)))
	  ;; Match \ characters at the end of the string to suppress
	  ;; their normal character-quote syntax.
	  (when (re-search-forward (concat "\\(\\\\*\\)\\(\"" hashes "\\)") end t)
	    (put-text-property (match-beginning 1) (match-end 1)
			       'syntax-table (string-to-syntax "_"))
	    (put-text-property (1- (match-end 2)) (match-end 2)
			       'syntax-table (string-to-syntax "|"))
	    (goto-char (match-end 0))))))))

(defun yr--fstring-embed-end (pos)
  "The position of the `}' closing the expression embedded in a format string
from POS, nil if the string ends before it.  Like the compiler, only braces are
counted, a `\"' ending the string."
  (let ((depth 1) (res nil) (done nil))
    (while (not done)
      (let ((c (char-after pos)))
        (cond
         ((or (null c) (eq c ?\")) (setq done t))
         ((eq c ?\\) (setq pos (+ pos 2)))
         ((eq c ?{) (setq depth (1+ depth) pos (1+ pos)))
         ((eq c ?})
          (setq depth (1- depth))
          (if (= depth 0) (setq res pos done t) (setq pos (1+ pos))))
         (t (setq pos (1+ pos))))))
    res))

(defun yr--syntax-propertize-fstring (fpos)
  "Propertize the format string whose `f' is at FPOS, and move after it.

Its literal parts are generic strings: the `f' opens the first one, the `{' of
each `${' closes one and the `}' closing the embedded expression opens the
next, the closing `\"' ending the last.  The embedded expressions are thus
read as code, and highlighted as such.  Every character from the `f' to the
closing `\"' (excluded) holds the position of the `f' in its `yr-fstring'
property, which `yr--syntax-propertize-extend-fstring' reads."
  (let ((fence (string-to-syntax "|"))
        (pos (+ fpos 2))
        (done nil))
    (put-text-property fpos (1+ fpos) 'syntax-table fence)
    (while (not done)
      (let ((c (char-after pos)))
        (cond
         ((null c) (setq done t))
         ((eq c ?\\) (setq pos (+ pos 2)))
         ((eq c ?\")
          (put-text-property pos (1+ pos) 'syntax-table fence)
          (setq done t))
         ((and (eq c ?$) (eq (char-after (1+ pos)) ?{))
          (let ((close (yr--fstring-embed-end (+ pos 2))))
            (if (null close)
                (setq pos (1+ pos))
              (put-text-property (1+ pos) (+ pos 2) 'syntax-table fence)
              (put-text-property close (1+ close) 'syntax-table fence)
              (setq pos (1+ close)))))
         (t (setq pos (1+ pos))))))
    (setq pos (min pos (point-max)))
    (put-text-property fpos pos 'yr-fstring fpos)
    (goto-char (min (1+ pos) (point-max)))))

(defun yr--syntax-propertize-extend-fstring (start end)
  "A `syntax-propertize-extend-region-functions' moving START back to the
beginning of the format string it is in, so that it is propertized from its
`f'."
  (let ((fpos (and (> start (point-min))
                   (get-text-property (1- start) 'yr-fstring))))
    (when (and (integerp fpos) (< fpos start))
      (cons fpos end))))

(defun yr-syntax-propertize (start end)
  "A `syntax-propertize-function' for `yr-mode'."
  (remove-text-properties start end '(yr-fstring nil))
  (goto-char start)
  (yr--syntax-propertize-raw-string end)
  (funcall
   (syntax-propertize-rules
    ;; Format strings, f"a ${expr} b".
    ("\\_<f\""
     (0 (ignore
         (let ((fpos (match-beginning 0)))
           (unless (nth 8 (save-excursion (syntax-ppss fpos)))
             (yr--syntax-propertize-fstring fpos))))))
    ;; Character literals.
    (yr--char-literal-rx (1 "\"") (2 "\""))
    ;; Raw strings.
    ("\\(r\\)#*\""
     (1 (prog1 "|"
	  (goto-char (match-end 0))
	  (yr--syntax-propertize-raw-string end))))
    ("[<>]"
     (0 (ignore
	 (when (save-match-data
		 (save-excursion
		   (goto-char (match-beginning 0))
		   (yr-ordinary-lt-gt-p)))
	   (put-text-property (match-beginning 0) (match-end 0)
			      'syntax-table (string-to-syntax "."))
	   (goto-char (match-end 0)))))))
   (point) end))

(defun yr-fill-prefix-for-comment-start (line-start)
  "Determine what to import for `fill-prefix' based on what is at the beginning of a line."
  (let ((result
         ;; Replace /* with same number of spaces
         (replace-regexp-in-string
          "\\(?:/\\*+?\\)[!*]?"
          (lambda (s)
            ;; We want the * to line up with the first * of the
            ;; comment start
            (let ((offset (if (eq t
                                  (compare-strings "/*" nil nil
                                                   s
                                                   (- (length s) 2)
                                                   (length s)))
                              1 2)))
              (concat (make-string (- (length s) offset)
                                   ?\x20) "*")))
          line-start)))
    ;; Make sure we've got at least one space at the end
    (if (not (= (aref result (- (length result) 1)) ?\x20))
        (setq result (concat result " ")))
    result))

(defun yr-in-comment-paragraph (body)
  ;; We might move the point to fill the next comment, but we don't want it
  ;; seeming to jump around on the importr
  (save-excursion
    ;; If we're outside of a comment, with only whitespace and then a comment
    ;; in front, jump to the comment and prepare to fill it.
    (when (not (nth 4 (syntax-ppss)))
      (beginning-of-line)
      (when (looking-at (concat "[[:space:]\n]*" comment-start-skip))
        (goto-char (match-end 0))))

    ;; We need this when we're moving the point around and then checking syntax
    ;; while doing paragraph fills, becaimport the cache it imports isn't always
    ;; invalidated during this.
    (syntax-ppss-flush-cache 1)
    ;; If we're at the beginning of a comment paragraph with nothing but
    ;; whitespace til the next line, jump to the next line so that we import the
    ;; existing prefix to figure out what the new prefix should be, rather than
    ;; inferring it from the comment start.
    (let ((next-bol (line-beginning-position 2)))
      (while (save-excursion
               (end-of-line)
               (syntax-ppss-flush-cache 1)
               (and (nth 4 (syntax-ppss))
                    (save-excursion
                      (beginning-of-line)
                      (looking-at paragraph-start))
                    (looking-at "[[:space:]]*$")
                    (nth 4 (syntax-ppss next-bol))))
        (goto-char next-bol)))

    (syntax-ppss-flush-cache 1)
    ;; If we're on the last line of a multiline-style comment that started
    ;; above, back up one line so we don't mistake the * of the */ that ends
    ;; the comment for a prefix.
    (when (save-excursion
            (and (nth 4 (syntax-ppss (line-beginning-position 1)))
                 (looking-at "[[:space:]]*\\*/")))
      (goto-char (line-end-position 0)))
    (funcall body)))

(defun yr-with-comment-fill-prefix (body)
  (let*
      ((line-string (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position)))
       (line-comment-start
        (when (nth 4 (syntax-ppss))
          (cond
           ;; If we're inside the comment and see a * prefix, import it
           ((string-match "^\\([[:space:]]*\\*+[[:space:]]*\\)"
                          line-string)
            (match-string 1 line-string))
           ;; If we're at the start of a comment, figure out what prefix
           ;; to import for the subsequent lines after it
           ((string-match (concat "[[:space:]]*" comment-start-skip) line-string)
            (yr-fill-prefix-for-comment-start
             (match-string 0 line-string))))))
       (fill-prefix
        (or line-comment-start
            fill-prefix)))
    (funcall body)))

(defun yr-find-fill-prefix ()
  (yr-in-comment-paragraph (lambda () (yr-with-comment-fill-prefix (lambda () fill-prefix)))))

(defun yr-fill-paragraph (&rest args)
  "Special wrapping for `fill-paragraph' to handle multi-line comments with a * prefix on each line."
  (yr-in-comment-paragraph
   (lambda ()
     (yr-with-comment-fill-prefix
      (lambda ()
        (let
            ((fill-paragraph-function
              (if (not (eq fill-paragraph-function 'yr-fill-paragraph))
                  fill-paragraph-function))
             (fill-paragraph-handle-comment t))
          (apply 'fill-paragraph args)
          t))))))

(defun yr-do-auto-fill (&rest args)
  "Special wrapping for `do-auto-fill' to handle multi-line comments with a * prefix on each line."
  (yr-with-comment-fill-prefix
   (lambda ()
     (apply 'do-auto-fill args)
     t)))

(defun yr-fill-forward-paragraph (arg)
  ;; This is to work around some funny behavior when a paragraph separator is
  ;; at the very top of the file and there is a fill prefix.
  (let ((fill-prefix nil)) (forward-paragraph arg)))

(defun yr-comment-indent-new-line (&optional arg)
  (yr-with-comment-fill-prefix
   (lambda () (comment-indent-new-line arg))))

;;; Imenu support
(defvar yr-imenu-generic-expression
  (append (mapcar #'(lambda (x)
                      (list (capitalize x) (yr-re-item-def-imenu x) 1))
                  '("enum" "union" "record" "entity" "class" "mod" "def" "impl" "trait" "tag" "over" "throw" "yield" "async"))
          `(("Macro" ,(yr-re-item-def-imenu "macro_rules!") 1)))
  "Value for `imenu-generic-expression' in Yr mode.

Create a hierarchical index of the item definitions in a Yr file.

Imenu will show all the enums, structs, etc. in their own subheading.
Import idomenu (imenu with `ido-mode') for best mileage.")

;;; Defun Motions

(defun yr-beginning-of-defun (&optional arg)
  "Move backward to the beginning of the current defun.

With ARG, move backward multiple defuns.  Negative ARG means
move forward.

This is written mainly to be importd as `beginning-of-defun-function' for Yr.
Don't move to the beginning of the line. `beginning-of-defun',
which calls this, does that afterwards."
  (interactive "p")
  (re-search-backward (concat "^\\(" yr-top-item-beg-re "\\)")
                      nil 'move (or arg 1)))

(defun yr-end-of-defun ()
  "Move forward to the next end of defun.

With argument, do it that many times.
Negative argument -N means move back to Nth preceding end of defun.

Assume that this is called after beginning-of-defun. So point is
at the beginning of the defun body.

This is written mainly to be importd as `end-of-defun-function' for Yr."
  (interactive)
  ;; Find the opening brace
  (if (re-search-forward "[{]" nil t)
      (progn
        (goto-char (match-beginning 0))
        ;; Go to the closing brace
        (condition-case nil
            (forward-sexp)
          (scan-error
           ;; The parentheses are unbalanced; instead of being unable to fontify, just jump to the end of the buffer
           (goto-char (point-max)))))
    ;; There is no opening brace, so consider the whole buffer to be one "defun"
    (goto-char (point-max))))

;; Formatting using yrfmt
(defun yr--format-call (buf)
  "Format BUF using yrfmt."
  (with-current-buffer (get-buffer-create "*yrfmt*")
    (erase-buffer)
    (insert-buffer-substring buf)
    (if (zerop (call-process-region (point-min) (point-max) yr-yrfmt-bin t t nil))
        (progn
          (if (not (string= (buffer-string) (with-current-buffer buf (buffer-string))))
              (copy-to-buffer buf (point-min) (point-max)))
          (kill-buffer))
      (error "Yrfmt failed, see *yrfmt* buffer for details"))))

(defconst yr--format-word "\\b\\(else\\|enum\\|def\\|for\\|if\\|let\\|loop\\|match\\|struct\\|unsafe\\|while\\)\\b")
(defconst yr--format-line "\\([\n]\\)")

;; Counts number of matches of regex beginning up to max-beginning,
;; leaving the point at the beginning of the last match.
(defun yr--format-count (regex max-beginning)
  (let ((count 0)
        save-point
        beginning)
    (while (and (< (point) max-beginning)
                (re-search-forward regex max-beginning t))
      (setq count (1+ count))
      (setq beginning (match-beginning 1)))
    ;; try one more in case max-beginning lies in the middle of a match
    (setq save-point (point))
    (when (re-search-forward regex nil t)
      (let ((try-beginning (match-beginning 1)))
        (if (> try-beginning max-beginning)
            (goto-char save-point)
          (setq count (1+ count))
          (setq beginning try-beginning))))
    (when beginning (goto-char beginning))
    count))

;; Gets list describing pos or (point).
;; The list contains:
;; 1. the number of matches of yr--format-word,
;; 2. the number of matches of yr--format-line after that,
;; 3. the number of columns after that.
(defun yr--format-get-loc (buffer &optional pos)
  (with-current-buffer buffer
    (save-excursion
      (let ((pos (or pos (point)))
            words lines columns)
        (goto-char (point-min))
        (setq words (yr--format-count yr--format-word pos))
        (setq lines (yr--format-count yr--format-line pos))
        (if (> lines 0)
            (if (= (point) pos)
                (setq columns -1)
              (forward-char 1)
              (goto-char pos)
              (setq columns (current-column)))
          (let ((initial-column (current-column)))
            (goto-char pos)
            (setq columns (- (current-column) initial-column))))
        (list words lines columns)))))

;; Moves the point forward by count matches of regex up to max-pos,
;; and returns new max-pos making sure final position does not include another match.
(defun yr--format-forward (regex count max-pos)
  (when (< (point) max-pos)
    (let ((beginning (point)))
      (while (> count 0)
        (setq count (1- count))
        (re-search-forward regex nil t)
        (setq beginning (match-beginning 1)))
      (when (re-search-forward regex nil t)
        (setq max-pos (min max-pos (match-beginning 1))))
      (goto-char beginning)))
  max-pos)

;; Gets the position from a location list obtained using yr--format-get-loc.
(defun yr--format-get-pos (buffer loc)
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((max-pos (point-max))
            (words (pop loc))
            (lines (pop loc))
            (columns (pop loc)))
        (setq max-pos (yr--format-forward yr--format-word words max-pos))
        (setq max-pos (yr--format-forward yr--format-line lines max-pos))
        (when (> lines 0) (forward-char))
        (let ((initial-column (current-column))
              (save-point (point)))
          (move-end-of-line nil)
          (when (> (current-column) (+ initial-column columns))
            (goto-char save-point)
            (forward-char columns)))
        (min (point) max-pos)))))

(defun yr-format-buffer ()
  "Format the current buffer using yrfmt."
  (interactive)
  (unless (executable-find yr-yrfmt-bin)
    (error "Could not locate executable \"%s\"" yr-yrfmt-bin))

  (let* ((current (current-buffer))
         (base (or (buffer-base-buffer current) current))
         buffer-loc
         window-loc)
    (dolist (buffer (buffer-list))
      (when (or (eq buffer base)
                (eq (buffer-base-buffer buffer) base))
        (push (list buffer
                    (yr--format-get-loc buffer nil))
              buffer-loc)))
    (dolist (window (window-list))
      (let ((buffer (window-buffer window)))
        (when (or (eq buffer base)
                  (eq (buffer-base-buffer buffer) base))
          (let ((start (window-start window))
                (point (window-point window)))
            (push (list window
                        (yr--format-get-loc buffer start)
                        (yr--format-get-loc buffer point))
                  window-loc)))))
    (yr--format-call (current-buffer))
    (dolist (loc buffer-loc)
      (let* ((buffer (pop loc))
             (pos (yr--format-get-pos buffer (pop loc))))
        (with-current-buffer buffer
          (goto-char pos))))
    (dolist (loc window-loc)
      (let* ((window (pop loc))
             (buffer (window-buffer window))
             (start (yr--format-get-pos buffer (pop loc)))
             (pos (yr--format-get-pos buffer (pop loc))))
        (set-window-start window start)
        (set-window-point window pos))))

  (message "Formatted buffer with yrfmt."))

(defun yr-enable-format-on-save ()
  "Enable formatting using yrfmt when saving buffer."
  (interactive)
  (setq-local yr-format-on-save t))

(defun yr-disable-format-on-save ()
  "Disable formatting using yrfmt when saving buffer."
  (interactive)
  (setq-local yr-format-on-save nil))

(defvar yr-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-f") 'yr-format-buffer)
    (define-key map (kbd "M-T") 'yr-toggle-test-file)
    (define-key map (kbd "C-S-f") 'yr-search-project)
    (define-key map (kbd "C-M-o") 'yr-optimize-imports)
    (define-key map (kbd "C-S-<mouse-1>") 'yr-find-symbol-definition)
    map)
  "Keymap for Yr major mode.")

;;;###autoload
(define-derived-mode yr-mode prog-mode "Yr"
  "Major mode for Yr code.

\\{yr-mode-map}"
  :group 'yr-mode
  :syntax-table yr-mode-syntax-table

  ;; Syntax.
  (setq-local syntax-propertize-function #'yr-syntax-propertize)
  (add-hook 'syntax-propertize-extend-region-functions
            #'yr--syntax-propertize-extend-fstring nil t)

  ;; Indentation
  (setq-local indent-line-function 'yr-mode-indent-line)

  ;; Fonts
  (setq-local font-lock-defaults '(yr-mode-font-lock-keywords
                                   nil nil nil nil
                                   (font-lock-syntactic-face-function . yr-mode-syntactic-face-function)
                                   ))

  ;; Misc
  (setq-local comment-start "// ")
  (setq-local comment-end   "")
  (setq-local indent-tabs-mode nil)
  (setq-local open-paren-in-column-0-is-defun-start nil)

  ;; Auto indent on }
  (setq-local
   electric-indent-chars (cons ?} (and (boundp 'electric-indent-chars)
                                       electric-indent-chars)))

  ;; Allow paragraph fills for comments
  (setq-local comment-start-skip "\\(?://[/!]*\\|/\\*[*!]?\\)[[:space:]]*")
  (setq-local paragraph-start
       (concat "[[:space:]]*\\(?:" comment-start-skip "\\|\\*/?[[:space:]]*\\|\\)$"))
  (setq-local paragraph-separate paragraph-start)
  (setq-local normal-auto-fill-function 'yr-do-auto-fill)
  (setq-local fill-paragraph-function 'yr-fill-paragraph)
  (setq-local fill-forward-paragraph-function 'yr-fill-forward-paragraph)
  (setq-local adaptive-fill-function 'yr-find-fill-prefix)
  (setq-local adaptive-fill-first-line-regexp "")
  (setq-local comment-multi-line t)
  (setq-local comment-line-break-function 'yr-comment-indent-new-line)
  (setq-local imenu-generic-expression yr-imenu-generic-expression)
  (setq-local imenu-syntax-alist '((?! . "w"))) ; For macro_rules!
  (setq-local beginning-of-defun-function 'yr-beginning-of-defun)
  (setq-local end-of-defun-function 'yr-end-of-defun)
  (setq-local parse-sexp-lookup-properties t)
  (setq-local electric-pair-inhibit-predicate 'yr-electric-pair-inhibit-predicate-wrap)
  (add-hook 'before-save-hook 'yr--before-save-hook nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.yr\\'" . yr-mode))

(defun yr-mode-reload ()
  (interactive)
  (unload-feature 'yr-mode)
  (require 'yr-mode)
  (yr-mode))

(defun yr--before-save-hook ()
  (when yr-format-on-save (yr-format-buffer)))

;; Issue #6887: Rather than inheriting the 'gnu compilation error
;; regexp (which is broken on a few edge cases), add our own 'yr
;; compilation error regexp and import it instead.
(defvar yrc-compilation-regexps
  (let ((file "\\([^\n]+\\)")
        (start-line "\\([0-9]+\\)")
        (start-col  "\\([0-9]+\\)")
        (end-line   "\\([0-9]+\\)")
        (end-col    "\\([0-9]+\\)")
        (msg-type   "\\(?:[Ee]rror\\|\\([Ww]arning\\)\\|\\([Nn]ote\\|[Hh]elp\\)\\)"))
    (let ((re (concat "^" file ":" start-line ":" start-col
                      ": " end-line ":" end-col
                      " " msg-type ":")))
      (cons re '(1 (2 . 4) (3 . 5) (6 . 7)))))
  "Specifications for matching errors in yrc invocations.
See `compilation-error-regexp-alist' for help on their format.")

(defvar yrc-new-compilation-regexps
  (let ((file "\\([^\n]+\\)")
        (start-line "\\([0-9]+\\)")
        (start-col  "\\([0-9]+\\)"))
    (let ((re (concat "^ *--> " file ":" start-line ":" start-col ; --> 1:2:3
                      )))
      (cons re '(1 2 3))))
  "Specifications for matching errors in yrc invocations (new style).
See `compilation-error-regexp-alist' for help on their format.")

;; Match test run failures and panics during compilation as
;; compilation warnings
(defvar cargo-compilation-regexps
  '("^\\s-+thread '[^']+' panicked at \\('[^']+', \\([^:]+\\):\\([0-9]+\\)\\)" 2 3 nil nil 1)
  "Specifications for matching panics in cargo test invocations.
See `compilation-error-regexp-alist' for help on their format.")

(defun yrc-scroll-down-after-next-error ()
  "In the new style error messages, the regular expression
   matches on the file name (which appears after `-->`), but the
   start of the error appears a few lines earlier. This hook runs
   after `M-x next-error`; it simply scrolls down a few lines in
   the compilation window until the top of the error is visible."
  (save-selected-window
    (when (eq major-mode 'yr-mode)
      (select-window (get-buffer-window next-error-last-buffer))
      (when (save-excursion
              (beginning-of-line)
              (looking-at " *-->"))
        (let ((start-of-error
               (save-excursion
                 (beginning-of-line)
                 (while (not (looking-at "^[a-z]+:\\|^[a-z]+\\[E[0-9]+\\]:"))
                   (forward-line -1))
                 (point))))
          (set-window-start (selected-window) start-of-error))))))

(eval-after-load 'compile
  '(progn
     (add-to-list 'compilation-error-regexp-alist-alist
                  (cons 'yrc-new yrc-new-compilation-regexps))
     (add-to-list 'compilation-error-regexp-alist 'yrc-new)
     (add-hook 'next-error-hook 'yrc-scroll-down-after-next-error)
     (add-to-list 'compilation-error-regexp-alist-alist
                  (cons 'yrc yrc-compilation-regexps))
     (add-to-list 'compilation-error-regexp-alist 'yrc)
     (add-to-list 'compilation-error-regexp-alist-alist
                  (cons 'cargo cargo-compilation-regexps))
     (add-to-list 'compilation-error-regexp-alist 'cargo)))

;;; Functions to submit (parts of) buffers to the yr playpen, for
;;; sharing.
(defun yr-playpen-region (begin end)
  "Create a sharable URL for the contents of the current region
   on the Yr playpen."
  (interactive "r")
  (let* ((data (buffer-substring begin end))
         (escaped-data (url-hexify-string data))
         (escaped-playpen-url (url-hexify-string (format yr-playpen-url-format escaped-data))))
    (if (> (length escaped-playpen-url) 5000)
        (error "encoded playpen data exceeds 5000 character limit (length %s)"
               (length escaped-playpen-url))
      (let ((shortener-url (format yr-shortener-url-format escaped-playpen-url))
            (url-request-method "POST"))
        (url-retrieve shortener-url
                      (lambda (state)
                        ; filter out the headers etc. included at the
                        ; start of the buffer: the relevant text
                        ; (shortened url or error message) is exactly
                        ; the last line.
                        (goto-char (point-max))
                        (let ((last-line (thing-at-point 'line t))
                              (err (plist-get state :error)))
                          (kill-buffer)
                          (if err
                              (error "failed to shorten playpen url: %s" last-line)
                            (message "%s" last-line)))))))))

(defun yr-playpen-buffer ()
  "Create a sharable URL for the contents of the current buffer
   on the Yr playpen."
  (interactive)
  (yr-playpen-region (point-min) (point-max)))

(defconst yr-decl-kinds
  '("enum" "record" "entity" "class" "mod" "def" "impl" "over" "union" "trait" "tag" "throw" "yield" "async")
  "Yr keywords that introduce a top-level declaration with a name,
importd by `yr-find-symbol-definition' to recognize declaration
sites.")

(defconst yr--binding-decorators '("mut" "dmut" "ref" "lazy")
  "Decorators that may appear between a `let'/`lazy' keyword (or in a
function parameter list) and the identifier being declared, importd
by `yr--binding-decorators-re'.")

(defun yr--binding-decorators-re ()
  "Return a regexp matching zero or more whitespace-separated
`yr--binding-decorators', importd as a prefix before an identifier
in `let'/`lazy' and parameter declaration regexps."
  (concat "\\(?:\\(?:" (regexp-opt yr--binding-decorators) "\\)[[:space:]]+\\)*"))

(defun yr--decl-regexp (name)
  "Return a regexp matching a top-level Yr declaration of NAME,
i.e. one of `yr-decl-kinds' followed by the identifier NAME."
  (concat "^[[:space:]]*\\(?:pub\\|prv\\|prot\\)?[[:space:]]*"
          (regexp-opt yr-decl-kinds 'symbols)
          "[[:space:]]+" (regexp-quote name) "\\_>"))

(defun yr--global-let-regexp (name)
  "Return a regexp matching a global (column-0) Yr `let' or `lazy'
declaration of NAME, e.g. `let NAME = ...;', `lazy NAME = ...;',
`let mut ref NAME = ...;' or `global let NAME = ...;' (see
`yr--binding-decorators' for the decorators tolerated between the
keyword and NAME).  Column-0 anchoring is what distinguishes these
from local `let'/`lazy' bindings inside a function body, which are
always indented and are instead found by
`yr--local-declaration-pos'."
  (concat "^\\(?:global[[:space:]]+\\)?\\_<\\(?:let\\|lazy\\)\\_>[[:space:]]+"
          (yr--binding-decorators-re) (regexp-quote name) "\\_>"))

(defun yr--enum-variant-regexp (name)
  "Return a regexp matching an Yr enum variant declaration of NAME,
i.e. a line of the form `| NAME', optionally followed by associated
data such as `(Type)' or `{ field: Type }'."
  (concat "^[[:space:]]*|[[:space:]]*" (regexp-quote name) "\\_>"))

(defun yr--all-decl-regexp (name)
  "Return a regexp matching a top-level item declaration (see
`yr--decl-regexp'), a global `let'/`lazy' declaration (see
`yr--global-let-regexp'), or an enum variant declaration (see
`yr--enum-variant-regexp') of NAME."
  (concat "\\(?:" (yr--decl-regexp name) "\\)"
          "\\|\\(?:" (yr--global-let-regexp name) "\\)"
          "\\|\\(?:" (yr--enum-variant-regexp name) "\\)"))

(defun yr--find-declarations (name root)
  "Return a list of (FILE POS LINE TEXT) declaring NAME in every
`.yr' file under ROOT (see `yr-project-root'), POS and LINE being
the character position and line number of the declaration within
FILE, and TEXT the declaring line's text."
  (let ((regexp (yr--all-decl-regexp name))
        (files (directory-files-recursively
                root "\\.yr\\'" nil
                (lambda (dir)
                  (not (string-prefix-p "." (file-name-nondirectory
                                              (directory-file-name dir)))))))
        matches)
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (push (list file (match-beginning 0) (line-number-at-pos (match-beginning 0))
                      (buffer-substring (line-beginning-position) (line-end-position)))
                matches))))
    (nreverse matches)))

(defun yr--visit-declaration (file pos)
  "Visit FILE and move point to POS."
  (pop-to-buffer (find-file-noselect file))
  (goto-char pos))

(defun yr--visit-declaration-and-close-list (file pos list-buf)
  "Visit FILE at POS (see `yr--visit-declaration'), then close the
window showing LIST-BUF -- the `yr--show-declarations' results
buffer this was chosen from -- and kill it, so the list disappears
once a declaration has actually been opened."
  (yr--visit-declaration file pos)
  (when (buffer-live-p list-buf)
    (let ((win (get-buffer-window list-buf)))
      (when (and win (window-live-p win))
        (ignore-errors (delete-window win))))
    (kill-buffer list-buf)))

(defun yr--show-declarations (name root matches)
  "Pop up a small, clickable buffer listing MATCHES (as returned by
`yr--find-declarations') for the Yr symbol NAME, found under ROOT.
Each entry can be visited with `RET' or a mouse click; the list
closes itself once a declaration has been opened.  `q' closes the
list without visiting anything."
  (let ((buf (get-buffer-create (format "*Yr declarations: %s*" name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (propertize (format "%d declaration%s of `%s':\n\n"
                                     (length matches)
                                     (if (cdr matches) "s" "")
                                     name)
                             'face 'bold))
        (dolist (m matches)
          (pcase-let ((`(,file ,pos ,line ,text) m))
            (insert-text-button
             (format "%s:%d: %s" (file-relative-name file root) line (string-trim text))
             'action (lambda (btn)
                       (yr--visit-declaration-and-close-list
                        (button-get btn 'yr-decl-file)
                        (button-get btn 'yr-decl-pos)
                        (button-get btn 'yr-decl-list-buf)))
             'yr-decl-file file
             'yr-decl-pos pos
             'yr-decl-list-buf buf
             'follow-link t
             'help-echo "mouse-1, RET: visit this declaration")
            (insert "\n"))))
      (goto-char (point-min))
      (forward-line 2))
    (pop-to-buffer buf '((display-buffer-below-selected) (window-height . 10)))))

(defun yr--looking-at-mod-decl-target-p ()
  "Non-nil if point is on the module name of a `mod ::NAME;'
declaration (`pub'/`prv'/`prot' and other modifiers before `mod' are
tolerated)."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (and bounds
         (save-excursion
           (goto-char (car bounds))
           (looking-back "\\_<mod\\_>[[:space:]]*::[[:space:]]*" (line-beginning-position))))))

(defun yr--module-file-candidates (name)
  "Return the candidate file paths for the Yr module NAME declared
via `mod ::NAME;' in the current buffer's file.

A module file for NAME declared in FILE (in directory DIR) is
expected at DIR/(basename of FILE)/NAME.yr, mirroring the layout
built by `yr--test-toggle-ensure-module-chain'.  DIR/NAME.yr is
tried as a fallback, in case NAME is declared from a file that is
already itself the root of its module's directory."
  (let* ((file (or buffer-file-name (user-error "Buffer is not visiting a file")))
         (dir (file-name-directory file))
         (base (file-name-base file)))
    (list (expand-file-name (concat name ".yr") (expand-file-name base dir))
          (expand-file-name (concat name ".yr") dir))))

(defun yr--enclosing-defun-start ()
  "Return the start position of the Yr item (function, impl, etc.)
enclosing point, as found by `yr-beginning-of-defun', or nil if
point is not within one (e.g. `yr-end-of-defun' from there does not
reach back to point)."
  (save-excursion
    (let ((pt (point)))
      (condition-case nil
          (progn
            (yr-beginning-of-defun)
            (let ((start (point)))
              (yr-end-of-defun)
              (when (and (<= start pt) (<= pt (point)))
                start)))
        (error nil)))))

(defun yr--nearest-local-let-pos (name start)
  "Search backward from point, no further than START, for the
nearest preceding `let NAME' or `lazy NAME' local binding
(tolerating `yr--binding-decorators' in between); return its
position, or nil if none is found."
  (save-excursion
    (let ((regexp (concat "\\_<\\(?:let\\|lazy\\)\\_>[[:space:]]+"
                           (yr--binding-decorators-re) "\\("
                           (regexp-quote name) "\\)\\_>")))
      (when (re-search-backward regexp start t)
        (match-beginning 1)))))

(defun yr--param-decl-pos (name start)
  "Search the parameter list of the Yr function starting at START
for a parameter named NAME; return its position, or nil if none is
found or START is not followed by a `{'."
  (save-excursion
    (goto-char start)
    (let ((brace (save-excursion (re-search-forward "{" nil t))))
      (when brace
        (goto-char start)
        (let ((regexp (concat "[(,][[:space:]]*" (yr--binding-decorators-re) "\\("
                               (regexp-quote name) "\\)\\_>")))
          (when (re-search-forward regexp brace t)
            (match-beginning 1)))))))

(defun yr--local-declaration-pos (name)
  "If NAME is declared as a local `let'/`lazy' binding or as a
parameter of the Yr function enclosing point, return its position in
the current buffer (preferring the nearest preceding `let'/`lazy'
binding over a same-named parameter, since it would shadow it);
otherwise return nil."
  (let ((start (yr--enclosing-defun-start)))
    (when start
      (or (yr--nearest-local-let-pos name start)
          (yr--param-decl-pos name start)))))

(defun yr-find-symbol-definition (&optional event)
  "Jump to wherever the Yr symbol at EVENT's position is declared.

Bound to `C-S-<mouse-1>' (Control-Shift-click).  When EVENT is an actual mouse click,
moves point there first; this also allows the command to be run
from the keyboard (e.g. via `M-x'), in which case it operates on
the symbol at point.  Resolution is tried in this order:

1. If the click (or point) lands on the module name of a
   `mod ::NAME;' declaration (see `yr--looking-at-mod-decl-target-p'),
   jump straight to that module's file if it can be found (see
   `yr--module-file-candidates').

2. Otherwise, if the symbol is a parameter or a local `let'/`lazy'
   binding of the Yr function enclosing point (see
   `yr--local-declaration-pos'), jump there, within the current
   buffer.

3. Otherwise, search every `.yr' file in the Yr project containing
   the current buffer (see `yr-project-root') for a top-level item
   declaration or a global `let'/`lazy' declaration (see
   `yr--all-decl-regexp') of that symbol name.  If exactly one
   declaration is found, visit it directly.  If several are found,
   pop up a small buffer listing them (see `yr--show-declarations')
   to pick from.  If none are found, report so."
  (interactive (list last-input-event))
  (when (mouse-event-p event)
    (mouse-set-point event))
  (let* ((name (thing-at-point 'symbol t))
         (module-target (and name buffer-file-name
                              (yr--looking-at-mod-decl-target-p)
                              (seq-find #'file-exists-p (yr--module-file-candidates name))))
         (local-pos (and name buffer-file-name (not module-target)
                         (yr--local-declaration-pos name))))
    (unless name (user-error "No symbol at point"))
    (cond
     (module-target (find-file module-target))
     (local-pos (goto-char local-pos))
     (t
      (let* ((root (yr-project-root))
             (matches (yr--find-declarations name root)))
        (cond
         ((null matches)
          (message "No declaration of `%s' found under %s" name root))
         ((null (cdr matches))
          (pcase-let ((`(,file ,pos ,_line ,_text) (car matches)))
            (yr--visit-declaration file pos)))
         (t
          (yr--show-declarations name root matches))))))))

(defconst yr--import-leaf :yr-import-leaf)

(defun yr--import-skip-space (text pos)
  "Return the first non-whitespace position in TEXT at or after POS."
  (while (and (< pos (length text))
              (memq (aref text pos) '(?\s ?\t ?\n ?\r)))
    (setq pos (1+ pos)))
  pos)

(defun yr--import-parse-ident (text pos)
  "Parse an import path segment in TEXT at POS.
Return (IDENT . NEW-POS)."
  (setq pos (yr--import-skip-space text pos))
  (unless (and (string-match "[[:word:][:multibyte:]_]+" text pos)
               (= (match-beginning 0) pos))
    (user-error "Cannot parse import near `%s'" (substring text pos)))
  (cons (match-string 0 text) (match-end 0)))

(defun yr--import-parse-entry (text pos)
  "Parse one import entry in TEXT at POS.
A leading `::' (a path from an external package) is kept on the first
segment.  Return (PATHS . NEW-POS), where PATHS is a list of path
segment lists."
  (let ((segments nil)
        paths parsed done external)
    (setq pos (yr--import-skip-space text pos)
          external (and (<= (+ pos 2) (length text))
                        (string= (substring text pos (+ pos 2)) "::")))
    (when external
      (setq pos (+ pos 2)))
    (setq parsed (yr--import-parse-ident text pos)
          segments (list (if external (concat "::" (car parsed)) (car parsed)))
          pos (cdr parsed))
    (while (not done)
      (setq pos (yr--import-skip-space text pos))
      (if (and (<= (+ pos 2) (length text))
               (string= (substring text pos (+ pos 2)) "::"))
          (progn
            (setq pos (yr--import-skip-space text (+ pos 2)))
            (if (and (< pos (length text)) (= (aref text pos) ?{))
                (progn
                  (setq parsed (yr--import-parse-group text (1+ pos) (nreverse segments))
                        paths (car parsed)
                        pos (cdr parsed)
                        done t))
              (setq parsed (yr--import-parse-ident text pos)
                    segments (cons (car parsed) segments)
                    pos (cdr parsed))))
        (setq paths (list (nreverse segments))
              done t)))
    (cons paths pos)))

(defun yr--import-parse-group (text pos prefix)
  "Parse an import group in TEXT at POS using PREFIX path segments.
POS should point just after the opening brace.  Return (PATHS . NEW-POS)."
  (let (paths parsed)
    (while (progn
             (setq pos (yr--import-skip-space text pos))
             (and (< pos (length text)) (not (= (aref text pos) ?}))))
      (setq parsed (yr--import-parse-entry text pos)
            paths (append paths (mapcar (lambda (path) (append prefix path))
                                        (car parsed)))
            pos (yr--import-skip-space text (cdr parsed)))
      (cond
       ((and (< pos (length text)) (= (aref text pos) ?,))
        (setq pos (1+ pos)))
       ((and (< pos (length text)) (= (aref text pos) ?}))
        nil)
       (t
        (user-error "Expected `,' or `}' in import near `%s'" (substring text pos)))))
    (unless (and (< pos (length text)) (= (aref text pos) ?}))
      (user-error "Unclosed import group"))
    (cons paths (1+ pos))))

(defun yr--import-paths (declaration)
  "Return the imported paths represented by use DECLARATION."
  (unless (string-match "\\`[[:space:]]*use[[:space:]]+\\(\\(?:.\\|\n\\)*\\);[[:space:]]*\\'"
                        declaration)
    (user-error "Cannot parse use declaration `%s'" declaration))
  (let* ((body (match-string 1 declaration))
         (pos 0)
         paths parsed)
    (while (< (setq pos (yr--import-skip-space body pos)) (length body))
      (setq parsed (yr--import-parse-entry body pos)
            paths (append paths (car parsed))
            pos (yr--import-skip-space body (cdr parsed)))
      (cond
       ((>= pos (length body)) nil)
       ((= (aref body pos) ?,)
        (setq pos (1+ pos)))
       (t
        (user-error "Unexpected import text near `%s'" (substring body pos)))))
    paths))

(defun yr--import-add-path (tree path)
  "Add PATH to import TREE."
  (if (null path)
      (puthash yr--import-leaf t tree)
    (let* ((segment (car path))
           (child (or (gethash segment tree)
                      (let ((new (make-hash-table :test 'equal)))
                        (puthash segment new tree)
                        new))))
      (yr--import-add-path child (cdr path)))))

(defun yr--import-child-keys (tree)
  "Return sorted import child keys from TREE."
  (let (keys)
    (maphash (lambda (key _value)
               (unless (eq key yr--import-leaf)
                 (push key keys)))
             tree)
    (sort keys #'string<)))

(defun yr--import-leaf-node-p (tree)
  "Return non-nil if TREE represents a complete import path leaf."
  (and (gethash yr--import-leaf tree)
       (null (yr--import-child-keys tree))))

(defun yr--import-direct-group-entries (tree)
  "Return TREE's direct leaf entries if TREE imports `_'.

Only direct leaf entries may stay in the parent import group.  Any
deeper child is emitted as a separate `use' declaration."
  (when (let ((wildcard (gethash "_" tree)))
          (and wildcard (yr--import-leaf-node-p wildcard)))
    (let ((ok t)
          entries)
      (dolist (key (yr--import-child-keys tree))
        (let ((child (gethash key tree)))
          (if (yr--import-leaf-node-p child)
              (setq entries (append entries (list key)))
            (setq ok nil))))
      (and ok entries))))

(defun yr--format-import-declaration (prefix entries)
  "Format one import declaration for PREFIX with ENTRIES."
  (if (cdr entries)
      (format "use %s::{%s};" prefix (mapconcat #'identity entries ", "))
    (format "use %s::%s;" prefix (car entries))))

(defun yr--format-import-declarations (prefix tree)
  "Return optimized declarations for PREFIX and TREE without nested groups."
  (let ((keys (yr--import-child-keys tree)))
    (if (and (null (gethash yr--import-leaf tree)) (null (cdr keys)))
        (yr--format-import-declarations
         (concat prefix "::" (car keys)) (gethash (car keys) tree))
      (let (entries declarations child-declarations)
        (when (gethash yr--import-leaf tree)
          (setq declarations (list (format "use %s;" prefix))))
        (dolist (key keys)
          (let* ((child (gethash key tree))
             (direct-entries (yr--import-direct-group-entries child)))
        (cond
         ((yr--import-leaf-node-p child)
          (setq entries (append entries (list key))))
         (direct-entries
          (setq entries
                (append entries
                        (when (gethash yr--import-leaf child)
                          (list key))
                        (mapcar (lambda (entry) (concat key "::" entry))
                                direct-entries))))
         (t
          (setq child-declarations
                (append child-declarations
                            (yr--format-import-declarations
                             (concat prefix "::" key) child)))))))
        (when entries
          (setq declarations
                (append declarations
                        (list (yr--format-import-declaration prefix entries)))))
        (append declarations child-declarations)))))

(defun yr--import-root-rank (root)
  "Return the sort rank of import ROOT: 0 for a local root, 1 for
`std', 2 for an external `::' root."
  (cond ((string= root "std") 1)
        ((string-prefix-p "::" root) 2)
        (t 0)))

(defun yr--format-import-block (declarations)
  "Return DECLARATIONS formatted as optimized `use' declarations.

Imports are deduplicated and nested input groups are merged.  A
nested path is kept inside an output group only one level deep and
only when that nested module imports `_'; otherwise it is emitted
as a separate `use' declaration.  Roots are sorted alphabetically,
local roots first, then `std', then external `::' roots, and
distinct roots are separated by a blank line."
  (let ((tree (make-hash-table :test 'equal)))
    (dolist (declaration declarations)
      (dolist (path (yr--import-paths declaration))
        (yr--import-add-path tree path)))
    (mapconcat
     (lambda (root)
       (mapconcat #'identity
                  (yr--format-import-declarations root (gethash root tree))
                  "\n"))
     (sort (yr--import-child-keys tree)
           (lambda (a b)
             (let ((rank-a (yr--import-root-rank a))
                   (rank-b (yr--import-root-rank b)))
               (if (= rank-a rank-b)
                   (string< a b)
                 (< rank-a rank-b)))))
     "\n\n")))

(defun yr--next-nonblank-line-is-use-p ()
  "Return non-nil if the next nonblank line starts a `use' declaration."
  (save-excursion
    (while (and (not (eobp)) (looking-at "^[ \\t]*$"))
      (forward-line 1))
    (looking-at "^[ \\t]*use[ \\t]+")))

(defun yr--strip-import-comments (text)
  "Return TEXT without its `//' and `/* */' comments."
  (replace-regexp-in-string
   "//.*$" ""
   (replace-regexp-in-string "/\\*\\(?:.\\|\n\\)*?\\*/" "" text)))

(defun yr--collect-use-declaration ()
  "Return the `use' declaration at point, comments removed, and move after it."
  (let ((start (point))
        done)
    (unless (looking-at "^[ \\t]*use[ \\t]+")
      (user-error "No `use' declaration at point"))
    (while (not done)
      (unless (re-search-forward "\\(;\\|//\\|/\\*\\)" nil t)
        (user-error "Unterminated `use' declaration"))
      (pcase (match-string 1)
        (";" (setq done t))
        ("//" (end-of-line))
        (_ (unless (search-forward "*/" nil t)
             (user-error "Unterminated comment in `use' declaration")))))
    (end-of-line)
    (prog1 (string-trim
            (yr--strip-import-comments
             (buffer-substring-no-properties start (point))))
      (forward-line 1))))

(defun yr-optimize-imports ()
  "Sort, merge, and deduplicate `use' declarations in the current buffer.

Finds the contiguous block of `use' declarations (blank lines
between them are allowed) starting at the first line beginning
with `use' in the buffer, and rewrites it: nested groups are
merged and duplicate imports are removed.  A nested path is kept
inside an output group only one level deep and only when that
nested module imports `_'; otherwise it is emitted as a separate
`use' declaration.  Roots are sorted alphabetically, local roots
first, then \"std\", then external \"::\" roots, and distinct roots
are separated by a blank line.  Comments inside the block are
dropped."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward "^[ \\t]*use[ \\t]+" nil t)
      (user-error "No `use' declarations found"))
    (beginning-of-line)
    (let ((block-start (point))
          declarations)
      (while (cond
              ((looking-at "^[ \\t]*use[ \\t]+")
               (push (yr--collect-use-declaration) declarations)
               t)
              ((and (looking-at "^[ \\t]*$")
                    (yr--next-nonblank-line-is-use-p))
               (forward-line 1)
               t)
              (t nil)))
      (setq declarations (nreverse declarations))
      (delete-region block-start (point))
      (goto-char block-start)
      (insert (yr--format-import-block declarations) "\n"))))

(declare-function dired-get-marked-files "dired")

(defun yr-dired-optimize-imports ()
  "Run `yr-optimize-imports' on the marked files in the current
Dired buffer (or the file at point, if none are marked).

Each file is visited (if not already), optimized if it contains
imports, and saved; buffers that had to be opened for the occasion
are killed again afterwards, buffers that were already open are
left open."
  (interactive)
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not in a Dired buffer"))
  (let ((files (dired-get-marked-files))
        (optimized 0)
        (skipped 0))
    (unless files
      (user-error "No files marked in this Dired buffer"))
    (dolist (file files)
      (if (not (file-regular-p file))
          (setq skipped (1+ skipped))
        (let* ((already-open (find-buffer-visiting file))
               (buffer (or already-open (find-file-noselect file))))
          (unwind-protect
              (with-current-buffer buffer
                (save-excursion
                  (goto-char (point-min))
                  (if (not (re-search-forward "^[ \\t]*use[ \\t]+" nil t))
                      (setq skipped (1+ skipped))
                    (yr-optimize-imports)
                    (setq optimized (1+ optimized))
                    (when (buffer-modified-p)
                      (save-buffer)))))
            (unless already-open
              (kill-buffer buffer))))))
    (message "Optimized imports in %d file%s, skipped %d without imports"
             optimized (if (= optimized 1) "" "s") skipped)))

(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "C-M-o") 'yr-dired-optimize-imports))

(defun yr-project-root (&optional file)
  "Find the root of the Yr project containing FILE (or the file
visited by the current buffer, if FILE is nil), as marked by the
nearest ancestor directory containing one of
`yr-test-toggle-project-markers' (e.g. gyllir.toml or
CMakeLists.txt).  If no such marker is found in any ancestor
directory, fall back to the parent directory of FILE instead."
  (let* ((file (expand-file-name (or file buffer-file-name default-directory)))
         (start-dir (file-name-directory file))
         (dir (locate-dominating-file
               start-dir
               (lambda (dir)
                 (seq-some (lambda (marker) (file-exists-p (expand-file-name marker dir)))
                           yr-test-toggle-project-markers)))))
    (expand-file-name (or dir (expand-file-name ".." start-dir)))))

(defun yr-search-project (regexp)
  "Search REGEXP across all `.yr' files in the Yr project containing
the current buffer, using `rgrep'.

The project root is computed by `yr-project-root': the nearest
ancestor directory containing a `yr-test-toggle-project-markers'
file (gyllir.toml or CMakeLists.txt), or the parent directory of
the current file if no such marker is found.  Results are shown in
a navigable grep buffer, similar to Dired: move between matches and
hit RET (or `n'/`p' to move and preview) to visit them."
  (interactive "sSearch project for regexp: ")
  (rgrep regexp "*.yr" (yr-project-root)))

(defun yr--test-toggle-project-root (file)
  "Find the root of the Yr project containing FILE, as marked by one
of `yr-test-toggle-project-markers'."
  (let ((dir (locate-dominating-file
              (file-name-directory file)
              (lambda (dir)
                (seq-some (lambda (marker) (file-exists-p (expand-file-name marker dir)))
                          yr-test-toggle-project-markers)))))
    (unless dir
      (user-error "Could not find a Yr project root (looking for %s) above %s"
                  (mapconcat #'identity yr-test-toggle-project-markers ", ") file))
    (expand-file-name dir)))

(defun yr--test-toggle-module-name (segs)
  "Convert SEGS, a list of path segments below the source root (the
last one being a file name ending in \".yr\"), into a `::'-qualified
Yr module path such as \"balder::core::config\"."
  (mapconcat #'identity
             (append (butlast segs) (list (file-name-sans-extension (car (last segs)))))
             "::"))

(defun yr--test-toggle-testify (name)
  "Import `yr-test-toggle-suffix' onto NAME."
  (concat name yr-test-toggle-suffix))

(defun yr--test-toggle-detestify (name)
  "Inverse of `yr--test-toggle-testify': strip a trailing
`yr-test-toggle-suffix' from NAME, if present."
  (if (string-suffix-p yr-test-toggle-suffix name)
      (substring name 0 (- (length name) (length yr-test-toggle-suffix)))
    name))

(defun yr--test-toggle-testify-first (segs)
  "Return SEGS (a list of path segments below the source/test root)
with its first element carrying `yr-test-toggle-suffix', handling the
case where that first element is itself a leaf \".yr\" file (no
subdirectory) by importing the suffix before the extension."
  (let ((first (car segs)))
    (cons
     (if (string-suffix-p ".yr" first)
         (concat (yr--test-toggle-testify (file-name-sans-extension first)) ".yr")
       (yr--test-toggle-testify first))
     (cdr segs))))

(defun yr--test-toggle-detestify-first (segs)
  "Inverse of `yr--test-toggle-testify-first'."
  (let ((first (car segs)))
    (cons
     (if (string-suffix-p ".yr" first)
         (concat (yr--test-toggle-detestify (file-name-sans-extension first)) ".yr")
       (yr--test-toggle-detestify first))
     (cdr segs))))

(defun yr--test-toggle-mod-decl-has-p (path submodule)
  "Non-nil if the Yr module file at PATH already declares SUBMODULE via
a `mod' statement."
  (and (file-exists-p path)
       (with-temp-buffer
         (insert-file-contents path)
         (goto-char (point-min))
         (re-search-forward
          (concat "\\_<mod\\_>[[:space:]]+::" (regexp-quote submodule) "[[:space:]]*;")
          nil t))))

(defun yr--test-toggle-ensure-mod-decl (path submodule)
  "Ensure the Yr module file at PATH declares SUBMODULE via a `pub mod'
statement, creating PATH (and its parent directory) if it does not
exist yet, or appending the declaration to it if it exists but lacks
one."
  (unless (yr--test-toggle-mod-decl-has-p path submodule)
    (make-directory (file-name-directory path) t)
    (with-temp-buffer
      (when (file-exists-p path)
        (insert-file-contents path)
        (goto-char (point-max))
        (unless (or (bobp) (bolp)) (insert "\n")))
      (insert (format "pub mod ::%s;\n" submodule))
      (write-region (point-min) (point-max) path))))

(defun yr--test-toggle-ensure-module-chain (root test dirs leaf-base)
  "Ensure the chain of Yr module-declaration files mirroring DIRS (a
list of directory segments below the top-level TEST directory of
ROOT) exists, each declaring the next segment of DIRS -- or LEAF-BASE,
for the last directory in DIRS -- as a submodule via `pub mod'.

For example, given TEST \"test\" and DIRS (\"path_test\" \"to\") and
LEAF-BASE \"file\", this ensures that ROOT/test/path_test.yr contains
`pub mod ::to;' and ROOT/test/path_test/to.yr contains
`pub mod ::file;'."
  (let ((prefix (list test)))
    (dotimes (i (length dirs))
      (setq prefix (append prefix (list (nth i dirs))))
      (let* ((child (if (< (1+ i) (length dirs)) (nth (1+ i) dirs) leaf-base))
             (mod-file (expand-file-name
                        (concat (mapconcat #'identity prefix "/") ".yr") root)))
        (yr--test-toggle-ensure-mod-decl mod-file child)))))

(defun yr--test-toggle-create-test (target module dirs leaf-base root test)
  "Visit TARGET as a new Yr test file for MODULE, seeded with a `use'
of MODULE and an empty `__test' block, first creating any missing
intermediate module-declaration files (see
`yr--test-toggle-ensure-module-chain', which imports DIRS, LEAF-BASE,
ROOT and TEST) so that TARGET is reachable from the top-level test
module tree."
  (yr--test-toggle-ensure-module-chain root test dirs leaf-base)
  (make-directory (file-name-directory target) t)
  (find-file target)
  (insert (format "use %s;\n\n__test {\n    assert(false);\n}\n" module))
  (goto-char (point-min))
  (when (search-forward "assert(" nil t)
    (goto-char (match-end 0))))

(defun yr-toggle-test-file ()
  "Toggle between a Yr source file and its corresponding test file.

Given a file under the project's source directory
(`yr-test-toggle-source-dir', e.g. \"src/foo/bar.yr\"), open the
corresponding file under the test directory
(`yr-test-toggle-test-dir'), with `yr-test-toggle-suffix' importd onto
its top-level path segment so the test module tree cannot collide
with the source module tree of the same name (e.g. \"test/foo_test/bar.yr\"),
offering to create it -- along with any missing intermediate
module-declaration files, so it is reachable via `pub mod' from the
top-level test module (see `yr--test-toggle-ensure-module-chain') --
seeded with a `use' of the source module and an empty `__test' block,
if it does not already exist. From a test file, jump back to the
matching source file, if there is one."
  (interactive)
  (unless (and buffer-file-name (string-suffix-p ".yr" buffer-file-name))
    (user-error "Not visiting a Yr (.yr) file"))
  (let* ((file (file-truename buffer-file-name))
         (root (yr--test-toggle-project-root file))
         (rel (file-relative-name file root))
         (segs (split-string rel "/"))
         (src yr-test-toggle-source-dir)
         (test yr-test-toggle-test-dir))
    (cond
     ((and (> (length segs) 1) (string= (car segs) src))
      (let* ((rest (cdr segs))
             (test-rest (yr--test-toggle-testify-first rest))
             (target (expand-file-name (mapconcat #'identity (cons test test-rest) "/") root)))
        (if (file-exists-p target)
            (find-file target)
          (when (yes-or-no-p (format "%s does not exist. Create it? " target))
            (yr--test-toggle-create-test
             target (yr--test-toggle-module-name rest)
             (butlast test-rest)
             (file-name-sans-extension (car (last test-rest)))
             root test)))))
     ((and (> (length segs) 1) (string= (car segs) test))
      (let* ((rest (cdr segs))
             (src-rest (yr--test-toggle-detestify-first rest))
             (target (expand-file-name (mapconcat #'identity (cons src src-rest) "/") root)))
        (if (file-exists-p target)
            (find-file target)
          (user-error "No corresponding source file %s" target))))
     (t
      (user-error "%s is not under `%s' or `%s' of the project rooted at %s"
                  rel src test root)))))

(provide 'yr-mode)

;;; yr-mode.el ends here
