(use-package ivy
  :ensure t
  :init
  (ivy-mode t)
  (keymap-unset ivy-minibuffer-map "S-SPC"))

(use-package swiper
  :ensure t
  :bind (("C-s" . swiper-isearch)
	 ("C-r" . swiper-isearch-backward)))

;; Remembers history for M-x
(use-package smex
  :ensure t)

(use-package counsel
  :ensure t
  :bind (("C-c s" . counsel-rg))
  :init
  (counsel-mode t))
