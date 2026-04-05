;;; gptel-agenda-tool.el --- Org Agenda clock log tool for gptel

(require 'org-agenda)
(require 'gptel)

(defun gptel-agenda--fetch-log (date)
  "Fetch the Org agenda clock log for DATE (YYYY-MM-DD).
This function generates a one-day agenda view with log mode enabled,
captures the content, and returns it as a string."
  (condition-case err
      (save-window-excursion
        (let ((org-agenda-start-with-log-mode t)
              (org-agenda-log-mode-items '(clock))
              (org-agenda-span 'day)
              (org-agenda-use-sticky-window nil)
              (org-agenda-window-setup 'current-window)
              (org-agenda-sticky nil))
          ;; Generate the agenda list for the specific date
          (org-agenda-list nil date)
          (let ((buffer (get-buffer org-agenda-buffer-name)))
            (if buffer
                (with-current-buffer buffer
                  (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                    ;; Clean up the temporary agenda buffer
                    (let ((kill-buffer-query-functions nil))
                      (kill-buffer buffer))
                    content))
              "Error: Agenda buffer not created."))))
    (error (format "Error fetching agenda for %s: %s" date (error-message-string err)))))

(defvar gptel-agenda-log-tool
  (gptel-make-tool
   :name "agenda_log"
   :function #'gptel-agenda--fetch-log
   :description "Retrieve the Org agenda clock log for a specific day. Returns a formatted agenda view showing scheduled tasks and clocked time."
   :args '((:name "date"
            :type string
            :description "The date in YYYY-MM-DD format (e.g., 2026-03-10)"))
   :category "org-agenda")
  "Gptel tool for fetching Org agenda logs.")

(add-to-list 'gptel-tools gptel-agenda-log-tool)
(provide 'gptel-agenda-tool)
