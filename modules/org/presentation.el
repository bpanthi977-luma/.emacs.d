;; For exporting org files as a beamer presentation
(use-package ox-beamer
  :after org
  :config
  (cl-pushnew '("beamer-show-heading" . "
#+BEGIN_EXPORT latex
\\AtBeginSection[]{
  \\begin{frame}
  \\vfill
  \\centering
  \\begin{beamercolorbox}[sep=8pt,center,shadow=true,rounded=true]{title}
    \\usebeamerfont{title}\\insertsectionhead\\par%
  \\end{beamercolorbox}
  \\vfill
  \\end{frame}
}
#+end_export
")
	      org-export-global-macros))

;; For presenting org files as presentation
(use-package org-tree-slide
  :ensure t
  :defer t)
