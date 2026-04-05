(defvar bp/gptel-openrouter
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
	      "meta-llama/llama-3.1-405b-instruct:free")))
