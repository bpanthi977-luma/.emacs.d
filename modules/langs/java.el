(use-package lsp-java
  :ensure t
  :defer t
  :init
  (add-hook 'java-mode (lambda () (require 'lsp-java))))
