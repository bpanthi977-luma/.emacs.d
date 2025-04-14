(use-package company
  :ensure t
  :init
  (global-company-mode t)
  (setf company-backends (remove 'company-clang company-backends)))
