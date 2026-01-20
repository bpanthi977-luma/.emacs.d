(use-package gptel
  :ensure t
  :bind (:map bp/global-prefix-map
	      (("g g" . gptel-send)
	       ("g b" . gptel)
	       ("g f" . gptel-add-file)
	       ("g a" . gptel-context-add)
	       ("g r" . gptel-context-remove-all)
	       ("g q" . gptel-abort)))
  :config
  ;; Set the api key in .authinfo file like:
  ;; machine generativelanguage.googleapis.com apikey password <<YOUR_API_KEY>>
  (setf gptel-default-mode 'org-mode
	gptel-model 'gemini-flash-latest
	gptel-backend (gptel-make-gemini "Gemini" :stream t :key #'gptel-api-key-from-auth-source))

  (gptel-make-openai "OpenRouter" ;; Any name you like
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
	      "meta-llama/llama-3.1-405b-instruct:free")))
