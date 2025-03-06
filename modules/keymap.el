(use-package smartrep
  :ensure t
  :demand t)

(defvar bp/global-prefix "M-m")
(define-prefix-command 'bp/global-prefix-map)
(define-key global-map (kbd bp/global-prefix) 'bp/global-prefix-map)

