;; Set the api key in .authinfo file like:
;; machine generativelanguage.googleapis.com apikey password <<YOUR_API_KEY>>

(gptel-make-gemini "Gemini" :stream t :key #'gptel-api-key-from-auth-source)
