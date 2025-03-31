;; Add syntax highliting for html export
(use-package htmlize
  :ensure t)

(use-package ox-html
  :ensure nil
  :config
  (setf org-html-htmlize-output-type 'css)
  (setf org-html-prefer-user-labels t))
