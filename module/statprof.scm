;;;; (statprof) -- a statistical profiler for Guile
;;;; -*-scheme-*-
;;;;
;;;; 	Copyright (C) 2009, 2010, 2011, 2013, 2014  Free Software Foundation, Inc.
;;;;    Copyright (C) 2004, 2009 Andy Wingo <wingo at pobox dot com>
;;;;    Copyright (C) 2001 Rob Browning <rlb at defaultvalue dot org>
;;;; 
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;; 
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
;;;; 


;;; Commentary:
;;;
;;; @code{(statprof)} is a statistical profiler for Guile.
;;;
;;; A simple use of statprof would look like this:
;;;
;;; @example
;;;   (statprof (lambda () (do-something))
;;;             #:hz 100
;;;             #:count-calls? #t)
;;; @end example
;;;
;;; This would run the thunk with statistical profiling, finally
;;; displaying a gprof flat-style table of statistics which could
;;; something like this:
;;;
;;; @example
;;;   %   cumulative      self              self    total
;;;  time    seconds   seconds    calls  ms/call  ms/call  name
;;;  35.29      0.23      0.23     2002     0.11     0.11  -
;;;  23.53      0.15      0.15     2001     0.08     0.08  positive?
;;;  23.53      0.15      0.15     2000     0.08     0.08  +
;;;  11.76      0.23      0.08     2000     0.04     0.11  do-nothing
;;;   5.88      0.64      0.04     2001     0.02     0.32  loop
;;;   0.00      0.15      0.00        1     0.00   150.59  do-something
;;;  ...
;;; @end example
;;;
;;; All of the numerical data with the exception of the calls column is
;;; statistically approximate. In the following column descriptions, and
;;; in all of statprof, "time" refers to execution time (both user and
;;; system), not wall clock time.
;;;
;;; @table @asis
;;; @item % time
;;; The percent of the time spent inside the procedure itself
;;; (not counting children).
;;; @item cumulative seconds
;;; The total number of seconds spent in the procedure, including
;;; children.
;;; @item self seconds
;;; The total number of seconds spent in the procedure itself (not counting
;;; children).
;;; @item calls
;;; The total number of times the procedure was called.
;;; @item self ms/call
;;; The average time taken by the procedure itself on each call, in ms.
;;; @item total ms/call
;;; The average time taken by each call to the procedure, including time
;;; spent in child functions.
;;; @item name
;;; The name of the procedure.
;;; @end table
;;;
;;; The profiler uses @code{eq?} and the procedure object itself to
;;; identify the procedures, so it won't confuse different procedures with
;;; the same name. They will show up as two different rows in the output.
;;;
;;; Right now the profiler is quite simplistic.  I cannot provide
;;; call-graphs or other higher level information.  What you see in the
;;; table is pretty much all there is. Patches are welcome :-)
;;;
;;; @section Implementation notes
;;;
;;; The profiler works by setting the unix profiling signal
;;; @code{ITIMER_PROF} to go off after the interval you define in the call
;;; to @code{statprof-reset}. When the signal fires, a sampling routine is
;;; run which looks at the current procedure that's executing, and then
;;; crawls up the stack, and for each procedure encountered, increments
;;; that procedure's sample count. Note that if a procedure is encountered
;;; multiple times on a given stack, it is only counted once. After the
;;; sampling is complete, the profiler resets profiling timer to fire
;;; again after the appropriate interval.
;;;
;;; Meanwhile, the profiler keeps track, via @code{get-internal-run-time},
;;; how much CPU time (system and user -- which is also what
;;; @code{ITIMER_PROF} tracks), has elapsed while code has been executing
;;; within a statprof-start/stop block.
;;;
;;; The profiler also tries to avoid counting or timing its own code as
;;; much as possible.
;;;
;;; Code:

(define-module (statprof)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:autoload   (ice-9 format) (format)
  #:use-module (system vm vm)
  #:use-module (system vm frame)
  #:use-module (system vm program)
  #:export (statprof-active?
            statprof-start
            statprof-stop
            statprof-reset

            statprof-accumulated-time
            statprof-sample-count
            statprof-fold-call-data
            statprof-proc-call-data
            statprof-call-data-name
            statprof-call-data-calls
            statprof-call-data-cum-samples
            statprof-call-data-self-samples
            statprof-call-data->stats
           
            statprof-stats-proc-name
            statprof-stats-%-time-in-proc
            statprof-stats-cum-secs-in-proc
            statprof-stats-self-secs-in-proc
            statprof-stats-calls
            statprof-stats-self-secs-per-call
            statprof-stats-cum-secs-per-call

            statprof-display
            statprof-display-anomalies
            statprof-display-anomolies ; Deprecated spelling.

            statprof-fetch-stacks
            statprof-fetch-call-tree

            statprof
            with-statprof

            gcprof))


;; This profiler tracks two numbers for every function called while
;; it's active.  It tracks the total number of calls, and the number
;; of times the function was active when the sampler fired.
;;
;; Globally the profiler tracks the total time elapsed and the number
;; of times the sampler was fired.
;;
;; Right now, this profiler is not per-thread and is not thread safe.

(define-record-type <state>
  (make-state accumulated-time last-start-time sample-count
              sampling-period remaining-prof-time profile-level
              count-calls? gc-time-taken record-full-stacks?
              stacks procedure-data inside-profiler?
              prev-sigprof-handler)
  state?
  ;; Total time so far.
  (accumulated-time accumulated-time set-accumulated-time!)
  ;; Start-time when timer is active.
  (last-start-time last-start-time set-last-start-time!)
  ;; Total count of sampler calls.
  (sample-count sample-count set-sample-count!)
  ;; Microseconds.
  (sampling-period sampling-period set-sampling-period!)
  ;; Time remaining when prof suspended.
  (remaining-prof-time remaining-prof-time set-remaining-prof-time!)
  ;; For user start/stop nesting.
  (profile-level profile-level set-profile-level!)
  ;; Whether to catch apply-frame.
  (count-calls? count-calls? set-count-calls?!)
  ;; GC time between statprof-start and statprof-stop.
  (gc-time-taken gc-time-taken set-gc-time-taken!)
  ;; If #t, stash away the stacks for future analysis.
  (record-full-stacks? record-full-stacks? set-record-full-stacks?!)
  ;; If record-full-stacks?, the stashed full stacks.
  (stacks stacks set-stacks!)
  ;; A hash where the key is the function object itself and the value is
  ;; the data. The data will be a vector like this:
  ;;   #(name call-count cum-sample-count self-sample-count)
  (procedure-data procedure-data set-procedure-data!)
  ;; True if we are inside the profiler.
  (inside-profiler? inside-profiler? set-inside-profiler?!)
  ;; True if we are inside the profiler.
  (prev-sigprof-handler prev-sigprof-handler set-prev-sigprof-handler!))

(define profiler-state (make-parameter #f))

(define* (fresh-profiler-state #:key (count-calls? #f)
                               (sampling-period 10000)
                               (full-stacks? #f))
  (make-state 0 #f 0 sampling-period 0 0 count-calls? 0 #f '()
              (make-hash-table) #f #f))

(define (ensure-profiler-state)
  (or (profiler-state)
      (let ((state (fresh-profiler-state)))
        (profiler-state state)
        state)))

(define (existing-profiler-state)
  (or (profiler-state)
      (error "expected there to be a profiler state")))

(define-record-type call-data
  (make-call-data proc call-count cum-sample-count self-sample-count)
  call-data?
  (proc call-data-proc)
  (call-count call-data-call-count set-call-data-call-count!)
  (cum-sample-count call-data-cum-sample-count set-call-data-cum-sample-count!)
  (self-sample-count call-data-self-sample-count set-call-data-self-sample-count!))

(define (call-data-name cd) (procedure-name (call-data-proc cd)))
(define (call-data-printable cd)
  (or (call-data-name cd)
      (with-output-to-string (lambda () (write (call-data-proc cd))))))

(define (inc-call-data-call-count! cd)
  (set-call-data-call-count! cd (1+ (call-data-call-count cd))))
(define (inc-call-data-cum-sample-count! cd)
  (set-call-data-cum-sample-count! cd (1+ (call-data-cum-sample-count cd))))
(define (inc-call-data-self-sample-count! cd)
  (set-call-data-self-sample-count! cd (1+ (call-data-self-sample-count cd))))

(define (accumulate-time state stop-time)
  (set-accumulated-time! state
                         (+ (accumulated-time state)
                            (- stop-time (last-start-time state)))))

(define (get-call-data state proc)
  (let ((k (cond
            ((program? proc) (program-code proc))
            (else proc))))
    (or (hashv-ref (procedure-data state) k)
        (let ((call-data (make-call-data proc 0 0 0)))
          (hashv-set! (procedure-data state) k call-data)
          call-data))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SIGPROF handler

;; FIXME: Instead of this messing about with hash tables and
;; frame-procedure, just record the stack of return addresses into a
;; growable vector, and resolve them to procedures when analyzing
;; instead of at collection time.
;;
(define (sample-stack-procs state stack)
  (let ((stacklen (stack-length stack))
        (hit-count-call? #f))

    (when (record-full-stacks? state)
      (set-stacks! state (cons stack (stacks state))))

    (set-sample-count! state (+ (sample-count state) 1))
    ;; Now accumulate stats for the whole stack.
    (let loop ((frame (stack-ref stack 0))
               (procs-seen (make-hash-table 13))
               (self #f))
      (cond
       ((not frame)
        (hash-fold
         (lambda (proc val accum)
           (inc-call-data-cum-sample-count!
            (get-call-data state proc)))
         #f
         procs-seen)
        (and=> (and=> self (lambda (proc)
                             (get-call-data state proc)))
               inc-call-data-self-sample-count!))
       ((frame-procedure frame)
        => (lambda (proc)
             (cond
              ((eq? proc count-call)
               ;; We're not supposed to be sampling count-call and
               ;; its sub-functions, so loop again with a clean
               ;; slate.
               (set! hit-count-call? #t)
               (loop (frame-previous frame) (make-hash-table 13) #f))
              (else
               (hashq-set! procs-seen proc #t)
               (loop (frame-previous frame)
                     procs-seen
                     (or self proc))))))
       (else
        (loop (frame-previous frame) procs-seen self))))
    hit-count-call?))

(define (reset-sigprof-timer usecs)
  ;; Guile's setitimer binding is terrible.
  (let ((prev (setitimer ITIMER_PROF 0 0 0 usecs)))
    (+ (* (caadr prev) #e1e6) (cdadr prev))))

(define (profile-signal-handler sig)
  (define state (existing-profiler-state))

  (set-inside-profiler?! state #t)

  ;; FIXME: with-statprof should be able to set an outer frame for the
  ;; stack cut
  (when (positive? (profile-level state))
    (let* ((stop-time (get-internal-run-time))
           ;; cut down to the signal handler. note that this will only
           ;; work if statprof.scm is compiled; otherwise we get
           ;; `eval' on the stack instead, because if it's not
           ;; compiled, profile-signal-handler is a thunk that
           ;; tail-calls eval. perhaps we should always compile the
           ;; signal handler instead...
           (stack (or (make-stack #t profile-signal-handler)
                      (pk 'what! (make-stack #t)))))

      (sample-stack-procs state stack)
      (accumulate-time state stop-time)
      (set-last-start-time! state (get-internal-run-time))

      (reset-sigprof-timer (sampling-period state))))
  
  (set-inside-profiler?! state #f))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Count total calls.

(define (count-call frame)
  (define state (existing-profiler-state))

  (unless (inside-profiler? state)
    (accumulate-time state (get-internal-run-time))

    (and=> (frame-procedure frame)
           (lambda (proc)
             (inc-call-data-call-count!
              (get-call-data state proc))))
        
    (set-last-start-time! state (get-internal-run-time))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (statprof-active?)
  "Returns @code{#t} if @code{statprof-start} has been called more times
than @code{statprof-stop}, @code{#f} otherwise."
  (define state (profiler-state))
  (and state (positive? (profile-level state))))

;; Do not call this from statprof internal functions -- user only.
(define* (statprof-start #:optional (state (ensure-profiler-state)))
  "Start the profiler.@code{}"
  ;; After some head-scratching, I don't *think* I need to mask/unmask
  ;; signals here, but if I'm wrong, please let me know.
  (set-profile-level! state (+ (profile-level state) 1))
  (when (= (profile-level state) 1)
    (let ((rpt (remaining-prof-time state)))
      (set-remaining-prof-time! state 0)
      ;; FIXME: Use per-thread run time.
      (set-last-start-time! state (get-internal-run-time))
      (set-gc-time-taken! state (assq-ref (gc-stats) 'gc-time-taken))
      (let ((prev (sigaction SIGPROF profile-signal-handler)))
        (set-prev-sigprof-handler! state (car prev)))
      (reset-sigprof-timer (if (zero? rpt) (sampling-period state) rpt))
      (when (count-calls? state)
        (add-hook! (vm-apply-hook) count-call))
      (set-vm-trace-level! (1+ (vm-trace-level)))
      #t)))
  
;; Do not call this from statprof internal functions -- user only.
(define* (statprof-stop #:optional (state (ensure-profiler-state)))
  "Stop the profiler.@code{}"
  ;; After some head-scratching, I don't *think* I need to mask/unmask
  ;; signals here, but if I'm wrong, please let me know.
  (set-profile-level! state (- (profile-level state) 1))
  (when (zero? (profile-level state))
    (set-gc-time-taken! state
                        (- (assq-ref (gc-stats) 'gc-time-taken)
                           (gc-time-taken state)))
    (set-vm-trace-level! (1- (vm-trace-level)))
    (when (count-calls? state)
      (remove-hook! (vm-apply-hook) count-call))
    ;; I believe that we need to do this before getting the time
    ;; (unless we want to make things even more complicated).
    (set-remaining-prof-time! state (reset-sigprof-timer 0))
    (accumulate-time state (get-internal-run-time))
    (sigaction SIGPROF (prev-sigprof-handler state))
    (set-prev-sigprof-handler! state #f)
    (set-last-start-time! state #f)))

(define* (statprof-reset sample-seconds sample-microseconds count-calls?
                         #:optional full-stacks?)
  "Reset the statprof sampler interval to @var{sample-seconds} and
@var{sample-microseconds}. If @var{count-calls?} is true, arrange to
instrument procedure calls as well as collecting statistical profiling
data. If @var{full-stacks?} is true, collect all sampled stacks into a
list for later analysis.

Enables traps and debugging as necessary."
  (when (statprof-active?)
    (error "Can't reset profiler while profiler is running."))
  (profiler-state
   (fresh-profiler-state #:count-calls? count-calls?
                         #:sampling-period (+ (* sample-seconds #e1e6)
                                              sample-microseconds)
                         #:full-stacks? full-stacks?))
  (values))

(define (statprof-fold-call-data proc init)
  "Fold @var{proc} over the call-data accumulated by statprof. Cannot be
called while statprof is active. @var{proc} should take two arguments,
@code{(@var{call-data} @var{prior-result})}.

Note that a given proc-name may appear multiple times, but if it does,
it represents different functions with the same name."
  (when (statprof-active?)
    (error "Can't call statprof-fold-call-data while profiler is running."))
  (hash-fold
   (lambda (key value prior-result)
     (proc value prior-result))
   init
   (procedure-data (existing-profiler-state))))

(define (statprof-proc-call-data proc)
  "Returns the call-data associated with @var{proc}, or @code{#f} if
none is available."
  (when (statprof-active?)
    (error "Can't call statprof-proc-call-data while profiler is running."))
  (get-call-data (existing-profiler-state) proc))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Stats

(define (statprof-call-data->stats call-data)
  "Returns an object of type @code{statprof-stats}."
  ;; returns (vector proc-name
  ;;                 %-time-in-proc
  ;;                 cum-seconds-in-proc
  ;;                 self-seconds-in-proc
  ;;                 num-calls
  ;;                 self-secs-per-call
  ;;                 total-secs-per-call)

  (define state (existing-profiler-state))

  (let* ((proc-name (call-data-printable call-data))
         (self-samples (call-data-self-sample-count call-data))
         (cum-samples (call-data-cum-sample-count call-data))
         (all-samples (statprof-sample-count))
         (secs-per-sample (/ (statprof-accumulated-time)
                             (statprof-sample-count)))
         (num-calls (and (count-calls? state) (statprof-call-data-calls call-data))))

    (vector proc-name
            (* (/ self-samples all-samples) 100.0)
            (* cum-samples secs-per-sample 1.0)
            (* self-samples secs-per-sample 1.0)
            num-calls
            (and num-calls ;; maybe we only sampled in children
                 (if (zero? self-samples) 0.0
                     (/ (* self-samples secs-per-sample) 1.0 num-calls)))
            (and num-calls ;; cum-samples must be positive
                 (/ (* cum-samples secs-per-sample)
                    1.0
                    ;; num-calls might be 0 if we entered statprof during the
                    ;; dynamic extent of the call
                    (max num-calls 1))))))

(define (statprof-stats-proc-name stats) (vector-ref stats 0))
(define (statprof-stats-%-time-in-proc stats) (vector-ref stats 1))
(define (statprof-stats-cum-secs-in-proc stats) (vector-ref stats 2))
(define (statprof-stats-self-secs-in-proc stats) (vector-ref stats 3))
(define (statprof-stats-calls stats) (vector-ref stats 4))
(define (statprof-stats-self-secs-per-call stats) (vector-ref stats 5))
(define (statprof-stats-cum-secs-per-call stats) (vector-ref stats 6))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (stats-sorter x y)
  (let ((diff (- (statprof-stats-self-secs-in-proc x)
                 (statprof-stats-self-secs-in-proc y))))
    (positive?
     (if (= diff 0)
         (- (statprof-stats-cum-secs-in-proc x)
            (statprof-stats-cum-secs-in-proc y))
         diff))))

(define* (statprof-display #:optional (port (current-output-port))
                           (state (existing-profiler-state)))
  "Displays a gprof-like summary of the statistics collected. Unless an
optional @var{port} argument is passed, uses the current output port."
  (cond
   ((zero? (statprof-sample-count))
    (format port "No samples recorded.\n"))
   (else
    (let* ((stats-list (statprof-fold-call-data
                        (lambda (data prior-value)
                          (cons (statprof-call-data->stats data)
                                prior-value))
                        '()))
           (sorted-stats (sort stats-list stats-sorter)))

      (define (display-stats-line stats)
        (if (count-calls? state)
            (format  port "~6,2f ~9,2f ~9,2f ~7d ~8,2f ~8,2f  "
                     (statprof-stats-%-time-in-proc stats)
                     (statprof-stats-cum-secs-in-proc stats)
                     (statprof-stats-self-secs-in-proc stats)
                     (statprof-stats-calls stats)
                     (* 1000 (statprof-stats-self-secs-per-call stats))
                     (* 1000 (statprof-stats-cum-secs-per-call stats)))
            (format  port "~6,2f ~9,2f ~9,2f  "
                     (statprof-stats-%-time-in-proc stats)
                     (statprof-stats-cum-secs-in-proc stats)
                     (statprof-stats-self-secs-in-proc stats)))
        (display (statprof-stats-proc-name stats) port)
        (newline port))
    
      (if (count-calls? state)
          (begin
            (format  port "~5a ~10a   ~7a ~8a ~8a ~8a  ~8@a\n"
                     "%  " "cumulative" "self" "" "self" "total" "")
            (format  port "~5a  ~9a  ~8a ~8a ~8a ~8a  ~8@a\n"
                     "time" "seconds" "seconds" "calls" "ms/call" "ms/call" "name"))
          (begin
            (format  port "~5a ~10a   ~7a  ~8@a\n"
                     "%" "cumulative" "self" "")
            (format  port "~5a  ~10a  ~7a  ~8@a\n"
                     "time" "seconds" "seconds" "name")))

      (for-each display-stats-line sorted-stats)

      (display "---\n" port)
      (simple-format #t "Sample count: ~A\n" (statprof-sample-count))
      (simple-format #t "Total time: ~A seconds (~A seconds in GC)\n"
                     (statprof-accumulated-time)
                     (/ (gc-time-taken state)
                        1.0 internal-time-units-per-second))))))

(define* (statprof-display-anomalies #:optional (state
                                                 (existing-profiler-state)))
  "A sanity check that attempts to detect anomalies in statprof's
statistics.@code{}"
  (statprof-fold-call-data
   (lambda (data prior-value)
     (when (and (count-calls? state)
                (zero? (call-data-call-count data))
                (positive? (call-data-cum-sample-count data)))
       (simple-format #t
                      "==[~A ~A ~A]\n"
                      (call-data-name data)
                      (call-data-call-count data)
                      (call-data-cum-sample-count data))))
   #f)
  (simple-format #t "Total time: ~A\n" (statprof-accumulated-time))
  (simple-format #t "Sample count: ~A\n" (statprof-sample-count)))

(define (statprof-display-anomolies)
  (issue-deprecation-warning "statprof-display-anomolies is a misspelling. "
                             "Use statprof-display-anomalies instead.")
  (statprof-display-anomalies))

(define* (statprof-accumulated-time #:optional (state
                                                (existing-profiler-state)))
  "Returns the time accumulated during the last statprof run.@code{}"
  (/ (accumulated-time state) 1.0 internal-time-units-per-second))

(define* (statprof-sample-count #:optional (state (existing-profiler-state)))
  "Returns the number of samples taken during the last statprof run.@code{}"
  (sample-count state))

(define statprof-call-data-name call-data-name)
(define statprof-call-data-calls call-data-call-count)
(define statprof-call-data-cum-samples call-data-cum-sample-count)
(define statprof-call-data-self-samples call-data-self-sample-count)

(define* (statprof-fetch-stacks #:optional (state (existing-profiler-state)))
  "Returns a list of stacks, as they were captured since the last call
to @code{statprof-reset}.

Note that stacks are only collected if the @var{full-stacks?} argument
to @code{statprof-reset} is true."
  (stacks state))

(define procedure=?
  (lambda (a b)
    (cond
     ((eq? a b))
     ((and (program? a) (program? b))
      (eq? (program-code a) (program-code b)))
     (else
      #f))))

;; tree ::= (car n . tree*)

(define (lists->trees lists equal?)
  (let lp ((in lists) (n-terminal 0) (tails '()))
    (cond
     ((null? in)
      (let ((trees (map (lambda (tail)
                          (cons (car tail)
                                (lists->trees (cdr tail) equal?)))
                        tails)))
        (cons (apply + n-terminal (map cadr trees))
              (sort trees
                    (lambda (a b) (> (cadr a) (cadr b)))))))
     ((null? (car in))
      (lp (cdr in) (1+ n-terminal) tails))
     ((find (lambda (x) (equal? (car x) (caar in)))
            tails)
      => (lambda (tail)
           (lp (cdr in)
               n-terminal
               (assq-set! tails
                          (car tail)
                          (cons (cdar in) (cdr tail))))))
     (else
      (lp (cdr in)
          n-terminal
          (acons (caar in) (list (cdar in)) tails))))))

(define (stack->procedures stack)
  (filter identity
          (unfold-right (lambda (x) (not x))
                        frame-procedure
                        frame-previous
                        (stack-ref stack 0))))

(define* (statprof-fetch-call-tree #:optional (state (existing-profiler-state)))
  "Return a call tree for the previous statprof run.

The return value is a list of nodes, each of which is of the type:
@code
 node ::= (@var{proc} @var{count} . @var{nodes})
@end code"
  (cons #t (lists->trees (map stack->procedures (stacks state)) procedure=?)))

(define* (statprof thunk #:key (loop 1) (hz 100) (count-calls? #f)
                   (full-stacks? #f) (port (current-output-port)))
  "Profiles the execution of @var{thunk}.

The stack will be sampled @var{hz} times per second, and the thunk itself will
be called @var{loop} times.

If @var{count-calls?} is true, all procedure calls will be recorded. This
operation is somewhat expensive.

If @var{full-stacks?} is true, at each sample, statprof will store away the
whole call tree, for later analysis. Use @code{statprof-fetch-stacks} or
@code{statprof-fetch-call-tree} to retrieve the last-stored stacks."
  
  (let ((state (fresh-profiler-state #:count-calls? count-calls?
                                     #:sampling-period
                                     (inexact->exact (round (/ 1e6 hz)))
                                     #:full-stacks? full-stacks?)))
    (parameterize ((profiler-state state))
      (dynamic-wind
        (lambda ()
          (statprof-start state))
        (lambda ()
          (let lp ((i loop))
            (unless (zero? i)
              (thunk)
              (lp (1- i)))))
        (lambda ()
          (statprof-stop state)
          (statprof-display port state))))))

(define-macro (with-statprof . args)
  "Profiles the expressions in its body.

Keyword arguments:

@table @code
@item #:loop
Execute the body @var{loop} number of times, or @code{#f} for no looping

default: @code{#f}
@item #:hz
Sampling rate

default: @code{20}
@item #:count-calls?
Whether to instrument each function call (expensive)

default: @code{#f}
@item #:full-stacks?
Whether to collect away all sampled stacks into a list

default: @code{#f}
@end table"
  (define (kw-arg-ref kw args def)
    (cond
     ((null? args) (error "Invalid macro body"))
     ((keyword? (car args))
      (if (eq? (car args) kw)
          (cadr args)
          (kw-arg-ref kw (cddr args) def)))
     ((eq? kw #f def) ;; asking for the body
      args)
     (else def))) ;; kw not found
  `((@ (statprof) statprof)
    (lambda () ,@(kw-arg-ref #f args #f))
    #:loop ,(kw-arg-ref #:loop args 1)
    #:hz ,(kw-arg-ref #:hz args 100)
    #:count-calls? ,(kw-arg-ref #:count-calls? args #f)
    #:full-stacks? ,(kw-arg-ref #:full-stacks? args #f)))

(define* (gcprof thunk #:key (loop 1) (full-stacks? #f))
  "Do an allocation profile of the execution of @var{thunk}.

The stack will be sampled soon after every garbage collection, yielding
an approximate idea of what is causing allocation in your program.

Since GC does not occur very frequently, you may need to use the
@var{loop} parameter, to cause @var{thunk} to be called @var{loop}
times.

If @var{full-stacks?} is true, at each sample, statprof will store away the
whole call tree, for later analysis. Use @code{statprof-fetch-stacks} or
@code{statprof-fetch-call-tree} to retrieve the last-stored stacks."
  
  (let ((state (fresh-profiler-state #:full-stacks? full-stacks?)))
    (parameterize ((profiler-state state))
      (define (gc-callback)
        (unless (inside-profiler? state)
          (set-inside-profiler?! state #t)

          ;; FIXME: should be able to set an outer frame for the stack cut
          (let ((stop-time (get-internal-run-time))
                ;; Cut down to gc-callback, and then one before (the
                ;; after-gc async).  See the note in profile-signal-handler
                ;; also.
                (stack (or (make-stack #t gc-callback 0 1)
                           (pk 'what! (make-stack #t)))))
            (sample-stack-procs state stack)
            (accumulate-time state stop-time)
            (set-last-start-time! state (get-internal-run-time)))
      
          (set-inside-profiler?! state #f)))

      (dynamic-wind
        (lambda ()
          (set-profile-level! state 1)
          (set-last-start-time! state (get-internal-run-time))
          (set-gc-time-taken! state (assq-ref (gc-stats) 'gc-time-taken))
          (add-hook! after-gc-hook gc-callback))
        (lambda ()
          (let lp ((i loop))
            (unless (zero? i)
              (thunk)
              (lp (1- i)))))
        (lambda ()
          (remove-hook! after-gc-hook gc-callback)
          (set-gc-time-taken! state
                              (- (assq-ref (gc-stats) 'gc-time-taken)
                                 (gc-time-taken state)))
          (accumulate-time state (get-internal-run-time))
          (set-profile-level! state 0)
          (statprof-display))))))
