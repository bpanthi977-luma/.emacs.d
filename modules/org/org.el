(use-package org
  :ensure nil
  :hook (org-mode . org-indent-mode)
  :hook (org-mode . org-export-stable-reference-mode)
  :bind (:map bp/global-prefix-map
	      (("o l" . org-store-link)
	       ("o L" . org-id-store-link)))
  :bind (:map org-mode-map
	      (("M-," . org-mark-ring-goto)))
  :config
  (setf org-directory (file-truename "~/org"))
  (setf org-image-actual-width nil)
  (setf org-startup-with-inline-images t)
  (setf org-id-link-consider-parent-id t
	org-id-link-to-org-use-id 'use-existing)
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((awk . t)
     (dot . t)
     (C . t)
     (R . t)
     (css . t)
     (awk . t)
     (emacs-lisp . t)
     (eshell . t)
     (gnuplot . t)
     (haskell . t)
     (js . t)
     (java . t)
     (lisp . t)
     (makefile . t)
     (maxima . t)
     (octave . t)
     (python . t)
     (scheme . t)
     (shell . t)
     (sql . t)
     (sqlite . t))))

(use-package orgit
  :ensure t
  :defer t)
