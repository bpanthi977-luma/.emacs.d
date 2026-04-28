(add-hook 'lisp-mode-hook
	  (lambda ()
	    (setq indent-tabs-mode nil)))

(use-package sly
  :ensure t
  :config
  (setf inferior-lisp-program "sbcl")
  (setf org-babel-lisp-eval-fn #'sly-eval))

(use-package sly-mrepl
  :ensure nil
  :bind (:map sly-mrepl-mode-map
	      ("C-c M-p" . sly-mrepl-set-package)))
