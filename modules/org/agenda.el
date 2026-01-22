(use-package org-agenda
  :ensure nil
  :bind (:map bp/global-prefix-map
	      (("o a" . org-agenda)))
  :config
  (define-key org-agenda-mode-map (kbd bp/global-prefix) bp/global-prefix-map)
  (setf org-agenda-span 'day
	org-agenda-files '("private/tasks.org" "private/tasks.org_archive" "private/plan.org")
	org-agenda-skip-scheduled-if-deadline-is-shown t))
(use-package org-tasks
  :ensure nil
  :config

  (defun bp/org-tasks-link-with-id ()
    (interactive)
    (org-tasks-custom-id)
    (org-store-link nil t))

  (bind-keys :map bp/global-prefix-map
	     ("o i" . org-tasks-start)
	     ("o M-l" . bp/org-tasks-link-with-id)
	     ("o u" . org-tasks-update-timetaken)
	     ("o U" . org-tasks-update-all-timetaken)))
