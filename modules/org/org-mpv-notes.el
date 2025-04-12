(use-package mpv
  :ensure t)

(use-package org-mpv-notes
  :ensure t
  :hook (org-mode . org-mpv-notes-setup-link)
  :config
  (require 'smartrep)
  (require 'mpv)
  (define-key org-mpv-notes-mode-map (kbd "M-n") (smartrep-map org-mpv-notes-key-bindings)))
