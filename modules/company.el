(use-package company
  :ensure t
  :init
  (global-company-mode t)
  (setf company-backends (remove 'company-clang company-backends))
  (setf company-dabbrev-downcase nil))

(use-package yasnippet
  :ensure t
  :bind (:map yas-minor-mode-map
	      ("C-;" . company-yasnippet))
  :init
  (yas-global-mode 1))
