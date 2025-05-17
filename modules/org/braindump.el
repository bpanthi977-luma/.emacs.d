(use-package ox-publish
  :ensure nil
  :after org
  :config
  (setf org-export-allow-bind-keywords t)
  (defvar bp/org-publish-braindump-dir "~/Development/Web/Blog/blog/braindump/")
  (setf org-babel-default-header-args '((:session . "none")
					(:results . "replace")
					(:exports . "both")
                                        (:eval . "no-export")
                                        (:cache . "no")
					(:noweb . "no")
					(:hlines . "no")
					(:tangle . "no")))

  (setf org-babel-default-inline-header-args '((:session . "none")
					(:results . "replace")
					(:exports . "results")
                                        (:eval . "no-export")
					(:hlines . "yes")))

  (setq org-publish-project-alist
        `(
          ("braindump-org"
           :base-directory "~/Documents/synced/Notes/"
           :base-extension "org"
           :publishing-directory ,bp/org-publish-braindump-dir
           :exclude "^notes.org\\|^tasks.org\\|^rss.org"
           :recursive nil
           :headline-levels 4
           :auto-preamble t
	   :html-prefer-user-labels t
           :auto-sitemap nil))))
