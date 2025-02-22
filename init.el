;; Setup package repository
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

;; Basic config
(setf init-dir (file-name-directory load-file-name))

(setf custom-file "custom.el")

(global-set-key (kbd "C-z") #'undo)
(setf backup-directory-alist `(("." . ,(concat init-dir "/savefiles/backups/"))))
(tool-bar-mode -1)
(scroll-bar-mode -1)
(setf use-short-answers t)
(setf ido-enable-flex-matching t)
(ido-everywhere t)
(ido-mode t)

;; Load modules
(defun load* (path)
  (load (expand-file-name path (file-name-directory load-file-name))))

(load* "custom.el")
(load* "modules/init.el")
