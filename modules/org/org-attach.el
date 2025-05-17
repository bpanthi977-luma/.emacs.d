(use-package org-attach
  :ensure nil
  :after org
  :config
  (setq org-attach-auto-tag nil
	org-attach-method "mv"
	org-attach-preferred-new-method 'dir
	org-attach-id-dir "data/"
	org-attach-use-inheritance t)

  (defun bp/org-attach-dir (id)
    "Function to be used as member of `org-attach-id-to-path-function-list'
Takes `id' of the node, and returns the attach directory.
Returns NIL if fallback to other id to path functions is wanted."
    (let* ((filename (buffer-file-name))
	   (basename (and filename (file-name-base filename))))
      basename))

  (cl-pushnew #'bp/org-attach-dir org-attach-id-to-path-function-list))
