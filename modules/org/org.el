(use-package org
  :ensure nil
  :hook (org-mode-hook . org-indent-mode)
  :bind (:map bp/global-prefix-map
	      (("o l" . org-store-link)
	       ("o L" . org-id-store-link)))
  :config
  (setf org-image-actual-width nil))

