(use-package org-mpv-notes
  :ensure t
  :hook (org-mode . org-mpv-notes-setup-link)
  :config
  (require 'smartrep)
  (setf org-mpv-notes-preferred-backend 'mpv)
  (setf org-mpv-notes-save-image-function #'org-attach-attach-mv)
  (define-key org-mpv-notes-mode-map (kbd "M-n") (smartrep-map org-mpv-notes-key-bindings)))
