(use-package org-roam
  :ensure t
  :bind (:map bp/global-prefix-map
	      (("r f" . org-roam-node-find)
	       ("r F" . org-roam-ref-find)
	       ("r c" . org-roam-capture)
	       ("r g" . org-roam-graph)))
  :config
  (cl-loop for (suffix . command) in '(("r i" . org-roam-node-insert)
				       ("r r" . org-roam-buffer-toggle)
				       ("r R" . org-roam-ref-add)
				       ("r a" . org-roam-alias-add)
				       ("r t" . org-roam-tag-add))
	   do
	   (keymap-set org-mode-map
		       (format "%s %s" bp/global-prefix suffix)
		       command))

  (setf org-roam-mode nil)
  (setq org-roam-directory (file-truename "~/org")
	org-roam-capture-templates '(("d" "default" plain "%?"
				      :target (file+head "${slug}.org"
							 "#+title: ${title}\n#+date:%t\n")
				      :unnarrowed t)
				     ("p" "private" plain "%?"
				      :target (file+head "private/${slug}.org"
							 "#+title: ${title}\n#+date:%t\n")
				      :unnarrowed t)
				     ("e" "encrypted private notes" plain "%?"
				      :target (file+head "private/${slug}.org.gpg"
							 "#+title: ${title}\n#+date:%t\n")
				      :unnarrowed t)))
  (setq org-roam-file-exclude-regexp '("data/" ".stversions/" ".stfolder/"))
  (setq org-roam-db-location
	(cond ((string-equal system-type "gnu/linux")
	       (expand-file-name "dbs/linux/org-roam.db" org-roam-directory))
	      ((string-equal system-type "windows-nt")
	       (expand-file-name "dbs/windows/org-roam.db" org-roam-directory))
	      ((string-equal system-type "darwin")
	       (expand-file-name "dbs/darwin/org-roam.db" org-roam-directory))))

  (org-roam-db-autosync-mode 1))
