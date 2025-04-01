;; https://emacs.stackexchange.com/a/70894
(defun bp/org-nov-open-new-window (path)
  "Open nov.el link in a new window"
  (setq available-windows
	(delete (selected-window) (window-list)))
  (setq new-window
	(or (car available-windows)
	    (split-window-sensibly)
	    (split-window-right)))
  (select-window new-window)
  (nov-org-link-follow path))

(defun bp/nov-find-buffer-visiting (file)
  (let ((truename (file-truename file)))
    (find-if (lambda (buffer)
	       (with-current-buffer buffer
		 (string-equal nov-file-name truename)))
	     (buffer-list))))

(defun bp/org-nov-jump (path)
  (cond ((string-match "^\\(.*\\)::\\([0-9]+\\):\\([0-9]+\\)$" path)
	 (let* ((file (match-string 1 path))
		(index (string-to-number (match-string 2 path)))
		(point (string-to-number (match-string 3 path)))

		(buffer (bp/nov-find-buffer-visiting file)))
	   (if (not buffer)
	       (bp/org-nov-open-new-window path)
	     (save-excursion
	       (print buffer)
	       (switch-to-buffer-other-frame buffer)
	       (nov--find-file nil index point)))))
	((string-match "^\\(.*\\).epub" path)
	 (let ((buffer (bp/nov-find-buffer-visiting path)))
	   (if buffer
	       (switch-to-buffer-other-frame buffer)
	     (nov--find-file path 0 0))))
	(t (error "Invalid nov.el link"))))

(defun org-nov-link-setup ()
  (org-link-set-parameters "nov" :follow #'bp/org-nov-jump))

(use-package nov
  :ensure t
  :hook (org-mode . org-nov-link-setup))
