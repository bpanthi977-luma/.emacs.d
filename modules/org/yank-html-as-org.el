(defvar bp/yank-html-as-org-command
  (cl-case system-type
    (darwin "pbpaste -Prefer public.html | pandoc -f html -t org")
    (t "false")))

(defun bp/yank-html-as-org ()
  "Convert rich text (HTML) from the macOS clipboard to Org and insert it."
  (interactive)
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
    (insert org-text)))

(bind-key "o y" #'bp/yank-html-as-org bp/global-prefix-map)
