;; Adpated from https://github.com/alphapapa/unpackaged.el#export-to-html-with-useful-anchors

(defun bp/org-export-get-reference (datum info)
  "Like `org-export-get-reference', except uses heading titles instead of random numbers."
  (let ((cache (plist-get info :internal-references)))
    (or (car (rassq datum cache))
	(when (org-html-standalone-image-p datum info)
	  (let ((figure-number (org-export-get-ordinal
				(org-element-map datum 'link
				  #'identity info t)
				info nil #'org-html-standalone-image-p)))
	    (format "figure-%d" figure-number)))
	(let* ((crossrefs (plist-get info :crossrefs))
	       (cells (org-export-search-cells datum))
	       (new (or (cl-some
			 (lambda (cell)
			   (let ((stored (cdr (assoc cell crossrefs))))
			     (when stored
			       (if (not (numberp stored))
				   stored
				 (let ((old (org-export-format-reference stored)))
				   (and (not (assoc old cache)) stored))))))
			 cells)
			(when (org-element-property :ID datum)
			  (concat "ID-" (org-element-property :ID datum)))
			(when (org-element-property :raw-value datum)
			  (bp/org-export-new-title-reference datum cache))
			(org-export-format-reference
			 (org-export-new-reference cache))))
	       (reference-string new))
	  (dolist (cell cells) (push (cons cell new) cache))
	  (push (cons reference-string datum) cache)
	  (plist-put info :internal-references cache)
	  reference-string))))

(defun bp/org-export-escape-reference (str)
  "Excape the `str' for use in link anchors in html, labels in latex."
  (let ((str (substring-no-properties str)))
    (cl-case org-export-current-backend
      (html (url-hexify-string (substring-no-properties str)))
      ((latex beamer) (replace-regexp-in-string "[^a-zA-Z0-9_-]" "-" str))
      (t (string-replace " " "-" (substring-no-properties str))))))

(defun bp/org-export-new-title-reference (datum cache)
  "Return new reference for DATUM that is unique in CACHE."
  (cl-macrolet ((inc-suffixf (place)
		  `(progn
		     (string-match (rx bos
				       (minimal-match (group (1+ anything)))
				       (optional "--" (group (1+ digit)))
				       eos)
				   ,place)
		     ;; HACK: `s1' instead of a gensym.
		     (-let* (((s1 suffix) (list (match-string 1 ,place)
						(match-string 2 ,place)))
			     (suffix (if suffix
					 (string-to-number suffix)
				       0)))
		       (setf ,place (format "%s--%s" s1 (cl-incf suffix)))))))
    (let* ((title (org-element-property :raw-value datum))
	   (ref (bp/org-export-escape-reference title))
	   (parent (org-element-property :parent datum)))
      (while (--any (equal ref (car it))
		    cache)
	;; Title not unique: make it so.
	(if parent
	    ;; Append ancestor title.
	    (setf title (concat (org-element-property :raw-value parent)
				"--" title)
		  ref (bp/org-export-escape-reference title)
		  parent (org-element-property :parent parent))
	  ;; No more ancestors: add and increment a number.
	  (inc-suffixf ref)))
      ref)))

(defun bp/org-export-format-reference (f reference)
  (if (stringp reference)
      reference
    (funcall f reference)))

(define-minor-mode org-export-stable-reference-mode
    "Attempt to export Org as HTML with useful link IDs.
Instead of random IDs like \"#orga1b2c3\", use heading titles,
made unique when necessary."
    :global nil
    (cond (org-export-stable-reference-mode
	   (advice-add #'org-export-format-reference :around #'bp/org-export-format-reference)
	   (advice-add #'org-export-get-reference :override #'bp/org-export-get-reference))
	  (t
	   (advice-remove #'org-export-format-reference  #'bp/org-export-format-reference)
	   (advice-remove #'org-export-get-reference #'bp/org-export-get-reference))))

(provide 'org-export-stable-reference-mode)
