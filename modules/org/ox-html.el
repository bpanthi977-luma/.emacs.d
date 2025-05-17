;; Add syntax highliting for html export
(use-package htmlize
  :ensure t)

(use-package ox-html
  :ensure nil
  :after org
  :config
  (setf org-html-style-default "<link rel=\"stylesheet\" href=\"/Users/bpanthi977/org/blog/css/stylesheet.css\" />")
  (setf org-html-htmlize-output-type 'css)
  (setf org-html-prefer-user-labels t))
