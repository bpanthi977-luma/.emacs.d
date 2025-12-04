(defun bp/slugify (str)
  "Convert STR to a URL-friendly, lowercase slug, replacing spaces and
non-word characters with underscores."
  (let ((slug (downcase str)))
    ;; Replace non-alphanumeric/underscore characters with a single underscore
    (setq slug (replace-regexp-in-string "[^a-z0-9_]" "_" slug t t))
    ;; Collapse multiple underscores into one
    (setq slug (replace-regexp-in-string "_+" "_" slug t t))
    ;; Remove leading/trailing underscores
    (string-trim-left (string-trim-right slug "_") "_")))

;;;###autoload
(defun bp/org-datetree-get-date-string ()
  "Search up the heading hierarchy for a YYYY-MM-DD date pattern and
return the date formatted as YYYYMMDD."
  (save-excursion
    (let ((date-regexp "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)")
	  (date-str nil)
	  (limit 5) ; Limit the search depth to prevent infinite loops in bad files
	  (count 0))
      ;; Iterate up the hierarchy until a date is found or limit is reached
      (while (and (not date-str) (org-up-heading-safe) (< count limit))
	(let ((heading (org-get-heading t t)))
	  (when (string-match date-regexp heading)
	    ;; Extract the YYYY-MM-DD part (match group 1)
	    (setq date-str (match-string 1 heading))))
	(setq count (1+ count)))

      (if date-str
	  ;; Format YYYY-MM-DD to YYYYMMDD (remove hyphens)
	  (replace-regexp-in-string "-" "" date-str)
	(error "Could not find a YYYY-MM-DD date heading in the hierarchy. Search aborted.")))))

;;;###autoload
(defun bp/org-datetree-custom-id ()
  "Add a CUSTOM_ID property to the current heading. The ID is constructed
from the date (found by searching up the datetree hierarchy for YYYY-MM-DD)
and a slugified version of the current heading text.

Example output: :CUSTOM_ID: 20251101_kalman_filter"
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (error "Not in an Org mode buffer. This function is for Org files."))

  ;; Check for existing CUSTOM_ID property
  (let ((existing-id (org-entry-get (point) "CUSTOM_ID" t)))
    (if existing-id
	;; If ID exists, report it and make no changes
	(message "CUSTOM_ID already set: %s (No change made)" existing-id)

      ;; If ID does not exist, proceed to generate and set it
      (let* ((heading-text (org-get-heading t t))
	     (date-part (bp/org-datetree-get-date-string))
	     (slug-part (bp/slugify heading-text))
	     (custom-id (concat date-part "_" slug-part)))

	;; Use org-set-property to insert the property
	(org-set-property "CUSTOM_ID" custom-id)
	(message "Added CUSTOM_ID: %s" custom-id)
	custom-id))))
