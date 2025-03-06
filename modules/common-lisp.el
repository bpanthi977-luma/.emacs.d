(use-package sly
  :ensure t
  :config
  (setf inferior-lisp-program "sbcl"))

(use-package sly-mrepl
  :ensure nil
  :bind (:map sly-mrepl-mode-map
	      ("C-c M-p" . sly-mrepl-set-package)))
