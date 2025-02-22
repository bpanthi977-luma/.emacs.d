;; Setup package repository
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

;; Basic config
(setf init-dir (file-name-directory load-file-name))

(setf custom-file "custom.el")
(cua-mode t)
(setf backup-directory-alist `(("." . ,(concat init-dir "/savefiles/backups/"))))

;; Load modules
(defun load* (path)
  (load (expand-file-name path (file-name-directory load-file-name))))

(load* "modules/init.el")
