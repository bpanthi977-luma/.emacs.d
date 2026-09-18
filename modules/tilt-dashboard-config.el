(use-package tilt-dashboard
  :load-path "modules/tilt-dashboard"
  :commands bp/tilt-dashboard
  :bind (:map bp/agent-prefix-map
              ("t" . bp/tilt-dashboard)))
