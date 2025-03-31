(use-package eldoc
  :ensure nil
  :config
  ;; This means not only documentation but any errors reported by flymake will
  ;; also be show in echo area.
  ;; Useful when used with lsp as it configures flymake
  (setf eldoc-documentation-strategy #'eldoc-documentation-compose))
