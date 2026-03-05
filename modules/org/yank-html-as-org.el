(defvar bp/yank-html-as-org-command
  (cl-case system-type
    (darwin "pbpaste -Prefer public.html | pandoc -f html -t org")
    (t "false")))

(defvar bp/org-bold-regexp
  (rx
    "*"                               ; 1. Match literal opening asterisk
    (group                            ; 2. Start capturing content (Group 1)
      (not (any space "*"))           ;    First char: MUST NOT be space (heading) or * (sub-heading)
      (optional                       ;    Optional rest of the word (if length > 1)
	(zero-or-more (not "*"))      ;    Middle content: anything except an asterisk
	(not (any space "*"))))       ;    Last char: MUST NOT be space (org syntax rule) or *
    "*"                               ; 3. Match literal closing asterisk
    )
  "Matches org-mode bold markers from string (*text*).
Don't match headings (* Heading) and multi-star markers (***).")

(defun bp/remove-org-bold (&optional beg end)
  "Remove org-mode bold markers (*text*) from region or string.
If BEG is a string, returns the modified string.
If called interactively, modifies the selected region."
  (interactive "r")
  (if (stringp beg)
      (replace-regexp-in-string bp/org-bold-regexp "\\1" beg)
    (save-excursion
      (let ((text (delete-and-extract-region beg end)))
	(insert (replace-regexp-in-string bp/org-bold-regexp "\\1" text))))))

(defun bp/yank-html-as-org (arg)
  "Convert rich text (HTML) from the macOS clipboard to Org and insert it."
  (interactive "P")
  ;; This uses `pbpaste` to read the clipboard and `pandoc` to turn HTML into Org.
  ;; Make sure `pandoc` is installed and on your PATH.
  (let* ((org-text (with-temp-buffer
		     (if (zerop (call-process-shell-command bp/yank-html-as-org-command nil t nil))
			 (progn
			   (goto-char (point-min))
			   (while (re-search-forward "^[ \t]*:PROPERTIES:\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?" nil t)
			     (replace-match ""))
			   (buffer-string))
		       (error "Conversion command failed")))))
    (unless arg
      (setf org-text (bp/remove-org-bold org-text)))
    (insert org-text)))

(bind-key "o y" #'bp/yank-html-as-org bp/global-prefix-map)
