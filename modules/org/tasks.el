;; * Custom code to manage my tasks.org file

;; ** bp/org-datetree-custom-id
;; Automatically create a CUSTOM_ID based on datetree

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
	existing-id
      ;; If ID does not exist, proceed to generate and set it
      (let* ((heading-text (org-get-heading t t))
	     (date-part (bp/org-datetree-get-date-string))
	     (slug-part (bp/slugify heading-text))
	     (custom-id (concat date-part "_" slug-part)))

	;; Use org-set-property to insert the property
	(org-set-property "CUSTOM_ID" custom-id)
	(message "Added CUSTOM_ID: %s" custom-id)
	custom-id))))


;; * Parent and Child tasks managemetn

(cl-defun bp/org-datetree-find-entry (&optional (prompt "Select task:"))
  "Return the point of an entry from a datetree file."
  (let* ((candidates
	  (org-map-entries
	   (lambda ()
	     (let* ((current-task (org-get-heading t t t t))
		    (date-heading (save-excursion
				    (if (org-up-heading-safe)
					(org-get-heading t t t t)
				      "Unknown Date"))))
	       (cons (format "%s | %s" date-heading current-task) (point))))
	   "LEVEL=4")))		       ; Only look at level 4 headings

    (when candidates
      (let* ((selection (completing-read prompt candidates))
	     (pos (cdr (assoc selection candidates))))
	pos))))

(defun bp/org-tasks-link-parent ()
  "Link an node to another node in tasks file.
PARENT property is updated in the child node and
CHILD_TASKS property is update in the parent node."
  (interactive)
  (let ((parent-pos (bp/org-datetree-find-entry "Parent entry: "))
	(child-custom-id (bp/org-datetree-custom-id))
	(parent-custom-id))
    (if (not parent-pos)
	(progn
	  (message "No parent task selected.")
	  nil)

      ;; Add child link to parent node
      (save-excursion
	(goto-char parent-pos)
	(setf parent-custom-id (bp/org-datetree-custom-id))
	(let ((children (org-entry-get-multivalued-property nil "CHILD_TASKS"))
	      (child-link (format "[[#%s]]" child-custom-id)))
	  (unless (cl-find child-link children :test #'string-equal)
	    (apply #'org-entry-put-multivalued-property
		   nil "CHILD_TASKS" (cons child-link children)))))

      ;; Add parent node to child
      (org-entry-put nil "PARENT" (format "[[#%s]]" parent-custom-id))
      t)))

(defun bp/org-tasks-update-timetaken ()
  "Update timetaken property for the node by summing clocked time in this
heading, and its CHILD_TASKS."
  (interactive)
  (let ((sum (org-clock-sum-current-item)))
    (dolist (child (org-entry-get-multivalued-property nil "CHILD_TASKS"))
      (save-excursion
	(org-link-open-from-string child)
	(setf sum (+ sum (org-clock-sum-current-item)))))
    (org-entry-put nil "TIMETAKEN" (org-duration-from-minutes sum))
    sum))

(defun bp/org-agenda-map-entries (func)
  "Map a function to all entries in org agenda view."
  (unless (eq major-mode 'org-agenda-mode)
    (error "Not in an Org Agenda buffer"))

  (print "mapping")
  (save-excursion
    (goto-char (point-min)) ;; Start from the beginning of the view
    (when
	(move-end-of-line 1)
	(goto-char (next-single-property-change (point) 'org-marker)))
    (while (next-single-property-change (point) 'org-marker)
      (goto-char (1+ (next-single-property-change (point) 'org-marker)))
      (let* ((marker (org-get-at-bol 'org-marker))
	     (file (and marker (marker-buffer marker))))
	(when (and marker file)
	  (with-current-buffer (marker-buffer marker)
	    (goto-char (marker-position marker))
	    (funcall func)))))))

(defun bp/org-tasks-update-all-timetaken ()
  (interactive)
  (bp/org-agenda-map-entries #'bp/org-tasks-update-timetaken))
