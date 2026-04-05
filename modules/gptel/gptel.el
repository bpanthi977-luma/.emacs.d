(use-package gptel
  :ensure t
  :bind (:map bp/global-prefix-map
	      (("g g" . gptel-send)
	       ("g b" . gptel)
	       ("g f" . gptel-add-file)
	       ("g a" . gptel-context-add)
	       ("g r" . gptel-context-remove-all)
	       ("g q" . gptel-abort)
	       ("g m" . gptel-menu)))
  :config
  (setf (alist-get 'inplace gptel-directives)
	"You are a large language model answering questions in-place for coding or writing. Respond with JUST the answer. DO NOT GIVE any explanation or surrounding text or ```")

  ;; Load providers
  (load* "copilot.el")
  (load* "ollama.el")

  ;; Config
  (setf gptel-default-mode 'org-mode
	gptel-model 'gpt-4.1
	gptel-backend bp/gptel-copilot)

  ;; Extra packages
  (load* "gptel-agenda-tool.el")
  (load* "~/.emacs.d/modules/other-packages/ob-gptel/ob-gptel.el"))
