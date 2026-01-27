(use-package org-agenda
  :ensure nil
  :bind (:map bp/global-prefix-map
	      (("o a" . org-agenda)))
  :config
  (define-key org-agenda-mode-map (kbd bp/global-prefix) bp/global-prefix-map)
  (setf org-agenda-span 'day
	org-agenda-files (expand-file-name "private/agenda_files.txt" org-directory)
	org-enforce-todo-dependencies t))

(use-package org-super-agenda
  :ensure t
  :config
  (org-super-agenda-mode)
  (setq org-agenda-custom-commands
	'(("n" "Agenda and all TODOs" ((agenda "") (alltodo "")))
	  ("a" "Daily with Sched vs Deadlines"
	   ((agenda ""
		    ((org-agenda-span 'day)
		     (org-super-agenda-groups
		      '((:name "Scheduled"
			       :time-grid t
			       :order 1)

			(:name "Overdue"
			       :scheduled past
			       :order 2)

			(:name "Deadlines"
			       :deadline t
			       :order 3)
			(:name "Other"
			       :anything t
			       :order 90)))))))
	  ("d" "Scheduled Today"
	   agenda ""
	   ((org-agenda-start-with-log-mode t)
	    (org-agenda-log-mode-items '(closed))
	    (org-super-agenda-keep-order t)
	    (org-super-agenda-groups
	     '((:name "Clocked today"
		      :log close
		      :time-grid t)
	       (:discard (:anything t)))))))))

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
