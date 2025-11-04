(use-package eglot
  :ensure t
  :defer t
  :config
  (setf eglot-autoshutdown t))

(use-package dap-mode
  :ensure t
  :config
  (require 'dap-codelldb))
