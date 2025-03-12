(defvar org-mid-link-email-program (cl-case system-type
				     (darwin "/Applications/Thunderbird.app/Contents/MacOS/thunderbird")
				     (t "thunderbird")))

(defun org-mid-link-follow (path &optional arg)
  "Open the email `PATH'"
  (make-process :name "thunderbird"
		:command (list org-mid-link-email-program
			       (concat "mid:" path))))

(defun org-mid-link-insert (message-id)
  (interactive "sMessage Id: ")
  (let ((stripped (string-trim message-id "<" ">")))
    (insert "[[mid:" stripped "]]")))

(defun org-mid-link-setup ()
  (org-link-set-parameters "mid" :follow #'org-mid-link-follow))

(with-eval-after-load 'org
  (org-mid-link-setup))

