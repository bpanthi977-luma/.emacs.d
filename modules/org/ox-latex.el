(use-package ox-latex
  :ensure nil
  :config
  (setq org-preview-latex-default-process 'dvisvgm)
  (setq org-preview-latex-image-directory "/tmp/ltximg/")
  (plist-put org-format-latex-options :scale 2)

  (defun bp/adjust-latex-previews-scale ()
    "Adjust the size of latex preview fragments when changing the
buffer's text scale."
    (pcase major-mode
      ('latex-mode
       (dolist (ov (overlays-in (point-min) (point-max)))
	 (if (eq (overlay-get ov 'category)
		 'preview-overlay)
	     (bp/latex-preview--resize-fragment ov))))
      ('org-mode
       (dolist (ov (overlays-in (point-min) (point-max)))
	 (if (eq (overlay-get ov 'org-overlay-type)
		 'org-latex-overlay)
	     (bp/latex-preview--resize-fragment ov))))))

  (defun bp/latex-preview--resize-fragment (ov)
    (overlay-put
     ov 'display
     (cons 'image
	   (plist-put
	    (cdr (overlay-get ov 'display))
	    :scale (* 2 (/ (frame-char-height) 12) (expt text-scale-mode-step text-scale-mode-amount))))))

  (add-hook 'text-scale-mode-hook #'bp/adjust-latex-previews-scale)
  (defadvice org-latex-preview (after bp/org-latex-preview--adjust-scale activate)
    (bp/adjust-latex-previews-scale)))
