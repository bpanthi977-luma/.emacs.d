(use-package smartparens
  :ensure t
  :bind (;; Movement [see: https://ebzzry.io/en/emacs-pairs/]
         ( "C-M-f" . sp-forward-sexp)
         ( "C-M-b" . sp-backward-sexp)
         ( "C-M-a" . sp-beginning-of-sexp)
         ( "C-M-e" . sp-end-of-sexp)

         ;; transpose, kill, copy
         ( "C-M-t" . sp-transpose-sexp)
         ( "C-M-k" . sp-kill-sexp)
         ( "C-M-w" . sp-copy-sexp)

         ( "M-i" . sp-change-enclosing))
  :hook ((prog-mode . smartparens-mode))
  :init
  (require 'smartparens-config)
  (smartparens-global-strict-mode -1))
