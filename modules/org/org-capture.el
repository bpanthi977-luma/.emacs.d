(use-package org-capture
  :bind (:map bp/global-prefix-map
	      ("o c" . org-capture))
  :init
  (setq org-capture-templates `(("t" "Todo" entry (file+datetree "~/org/private/tasks.org")
				 "* TODO %?\nCREATED: %U\n %i\n  %a")
                                ("c" "Clock" entry (file+datetree "~/org/private/tasks.org")
                                 "* %? \n" :clock-in t :clock-keep t)
                                ("j" "Journal" entry (file+datetree "~/org/private/journal.org.gpg")
                                 "* %?\nEntered on %U\n  %i\n  %a")
                                ("e" "Event" entry (file+datetree "~/org/private/dates.org")
                                 "* %?\n %i \n %a \n"
                                 :time-prompt t)
                                ("n" "Note" entry (file "~/org/private/notes.org" )
                                 "* %?\nCREATED: %U\n")
                                ("k" "Quote" item (file+headline "~/org/notes.org" "Quotes")
                                 "%? :: %x"))))
