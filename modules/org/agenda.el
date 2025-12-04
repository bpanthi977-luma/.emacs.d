(use-package org-agenda
  :ensure nil
  :bind (:map bp/global-prefix-map
	      (("o a" . org-agenda)))
  :config
  (setf org-agenda-span 'day))
