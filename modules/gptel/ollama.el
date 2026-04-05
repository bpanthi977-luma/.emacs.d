(defvar bp/gptel-ollama
  (gptel-make-ollama "Ollama"
    :host "localhost:11434"
    :stream t
    :models '(gemma3:4b)))
