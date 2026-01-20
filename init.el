;; Setup package repository
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

;; Basic config
(setf init-dir (file-name-directory load-file-name))

(setf custom-file (expand-file-name "custom.el" init-dir))

(global-set-key (kbd "C-z") #'undo)
(setf backup-directory-alist `(("." . ,(concat init-dir "savefiles/backups/"))))
(setq auto-save-file-name-transforms `((".*" ,(concat init-dir "savefiles/autosave/" "\\2") t)))
(tool-bar-mode -1)
(scroll-bar-mode -1)
(setf ring-bell-function 'ignore)
(setf use-short-answers t)

(setf epg-pinentry-mode 'loopback)
(add-hook 'text-mode-hook #'visual-line-mode)

;; Load modules
(defun load* (path)
  (load (expand-file-name path (file-name-directory load-file-name))))

(when (file-exists-p custom-file)
  (load-file custom-file))
(load* "modules/init.el")
