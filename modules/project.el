(use-package project
  :config
  (defun bp/projectile-dir-p (dir)
    (let ((root (locate-dominating-file dir ".projectile")))
      (when root
	(cons 'transient root))))
  (add-to-list 'project-find-functions #'bp/projectile-dir-p))
