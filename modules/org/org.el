(use-package org
  :ensure nil
  :hook (org-mode . org-indent-mode)
  :hook (org-mode . org-export-stable-reference-mode)
  :bind (:map bp/global-prefix-map
	      (("o l" . org-store-link)
	       ("o L" . org-id-store-link)))
  :config
  (setf org-image-actual-width nil))
