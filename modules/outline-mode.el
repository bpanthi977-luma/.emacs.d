(defun bp/outline-cycle ()
  (interactive)
  (if (outline-on-heading-p)
      (outline-cycle)
    (outline-cycle-buffer)))

(bind-key "M-TAB" 'bp/outline-cycle outline-minor-mode-map)
