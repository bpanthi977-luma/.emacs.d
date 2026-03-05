(use-package eglot
  :ensure t
  :defer t
  :config
  (setf eglot-autoshutdown t)

  (defun bp/eglot-config-python (venv-dir)
    "Takes the directory of virtualenv as argument and configures eglot"
    (interactive "DSelect Virtualenv Directory: ")
    (add-dir-local-variable 'python-mode
			    'eglot-workspace-configuration
			    `((:python :venvPath ,(file-relative-name venv-dir default-directory)
				       :pythonPath ,(file-relative-name
						     (expand-file-name "./bin/python" venv-dir)
						     default-directory))))))

;; See https://github.com/svaante/dape on how to use different debug
;; adapters.
;; I recommend codelldb for C/C++ in MacOS

(use-package dape
  :ensure t)
