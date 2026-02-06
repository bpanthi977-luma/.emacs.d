(use-package magit
  :ensure t
  :bind (:map project-prefix-map
	      ("m" . magit-project-status))
  :defer t)

(use-package forge
  :ensure t
  :defer t)
