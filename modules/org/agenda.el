(use-package org-agenda
  :ensure nil
  :bind (:map bp/global-prefix-map
	      (("o a" . org-agenda)))
  :config
  (require 'org-tasks)
  (org-tasks-mode)
  (define-key org-agenda-mode-map (kbd bp/global-prefix) bp/global-prefix-map)
  (define-key org-agenda-mode-map (kbd "C-c C-x C-i") #'org-tasks-start)
  (setf org-agenda-span 'day
	org-agenda-files '("private/tasks.org" "private/tasks.org_archive" "private/plan.org")
	org-agenda-skip-scheduled-if-deadline-is-shown t))
