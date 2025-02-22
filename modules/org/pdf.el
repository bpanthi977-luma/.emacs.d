;; Add support for opening pdf links in org
(use-package org-pdftools
  :ensure t
  :hook (org-mode . org-pdftools-setup-link))

(use-package pdf-tools
  :ensure t
  :config
  (setq pdf-view-use-scaling t)
  :init
  (pdf-loader-install))
