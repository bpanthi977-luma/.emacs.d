(use-package ivy
  :ensure t
  :init
  (ivy-mode t))

(use-package swiper
  :ensure t
  :bind (("C-s" . swiper-isearch)
	 ("C-r" . swiper-isearch-backward)))

(use-package counsel
  :ensure t
  :bind (("C-c s" . counsel-rg))
  :init
  (counsel-mode t))
