(use-package multiple-cursors
  :ensure t
  :defer t
  :commands (mc/mark-previous-like-this mc/mark-next-like-this)
  :init
  (smartrep-define-key bp/global-prefix-map
      "m"
    '(("p" . mc/mark-previous-like-this)
      ("n" . mc/mark-next-like-this)
      ("l" . mc/edit-lines)
      ("0" . mc/insert-numbers)
      ("a" . mc/insert-letters))))
