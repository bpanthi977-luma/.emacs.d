(use-package uv-mode
  :ensure t
  :config

  (defun bp/uv-setup-venv-location (dir)
    "Create .venv configuration file in DIR to set up the uv environment."
    (interactive "DDirectory: ")
    (let* ((expanded-dir (expand-file-name dir))
	   (content (format "
export UV_PROJECT_ENVIRONMENT=%s

if [ -f \"${UV_PROJECT_ENVIRONMENT}/bin/activate\" ]; then
    source \"${UV_PROJECT_ENVIRONMENT}/bin/activate\"
fi"
			    expanded-dir)))
      (with-temp-file ".venv"
	(insert content))
      (message "Successfully wrote environment setup to .venv" ))))
