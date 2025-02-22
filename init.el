;; Setup package repository
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

(defmacro load* (path)
  `(load (expand-file-name ,path (file-name-directory load-file-name))))

(setf custom-file "custom.el")
(load* "modules/init.el")
