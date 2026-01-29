(use-package org-alert
  :ensure t
  :defer nil
  :config

  (setq org-alert-interval 60
	org-alert-notify-cutoff 1
	org-alert-notify-after-event-cutoff 0)
  (org-alert-enable))

(use-package alert
  :ensure t
  :defer t
  :config

  (cond ((eql system-type 'darwin)

	 (defun bp/alert-osx-notify (info)
	   "Just like the default osx-notifier but with sound"
	   (do-applescript (format "display notification %S with title %S sound name \"Ping\""
				   (plist-get info :message)
				   (plist-get info :title))))

	 (alert-define-style 'bp-osx-notifier
			     :title "Notify using native OSX notification with sound"
			     :notifier #'bp/alert-osx-notify)
	 (setq alert-default-style 'bp-osx-notifier))))
