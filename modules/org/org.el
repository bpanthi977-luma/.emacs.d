(use-package org
  :ensure nil
  :hook (org-mode . org-indent-mode)
  :hook (org-mode . org-export-stable-reference-mode)
  :bind (:map bp/global-prefix-map
	      (("o l" . org-store-link)
	       ("o L" . bp/org-id-store-link)))
  :bind (:map org-mode-map
	      (("M-," . org-mark-ring-goto)))
  :config

  (setf org-directory (file-truename "~/org"))
  (setf org-image-actual-width nil)
  (setf org-startup-with-inline-images t)
  (setf org-indirect-buffer-display 'current-window)

  (setf org-id-link-consider-parent-id t
	org-id-link-to-org-use-id 'use-existing)

  (defun bp/org-id-store-link ()
    "When org-id-link-consider-parent-id is t,
org-id-store-link doesn't create a new ID if one already exists for the
parent. This function forces creation of an ID for the node."
    (interactive)
    (org-id-get-create)
    (org-store-link nil t))

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
