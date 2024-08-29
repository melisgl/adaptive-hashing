;;;; TODO
;;;;
;;;; - Use CLOCK_PROCESS_CPUTIME_ID?
;;;;
;;;; - Stddev is not very useful for the geometric avarage line. It
;;;;   would be more meaningful if all data was in the log domain.
;;;;   Maybe copy the timing and take the log of all values; or add a
;;;;   log option to all timing accessors and functions?
;;;;
;;;; - Print table of ratios?
;;;;
;;;; - Add parallel option (as opposed to interleaved)?
;;;;
;;;; - Track other statistics (e.g. rank (estimate the probability of
;;;;   each rank))
;;;;
;;;; - Rerun a subset of benchmarks based on a previous run (e.g.
;;;;   where the biggest differences were)
;;;;
;;;; - Document
;;;;
;;;; - How to handle failures in benchmarks?
;;;;
;;;; - Timeouts
;;;;
;;;; - Better estimate measurement overhead
;;;;
;;;; - DEFTESTlike macro?
;;;;
;;;; - Handle failures (<= 1 exit-code 127)?
;;;;
;;;;
;;;; ---- Generalization -----
;;;;
;;;; - Allow arbitrary statistics
;;;;
;;;; - Multiple measurements in one FUNCALL / RUN-PROGRAM? (To reduce
;;;;   the RUN-PROGRAM overhead) (network protocol?)
;;;;
;;;; ----- Output -----
;;;;
;;;; - For each benchmark, print a copy-pasteable shell command to
;;;;   rerun it.
;;;;
;;;; - Machine-readable output
;;;;
;;;; - Select output columns
;;;;
;;;; - Control format (e.g. number of float digits)
;;;;
;;;; - Streaming table output (grow/resize columns as necessary)
;;;;
;;;; ----- Tests -----
;;;;
;;;; - Show that delta works better than absolute: maybe don't control
;;;;   cpu frequency?
;;;;
;;;; - Show that delta works better than beta


(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :alexandria)
  (require :split-sequence))


;;;; Utilities

(defun random-permutation (n)
  (alexandria:shuffle (alexandria:iota n)))


;;;; KLUDGE: When started from the command line, redefine
;;;; SB-SYS::GET-SYSTEM-INFO (used by SB-EXT:CALL-WITH-TIMING below)
;;;; with SB-UNIX:RUSAGE_CHILDREN instead of SB-UNIX:RUSAGE_SELF. It's
;;;; all a secondary concern, though, because for real time we rely on
;;;; clock_gettime() for high-resolution timing.

(defmacro without-redefinition-warnings (&body body)
  #+sbcl
  `(locally
       (declare (sb-ext:muffle-conditions sb-kernel:redefinition-warning))
     (handler-bind ((sb-kernel:redefinition-warning #'muffle-warning))
       ,@body))
  #-sbcl
  `(progn ,@body))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (sb-ext:unlock-package :sb-sys))

(defun redefine-get-system-info ()
  (without-redefinition-warnings
    sb-sys::
    (defun get-system-info ()
      (multiple-value-bind
            (err? utime stime maxrss ixrss idrss isrss minflt majflt)
          (sb-unix:unix-getrusage sb-unix:rusage_children)
        (declare (ignore maxrss ixrss idrss isrss minflt))
        (unless err?     ; FIXME: nonmnemonic (reversed) name for ERR?
          (error "Unix system call getrusage failed: ~A." (strerror utime)))
        (values utime stime majflt)))))


;;;; Timing

;;; One milli-, micro- and nanosecond in seconds
(defconstant +ms+ (expt 10 -3))
(defconstant +us+ (expt 10 -6))
(defconstant +ns+ (expt 10 -9))

;;; Add :RUN-TIME-US to PLIST to make it a TIMING. PLIST is the
;;; argument list SB-EXT:CALL-WITH-TIMING calls its TIMER argument
;;; with. :RUN-TIME-US is no longer used though, so maybe this can be
;;; removed.
(defun %make-timing (&rest plist)
  (let ((plist (copy-list plist)))
    (setf (getf plist :run-time-us)
          (+ (timing-value plist :user-run-time-us)
             (timing-value plist :system-run-time-us)))
    plist))

;;; FIXME: hard coded
(defconstant +clock-monotonic+ 1)

;;; Like SB-EXT:CALL-WITH-TIMING, but TIMER is called with a TIMING.
(defmacro with-timing (timer fn)
  (alexandria:with-unique-names
      (start-clock-sec start-clock-ns end-clock-sec end-clock-ns args)
    `(let ((,start-clock-sec nil)
           (,start-clock-ns nil)
           (,end-clock-sec nil)
           (,end-clock-ns nil))
       ;; This uses getrusage(), which has at best microsecond
       ;; resolution.
       (sb-ext:call-with-timing
        (lambda (&rest ,args)
          (let ((real-time-ns (+ (/ (- ,end-clock-sec ,start-clock-sec) +ns+)
                                 (- ,end-clock-ns ,start-clock-ns))))
            (funcall ,timer (apply #'%make-timing :real-time-ns real-time-ns
                                   ,args))))
        (lambda ()
          ;; The higher resolution timer goes inside, of course.
          (multiple-value-setq (,start-clock-sec ,start-clock-ns)
            (sb-unix:clock-gettime +clock-monotonic+))
          (funcall ,fn)
          (multiple-value-setq (,end-clock-sec ,end-clock-ns)
            (sb-unix:clock-gettime +clock-monotonic+)))))))

(defun timing-value (timing key)
  (let ((x (if (functionp key)
               (funcall key timing)
               (getf timing key))))
    (if (consp x)
        (car x)
        x)))

;;; This is the variance of the measurement (0 by default). Currently
;;; only used when multiple timings are averaged and their sample
;;; variance is estimated (see MEAN-TIMING).
(defun timing-uncertainty (timing key)
  (let ((x (if (functionp key)
               (funcall key timing)
               (getf timing key))))
    (or (and (consp x)
             (cdr x))
        0)))

;;; 0s is measured sometimes ...
(defparameter *log-kludge* 1d-20)

(defun log-timing (timing)
  (list* :logp t
         (loop for (key value) on timing by #'cddr
               append (list key (cond ((numberp value)
                                       (log (+ value *log-kludge*)))
                                      ((consp value)
                                       ;; Translating variance to the log
                                       ;; domain is underspecified.
                                       (assert nil))
                                      (t
                                       value))))))

(defun timings-mean (timings key)
  (let ((sum 0)
        (n (length timings)))
    (map nil (lambda (timing)
               (incf sum (timing-value timing key)))
         timings)
    (if (zerop n)
        0
        (/ sum n))))

(defun timings-variance-of-mean (timings key)
  (let ((mean (timings-mean timings key))
        (sum 0))
    (map nil (lambda (timing)
               (let ((x (timing-value timing key)))
                 (incf sum (expt (- x mean) 2))))
         timings)
    (/ sum (length timings))))

(defun timing-rse (timing)
  (/ (sqrt (timing-uncertainty timing :real-time-ns))
     (+ (timing-value timing :real-time-ns) +ns+)))

;;; Return a timing whose TIMING-VALUEs are the estimated means of
;;; TIMINGS, and whose TIMING-UNCERTAINTYs are the estimated variance
;;; of that mean.
(defun mean-timing (timings)
  (let ((keys (loop for rest on (first timings) by #'cddr
                    collect (first rest))))
    (list* :logp (timing-value (first timings) :logp)
           (loop for key in keys
                 unless (eq key :logp)
                   append (list key (cons (timings-mean timings key)
                                          (timings-variance-of-mean timings
                                                                    key)))))))

(defun timings-average-uncertainy (timings key)
  (/ (loop for timing in timings
           sum (timing-uncertainty timing key))
     (length timings)))

(defun average-timings (timings)
  (let ((keys (loop for rest on (first timings) by #'cddr
                    collect (first rest))))
    (list* :logp (timing-value (first timings) :logp)
           (loop for key in keys
                 unless (eq key :logp)
                   append (list key (cons (timings-mean timings key)
                                          (timings-average-uncertainy timings
                                                                      key)))))))

(defvar *time-unit* 1)

(defvar *print-timing-gc* nil)

(defun print-heading (serial-no &optional marker)
  (if serial-no
      (format t "~A~3D" marker serial-no)
      (format t "    "))
  (format t " cmd    real  stddev     cpu  stddev ~
             (   user +     sys~:[~;,      gc~])~%"
          *print-timing-gc*))

(defun print-timing (timing &key (time-unit *time-unit*))
  (labels ((value (key)
             (timing-value timing key))
           (uncertainty (key)
             (timing-uncertainty timing key))
           (print-real-or-run-time (mean stddev)
             (format t "~7,3F" mean)
             (if (/= stddev 0)
                 ;; Biased sample stddev
                 (format t " ~7,3F" stddev)
                 (format t "        ")))
           (scale (x a)
             (if (value :logp)
                 (+ x (log a))
                 (* x a))))
    (print-real-or-run-time (scale (value :real-time-ns) (/ +ns+ time-unit))
                            (sqrt (uncertainty :real-time-ns)))
    (format t " ")
    (print-real-or-run-time (scale (value :run-time-us) (/ +us+ time-unit))
                            (sqrt (uncertainty :run-time-us)))
    (format t " (~7,3F + ~7,3F~@[, ~7,3F~])~%"
            (scale (value :user-run-time-us) (/ +us+ time-unit))
            (scale (value :system-run-time-us) (/ +us+ time-unit))
            (and *print-timing-gc*
                 ;; FIXME: :GC-REAL-TIME-MS?
                 (getf timing :gc-run-time-ms)
                 (scale (value :gc-run-time-ms) (/ +ms+ time-unit))))))


;;;; Commands

(defun run-program* (command)
  (uiop:with-temporary-file (:pathname output-file)
    (multiple-value-bind (output error-output exit-code)
        ;; https://stackoverflow.com/questions/4056075/how-to-redirect-a-program-that-writes-to-tty
        (uiop:run-program (list "script" "-q" "-c" command "/dev/null")
                          :ignore-error-status t :output output-file
                          :error-output output-file
                          :force-shell nil)
      (declare (ignore output error-output))
      (unless (zerop exit-code)
        (format t "Exit code ~S from command ~A~%Output:~%~A~%"
                exit-code command
                (alexandria:read-file-into-string output-file))
        (sb-ext:exit :code exit-code :abort t)))))

(defun command-name (command-names i)
  (if (< i (length command-names))
      (format nil "~3@A" (elt command-names i))
      (format nil "~3D" (1+ i))))

(defun commands-to-functions (commands command-names)
  (loop for command in commands
        for i upfrom 0
        do (format t "Command ~A: ~A~%" (command-name command-names i)
                   command)
        collect (if (stringp command)
                    (let ((command command))
                      (lambda ()
                        (run-program* command)))
                    command)))


;;;; Estimating the run times of multiple commands with either Delta
;;;; or Beta estimator

(defun estimate-run-times (commands
                           &key command-names
                             (estimator :delta) (warmup 0) (runs 10)
                             measure-gc (geometricp t) (time-unit *time-unit*))
  (let* ((fns (commands-to-functions commands command-names))
         (n-commands (length fns))
         (timings (make-array n-commands :initial-element ()))
         ;; Timings further grouped by the previous program. This is
         ;; to detect some violations of the main assumption, that
         ;; requires the uncontrolled state to have the same effect on
         ;; all programs.
         (timings-after (make-array (list n-commands n-commands)
                                    :initial-element ()))
         (*time-unit* time-unit)
         (*print-timing-gc* measure-gc)
         (prev nil)
         (printp nil))
    (flet ((print-command-name (command-index kind &optional n)
             (print-command-name command-names command-index kind n))
           (min-n-runs ()
             (loop for timings across timings
                   minimizing (length timings)))
           (timer (i kind)
             (when printp
               (print-command-name command-names i kind))
             (let ((fn (elt fns i)))
               (with-timing (lambda (timing)
                              (let ((timing (if geometricp
                                                (log-timing timing)
                                                timing)))
                                (when printp
                                  (print-timing timing))
                                (push timing (aref timings i))
                                (when prev
                                  (push timing (aref timings-after prev i)))))
                 fn))
             (setq prev i)))
      (when (plusp warmup)
        (format t "~%Warming up~%")
        (loop for run below warmup do
          (terpri)
          (print-heading (1+ run) "B")
          (loop for i in (random-permutation n-commands)
                do (print-command-name i :shuffled)
                   (with-timing #'print-timing
                     (elt fns i)))))
      (format t "~%Benchmarking~%")
      (let ((mod (max 1 (floor runs 100))))
        (loop
          (let ((min-n-runs (min-n-runs)))
            (setq printp (or (zerop (mod min-n-runs mod))
                             (= min-n-runs (1- runs))))
            (when (<= runs min-n-runs)
              (return))
            (when printp
              (terpri)
              (print-heading (1+ min-n-runs) (ecase estimator
                                               ((:delta) "D")
                                               ((:beta) "B"))))
            (ecase estimator
              ((:delta) (run-delta-batch n-commands #'min-n-runs #'timer))
              ((:beta) (run-beta-batch n-commands #'timer)))
            (assert (= (min-n-runs) (1+ min-n-runs)))
            (when printp
              (loop for i below n-commands
                    do (let ((timings (aref timings i)))
                         (print-command-name i (if geometricp
                                                   :geometric-mean
                                                   :arithmetric-mean)
                                             (length timings))
                         (print-timing (mean-timing timings))))
              (check-assumption timings timings-after :real-time-ns geometricp
                                command-names))))))
    (format t "~%Total runs: ~D~%" (loop for timings across timings
                                         sum (length timings)))
    (map 'list (lambda (timings)
                 (mean-timing timings))
         timings)))

(defun check-assumption (timings timings-after key geometricp command-names)
  ;; Assuming order (AREF TIMINGS-AFTER I J), where I is the previous,
  ;; J is the current program (the index of).
  (let* ((ta timings-after)
         (n (array-dimension ta 0))
         ;; The "complement" of TA. Timings after I /= J.
         (tac (make-array (list n n) :initial-element ())))
    ;; Populate TAC
    (dotimes (j n)
      (let ((j-timings (aref timings j)))
        (dotimes (i n)
          (let ((i-j-timings (aref ta i j)))
            (setf (aref tac i j) (set-difference j-timings i-j-timings))))))
    ;; If our assumptions hold, then for each i, E[L | i, j] - E[L |
    ;; not i, j] = E[L | i, k] - E[L | not i, k] for all j and k.
    (let ((diffs (make-array (list n n))))
      (dotimes (i n)
        (dotimes (j n)
          (setf (aref diffs i j)
                (if (or (zerop (length (aref ta i j)))
                        (zerop (length (aref tac i j))))
                    nil
                    (- (timings-mean (aref ta i j) key)
                       (timings-mean (aref tac i j) key))))))
      (dotimes (i n)
        (format t "prev=~A: " (command-name command-names i))
        (dotimes (j n)
          (let ((d (aref diffs i j)))
            (if (null d)
                (format t "   N/A")
                (format t " ~5F"
                        (if geometricp
                            d
                            (/ (* d +ns+) *time-unit*))))))
        (terpri)))))

(defun run-delta-batch (n-commands min-n-runs-fn timer-fn)
  (let ((min-n-runs (funcall min-n-runs-fn)))
    ;; Run commands until the minimum number of runs changes.
    (loop do (funcall timer-fn (random n-commands) :random)
          while (= min-n-runs (funcall min-n-runs-fn)))))

(defun run-beta-batch (n-commands timer-fn)
  (loop for i in (random-permutation n-commands)
        do (funcall timer-fn i :shuffled)))

(defun print-command-name (command-names command-index kind &optional n)
  (format t "~A ~A " (ecase kind
                       ((:shuffled) "shuf")
                       ((:arithmetric-mean) (format nil "A~3D" n))
                       ((:geometric-mean) (format nil "G~3D" n))
                       ((:random) "rand"))
          (command-name command-names command-index))
  (force-output))

#+nil
(estimate-run-times (list (lambda () (sleep (+ 0.075 (random 0.05))))
                          (lambda () (sleep (+ 0.175 (random 0.05)))))
                    :estimator :delta
                    :runs 100
                    :time-unit 0.1)
#+nil
(estimate-run-times (list (lambda () (sleep (+ 0.075 (random 0.05))))
                          (lambda () (sleep (+ 0.175 (random 0.05)))))
                    :estimator :beta)


;;;; Benchmarks

(defun benchmark-weight (benchmark)
  (getf benchmark :weight 1))

(defun benchmark-commands (benchmark)
  (getf benchmark :commands))

(defun blank-char-p (char)
  (member char '(#\Space #\Tab)))

(defun blank-string-p (string)
  (every #'blank-char-p string))

;;; Read consecutive non-blank lines as a list of commands. Weights
;;; are not currently supported.
(defun parse-benchmark-file (stream)
  (let ((benchmarks ()))
    (loop
      (let ((lines (loop for line = (read-line stream nil nil)
                         while (and line (not (blank-string-p line)))
                         collect line)))
        (unless lines
          (return))
        (push (list :commands lines) benchmarks)))
    (reverse benchmarks)))


;;;; Main entry point

(defun time-sequentially (benchmarks time-it
                          &key command-names shuffle max-rse skip-high-rse
                            (measure-gc t) (geometricp t)
                            (time-unit *time-unit*))
  (let* ((benchmarks (if shuffle (alexandria:shuffle benchmarks) benchmarks))
         (n-commands (length (benchmark-commands (first benchmarks))))
         (command-timings (make-array n-commands :initial-element ()))
         (skipp (and skip-high-rse max-rse))
         ;; Contains even skipped benchmarks.
         (command-timings/skip (when skipp
                                 (make-array n-commands :initial-element ())))
         (n-skipped 0)
         (*print-timing-gc* measure-gc)
         (*time-unit* time-unit))
    (flet ((print-command-totals (command-timings)
             (loop for i below n-commands
                   do (format t "~A ~A " (if geometricp "geom" "arit")
                              (command-name command-names i))
                      (print-timing (average-timings
                                     (aref command-timings i))))))
      (loop for benchmark in benchmarks
            do (assert (= (length (benchmark-commands benchmark)) n-commands)))
      (loop
        for benchmark-index upfrom 0
        for benchmark in benchmarks
        do (format t "~%Benchmark ~S~%" (1+ benchmark-index))
           (let* ((timings (funcall time-it (benchmark-commands benchmark)))
                  (rse (loop for timing in timings
                             maximize (timing-rse timing)))
                  (skip-this-p (and skipp (< max-rse rse))))
             (when skip-this-p
               (format t "~%Final RSE too high. ~
                          Skipping results of benchmark ~D.~%"
                       (1+ benchmark-index))
               (incf n-skipped))
             (loop for i upfrom 0
                   for timing in timings
                   do (unless skip-this-p
                        (push timing (aref command-timings i)))
                      (when skipp
                        (push timing (aref command-timings/skip i))))
             ;; Print totals without skipped
             (format t "~%Totals after benchmark ~S" (1+ benchmark-index))
             (when (plusp n-skipped)
               (format t " (excluding ~S skipped)"  n-skipped))
             (terpri)
             (print-heading nil)
             (print-command-totals command-timings)
             ;; Print totals with skipped if any
             (when (plusp n-skipped)
               (format t "~%Totals after benchmark ~S (including ~S skipped)~%"
                       (1+ benchmark-index) n-skipped)
               (print-heading nil)
               (print-command-totals command-timings/skip)))))))

#+nil
(time-sequentially `((:commands ,(list (lambda () (sleep 0.1))
                                       (lambda () (sleep 0.2))))
                     (:commands ,(list (lambda () (sleep 0.01))
                                       (lambda () (sleep 0.02)))))
                   #'estimate-run-times)


;;;; Command line

(defun parse-arguments (args)
  (let ((options ()))
    (loop until (endp args) do
      (let ((arg (pop args)))
        (unless (alexandria:starts-with-subseq "-" arg)
          (push arg args)
          (return))
        (when (string= arg "--")
          (return))
        (let ((value (pop args)))
          (push (cons arg value) options))))
    (values (reverse options) args)))

(defun get-option-string-value (options option-name &optional default)
  (let ((value (alexandria:assoc-value options option-name :test #'string=)))
    (or value default)))

(defun get-option-integer-value (options option-name &optional default)
  (let ((value (alexandria:assoc-value options option-name :test #'string=)))
    (if value
        (parse-integer value)
        default)))

(defun get-option-boolean-value (options option-name &optional default)
  (let ((x (get-option-integer-value options option-name nil)))
    (if x
        (not (zerop x))
        default)))

(defun get-option-real-value (options option-name &optional default)
  (let ((value (alexandria:assoc-value options option-name :test #'string=)))
    (if value
        (let ((*read-eval* nil))
          (the real (read-from-string value)))
        default)))

(defun get-option-categorical-value (options option-name allowed-values
                                     &optional default)
  (let ((value (alexandria:assoc-value options option-name :test #'string=)))
    (when value
      (unless (member value allowed-values :test #'string=)
        (error "Unexpected value ~A for option ~A.~%Not one of ~{~A~^,~}."
               option-name value allowed-values)))
    (or value default)))

#+nil (parse-arguments '("-w" "1" "-r" "10" "--" "a" "b" "c"))
#+nil (parse-arguments '("a" "b" "c"))

;;; Return the maximum Relative Standard Deviation (sqrt(var) / abs(mean)).
(defun max-rsd (means variances)
  (loop for m across means
        for v across variances
        maximize (/ (sqrt v) (abs m))))

(defun deltist ()
  (redefine-get-system-info)
  (handler-case
      (multiple-value-bind (options commands)
          (parse-arguments (rest sb-ext:*posix-argv*))
        (let* ((*random-state* (make-random-state t))
               (estimator (get-option-categorical-value options "--estimator"
                                                        '("delta" "beta")
                                                        "delta"))
               (estimator (if (string= estimator "delta") :delta :beta))
               (geometricp (get-option-boolean-value options "--geometric" t))
               (time-unit (get-option-real-value options "--time-unit" 1))
               (warmup (get-option-integer-value options "--warmup" 1))
               (runs (get-option-integer-value options "--runs" 10))
               (command-names
                 (split-sequence:split-sequence
                  #\Space (get-option-string-value options "--command-names"
                                                   nil)
                  :remove-empty-subseqs t))
               (benchmark-file (get-option-string-value options
                                                        "--benchmark-file"
                                                        nil))
               (shuffle-benchmarks (get-option-boolean-value
                                    options "--shuffle-benchmarks" nil))
               (max-rse (get-option-real-value options "--max-rse" 0.001))
               (skip-high-rse (get-option-boolean-value
                               options "--skip-high-rse" nil)))
          (format t "~%estimator: ~A, geometric: ~S, time-unit: ~F sec, ~
                     warmup: ~S, runs: ~S, ~%~
                     benchmark-file: ~S, shuffle-benchmarks: ~S, ~
                     max-rse: ~,1F, skip-high-rse: ~S~%"
                  estimator geometricp time-unit warmup runs
                  benchmark-file shuffle-benchmarks max-rse skip-high-rse)
          (flet ((time-it (commands)
                   (estimate-run-times commands
                                       :command-names command-names
                                       :estimator estimator
                                       :warmup warmup :runs runs
                                       :measure-gc nil
                                       :geometricp geometricp
                                       :time-unit time-unit)))
            (when commands
              (time-it commands))
            (when benchmark-file
              (time-sequentially (if (zerop (length benchmark-file))
                                     (parse-benchmark-file *standard-input*)
                                     (with-open-file (s benchmark-file)
                                       (parse-benchmark-file s)))
                                 #'time-it
                                 :command-names command-names
                                 :max-rse max-rse
                                 :skip-high-rse skip-high-rse
                                 :shuffle shuffle-benchmarks
                                 :measure-gc nil :geometricp geometricp
                                 :time-unit time-unit)))
          (format t "~%Done.~%")))
    ((or sb-sys:interactive-interrupt sb-int:broken-pipe) ()
      ;; 130=128+SIGINT
      (sb-ext:exit :code 130 :abort t))))


;;;; Show that delta works better than absolute
;;;;
;;;; Plot delta vs number of runs? (repeated, with error bars)

#+nil
(defun burn-cpu (&key (n 1))
  (declare (type (integer 0 10) n))
  (loop for i below (* n 99999999)))

(defun burn-cpu (&key (n 1))
  (declare (type (integer 0 10) n))
  (loop for i below (* n 999999)))

(defun burn-cpu-2 (&key (n 1))
  (declare (type (integer 0 10) n))
  (loop for i below (* n 99999)
        count (zerop (mod i 100))))

#+nil
(loop (burn-cpu))
#+nil
(with-timing #'print (lambda () (sleep 0.1)))

#+nil
(estimate-run-times (list #'burn-cpu-2
                          #'burn-cpu)
                    :estimator :delta :runs 2000 :geometricp t
                    :time-unit 0.0001)

#+nil
(estimate-run-times (list #'burn-cpu-2
                          #'burn-cpu)
                    :estimator :beta :runs 2000 :geometricp t
                    :time-unit 0.0001)

;;; FIXME: Arithmethic average of geometric averages ...
#+nil
(estimate-run-times (list #'burn-cpu-2
                          #'burn-cpu
                          #'burn-cpu-2
                          #'burn-cpu
                          #'burn-cpu-2
                          #'burn-cpu
                          #'burn-cpu-2
                          #'burn-cpu
                          #'burn-cpu-2
                          #'burn-cpu)
                    :estimator :delta :runs 400 :geometricp t
                    :time-unit 0.0001)

#+nil
(estimate-run-times (list #'burn-cpu-2
                          #'burn-cpu
                          #'burn-cpu-2
                          #'burn-cpu
                          #'burn-cpu-2
                          #'burn-cpu
                          #'burn-cpu-2
                          #'burn-cpu
                          #'burn-cpu-2
                          #'burn-cpu)
                    :estimator :beta :runs 400 :geometricp t
                    :time-unit 0.0001)

#+nil
(loop repeat 2 do
  (time/delta (list (lambda () (burn-cpu))) :runs 100))
