;; Add support for opening pdf links in org
(use-package org-pdftools
  :ensure nil
  :load-path "modules/other-packages/org-pdftools" ; my fork of org-pdftools
  :hook (org-mode . org-pdftools-setup-link))

(use-package pdf-tools
  :ensure t
  :bind (:map pdf-view-mode-map
	      ("C-s" . isearch-forward)
	      ("C-r" . isearch-backward))
  :config
  (setq pdf-view-use-scaling t)
  (setq pdf-view-continuous nil)
  :init
  (pdf-loader-install))
