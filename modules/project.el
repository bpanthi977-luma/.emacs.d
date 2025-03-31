(use-package project
  :bind (("C-x p C-s" . bp/project-save-all-buffers))
  :config
  (defun bp/projectile-dir-p (dir)
    (let ((root (locate-dominating-file dir ".projectile")))
      (when root
	(cons 'transient root))))

  (defun bp/project-save-all-buffers ()
    "Save all buffers that belong to the current project."
    (interactive)
    (let* ((project (project-current))
	   (buffers (when project (project-buffers project))))
      (if buffers
	  (progn
	    (dolist (buf buffers)
	      (when (buffer-file-name buf)
		(with-current-buffer buf
		  (when (buffer-modified-p)
		    (save-buffer)))))
	    (message "All project buffers saved."))
	(message "No project found or no buffers to save."))))

  (add-to-list 'project-find-functions #'bp/projectile-dir-p))
