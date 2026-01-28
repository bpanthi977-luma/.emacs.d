;; 20-20-20 for rule
(defvar bp/eye-care-timer nil)

(defcustom bp/eye-care-interval (* 20 60)
  "The time interval for eye rest. Usually 20 minutes.

You need to restart the time after changing this variable.")

(defcustom bp/eye-care-duration 20
  "The duration for which to take break. Usually 20 seconds.")

(defun bp/eye-care-beep ()
  ;; eye-care-sound1 was downloaded from https://20-20-20-timer.netlify.app/
  (start-process "afplay-process" nil "afplay" "./eye-care-sound1.wav"))

(defun bp/eye-care-routine ()
  (bp/eye-care-beep)
  (run-at-time bp/eye-care-duration nil #'bp/eye-care-beep))

(defun bp/eye-care-start ()
  (interactive)
  (if bp/eye-care-timer
      (error "Timer already running.")
    (setf bp/eye-care-timer
	  (run-at-time bp/eye-care-interval
		       bp/eye-care-interval
		       #'bp/eye-care-routine))))

(defun bp/eye-care-stop ()
  (interactive)
  (if (not bp/eye-care-timer)
      (error "Time not running")
    (cancel-timer bp/eye-care-timer)
    (setf bp/eye-care-timer nil)))
