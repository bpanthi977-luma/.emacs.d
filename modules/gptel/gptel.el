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
  (setf gptel-default-mode 'org-mode
	gptel-model 'gpt-4.1
	gptel-backend (gptel-make-gh-copilot "GitHub Copilot"))

  (setf (alist-get 'inplace gptel-directives)
	"You are a large language model answering questions in-place for coding or writing. Respond with JUST the answer. DO NOT GIVE any explanation or surrounding text or ```")

  ;; Set the api key in .authinfo file like:
  ;; machine generativelanguage.googleapis.com apikey password <<YOUR_API_KEY>>

  (gptel-make-gemini "Gemini" :stream t :key #'gptel-api-key-from-auth-source)

  (gptel-make-openai "OpenRouter"
    :host "openrouter.ai"
    :endpoint "/api/v1/chat/completions"
    :protocol "https"
    :stream t
    :key #'gptel-api-key-from-auth-source
    :models '("openrouter/mistral-7b" ;; example models
	      "openrouter/gpt-4.1-mini"
	      "qwen/qwen3-4b:free"
	      "mistralai/mistral-small-3.1-24b-instruct:free"
	      "google/gemma-3-27b-it:free"
	      "meta-llama/llama-3.3-70b-instruct:free"
	      "meta-llama/llama-3.1-405b-instruct:free"))

  (load* "gptel-agenda-tool.el")
  (load* "~/.emacs.d/modules/other-packages/ob-gptel/ob-gptel.el")
  (add-to-list 'gptel-tools gptel-agenda-log-tool))
