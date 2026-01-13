(use-package org-agenda
  :ensure nil
  :bind (:map bp/global-prefix-map
	      (("o a" . org-agenda)))
  :config
  (setf org-agenda-span 'day))
  (define-key org-agenda-mode-map (kbd bp/global-prefix) bp/global-prefix-map)

