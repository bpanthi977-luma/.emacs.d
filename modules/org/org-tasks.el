;; -*- eval: (outline-minor-mode); -*-

(require 'org-datetree)

;; Custom code to manage my tasks.org file
;;; Custom variables
(defcustom org-tasks-file (file-truename "~/org/private/tasks.org")
  "The file where time logging of tasks is done. Time logs are placed in
datetree format.

(org-tasks-start) function create a time log entry in this file."
  :type 'file)

;;; org-tasks-custom-id
;; Automatically create a CUSTOM_ID based on datetree or parent headings

(defun org-tasks--slugify (str)
  "Convert STR to a URL-friendly, lowercase slug, replacing spaces and
non-word characters with underscores."
  (let ((slug (downcase str)))
    ;; Replace non-alphanumeric/underscore characters with a single underscore
    (setq slug (replace-regexp-in-string "[^a-z0-9_]" "_" slug t t))
    ;; Collapse multiple underscores into one
    (setq slug (replace-regexp-in-string "_+" "_" slug t t))
    ;; Remove leading/trailing underscores
    (string-trim-left (string-trim-right slug "_") "_")))

(defun org-tasks--datetree-get-date-string ()
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
	nil))))

(defun org-tasks--random-string (length)
  "Generate a random alphanumeric string of the given LENGTH."
  (let* ((charset "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
	 (charset-len (length charset))
	 (i 0)
	 (str (make-string length 0)))
    (while (< i length)
      (setf (aref str i) (aref charset (random charset-len)))
      (setf i (+ i 1)))
    str))

(defun org-tasks-custom-id ()
  "Add a CUSTOM_ID property to the current heading.
For datetree the ID is constructed from the date (found by searching up
the datetree hierarchy for YYYY-MM-DD) and a slugified version of the
current heading text.

For other tree the ID is construction by concatenating slugfied version
of all the headings.

Example output: :CUSTOM_ID: 20251101_kalman_filter"
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (error "Not in an Org mode buffer. This function is for Org files."))

  ;; Check for existing CUSTOM_ID property
  (let ((existing-id (org-entry-get (point) "CUSTOM_ID" nil)))
    (if existing-id
	existing-id
      ;; If ID does not exist, proceed to generate and set it
      (let* ((heading-slug (org-tasks--slugify (org-get-heading t t t t)))
	     (parent-part (or (org-tasks--datetree-get-date-string)
			      (concat (format-time-string "%Y%m%d" (current-time))
				      "_"
				      (org-tasks--random-string 4))))
	     (custom-id (concat parent-part "_" heading-slug)))

	;; Use org-set-property to insert the property
	(org-set-property "CUSTOM_ID" custom-id)
	(message "Added CUSTOM_ID: %s" custom-id)
	custom-id))))

;; Advicee org-store-link to first create custom id in agenda files
;;; org-tasks-link-parent
;; Parent and Child tasks management
(defun org-tasks-create-marker ()
  (let* ((marker (make-marker))
	 (pos (point)))
    (set-marker marker pos)
    marker))


(defun org-tasks--org-link-marker (org-link)
  "Creates and returns marker to the file and position `ORG-LINK' points
to.
Works with file: and id: links only."
  (pcase (with-temp-buffer
	   (let ((org-inhibit-startup nil))
	     (insert org-link)
	     (org-mode)
	     (goto-char (point-min))
	     (org-element-link-parser)))
    (`nil (user-error "No valid link in %S" s))
    (link
     (let* ((type (org-element-property :type link))
	    (buffer))
       (pcase type
	 ((or "file" "custom-id")
	  (let ((buffer (if (equal type "custom-id")
			    (current-buffer)
			  (find-file-noselect (org-element-property :path link))))
		(search-option (if (equal type "custom-id")
				   (org-element-property :raw-link link)
				   (org-element-property :search-option link)))
		(position)
		(marker (make-marker)))

	    (with-current-buffer buffer
	      (save-excursion
		(when (org-string-nw-p search-option)
		  (org-link-search search-option))
		(setf position (point))))

	    (set-marker marker position buffer)))

	 ("id"
	  (let* ((path (org-element-property :path link)) ;; for id links path has the whole string
		 (search-option (and (string-match "::\\(.*\\)\\'" path)
				     (match-string 1 path)))
		 (id (if (not search-option)
			 path
		       (substring path 0 (match-beginning 0))))
		 (marker))

	    (setf marker (org-id-find id 'marker))
	    (when search-option
	      (with-current-buffer (marker-buffer marker)
		(save-excursion
		  (org-link-search search-option)
		  (set-marker marker (point)))))
	    marker))

	  (_ (error "Unsupported link type: %s" type)))))))

(defmacro org-tasks--with-org-link (org-link &rest body)
  "Make current buffer and point be where ORG-LINK points, then eval BODY.
Works with file: and id: links only."
  (declare (indent 1) (debug (form body)))
  `(let ((--marker (org-tasks--org-link-marker ,org-link)))
     (with-current-buffer (marker-buffer --marker)
       (save-excursion
	 (goto-char (marker-position --marker))
	 ,@body))))

(defun org-tasks--marker-from-link ()
  (let ((entry (pop org-stored-links)))
    (when entry
      (org-tasks--org-link-marker (concat "[[" (car entry) "]]")))))

(defun org-tasks--link-string (target-file target-custom-id insert-file)
  (if (equal target-file insert-file)
      (format "[[#%s]]" target-custom-id)
    (format "[[file:%s::#%s]]"
	    (file-relative-name target-file (file-name-directory insert-file))
	    target-custom-id)))

(defun org-tasks-link-parent (&optional parent-marker)
  "Link an node to another node in tasks file.
PARENT property is updated in the child node and
CHILD_TASKS property is update in the parent node."
  (interactive)
  (let* ((parent-marker (or parent-marker
			    (org-tasks--marker-from-link)
			    (error "Mark the parent heading first by creating a link M-x org-store-link")))
	 (parent-buffer-name (buffer-file-name (marker-buffer parent-marker)))
	 (child-buffer-name (buffer-file-name))
	 (child-custom-id (org-tasks-custom-id))
	 (parent-custom-id))

    ;; Add child link to parent node
    (save-excursion
      (with-current-buffer (marker-buffer parent-marker)
	(goto-char (marker-position parent-marker))
	(setf parent-custom-id (org-tasks-custom-id))
	(let ((children (org-entry-get-multivalued-property nil "CHILD_TASKS"))
	      (child-link (org-tasks--link-string child-buffer-name child-custom-id parent-buffer-name)))
	  (unless (cl-find child-link children :test #'string-equal)
	    (apply #'org-entry-put-multivalued-property
		   nil "CHILD_TASKS" (cons child-link children))))))

    ;; Add parent node to child
    (org-entry-put nil "PARENT" (org-tasks--link-string parent-buffer-name parent-custom-id child-buffer-name))
    t))

;;; org-tasks-update-timetaken
;; Update TIMETAKEN
(defun org-tasks--map-agenda-entries (func)
  "Map a function to all entries in org agenda view."
  (unless (eq major-mode 'org-agenda-mode)
    (error "Not in an Org Agenda buffer"))

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

(defun org-tasks-update-timetaken ()
  "Update timetaken property for the node by summing clocked time in this
heading, and its CHILD_TASKS."
  (interactive)
  (let ((sum (org-clock-sum-current-item))
	(original-buffer (current-buffer)))
    (dolist (child (org-entry-get-multivalued-property nil "CHILD_TASKS"))
      (org-tasks--with-org-link child
	(setf sum (+ sum (org-clock-sum-current-item)))))
    (org-entry-put nil "TIMETAKEN" (org-duration-from-minutes sum))
    sum))

(defun org-tasks-update-all-timetaken ()
  "Update the TIMETAKEN property for all tasks listed in the agenda view."
  (interactive)
  (org-tasks--map-agenda-entries #'org-tasks-update-timetaken))

;;; org-tasks-start
(defun org-tasks-start ()
  "Ensures a log entry for the task under cursor in the agenda view under
todays date. And starts the clock on that entry."
  (interactive)
  (let* ((parent-marker (or (org-get-at-bol 'org-marker)
			    (org-tasks-create-marker)))
	 (tasks-file (file-truename org-tasks-file))
	 parent-task-title
	 child-tasks
	 (clockin-if-today (lambda ()
			     (when (string-equal (file-truename (buffer-file-name)) tasks-file)
			       (let ((task-date (org-tasks--datetree-get-date-string))
				     (today (format-time-string "%Y%m%d" (current-time))))
				 (when (string-equal task-date today)
				   (org-clock-in)
				   t))))))
    (unless (and parent-marker (marker-buffer parent-marker))
      (error "No task under cursor."))

    (or
     (with-current-buffer (marker-buffer parent-marker)
       (goto-char (marker-position parent-marker))
       (setf parent-task-title (org-get-heading t t t t)
	     child-tasks (org-entry-get-multivalued-property nil "CHILD_TASKS"))
       ;; Clock in if the parent node is itself okay as task node
       (funcall clockin-if-today))

     (org-with-file-buffer tasks-file
       ;; Find a child tasks in today's date
       (or
	(cl-some (lambda (child)
		   (org-tasks--with-org-link child
		     (funcall clockin-if-today)))
		 child-tasks)
	;; Create a new child tasks in today's date
	(progn
	  (org-datetree-file-entry-under (format "* %s" parent-task-title) (calendar-current-date))
	  (org-clock-in)
	  (org-tasks-link-parent parent-marker)
	  t))))))

(provide 'org-tasks)
