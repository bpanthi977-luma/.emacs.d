(use-package lsp-mode
  :ensure t)

(use-package dap-mode
  :ensure t
  :config
  (require 'dap-codelldb))
