(import (scheme base)
        (scheme process-context)
        (scheme write)
        (srfi 64)
        (kons compat threads)
        (kons jobs))

(test-begin "kons jobs")

(define (check-equal name got expected)
  (test-equal name expected got))

(define (job-result->list result)
  (list (job-result-id result)
        (job-result-status result)
        (job-result-value result)))

(define (member-equal? value items)
  (cond
   ((null? items) #f)
   ((equal? value (car items)) #t)
   (else (member-equal? value (cdr items)))))

(define (count-status status events)
  (let loop ((items events) (count 0))
    (cond
     ((null? items) count)
     ((let ((field (assq 'status (cdr (car items)))))
        (and field (eq? (cadr field) status)))
      (loop (cdr items) (+ count 1)))
     (else (loop (cdr items) count)))))

(let ((channel (make-channel)))
  (channel-send! channel 'first)
  (channel-send! channel 'second)
  (check-equal "channel receive first" (channel-receive! channel) 'first)
  (check-equal "channel drain rest" (channel-drain! channel) '(second)))

(let* ((channel (make-channel))
       (thread (spawn-thread (lambda () (channel-send! channel 'from-thread)))))
  (check-equal "channel receive from thread" (channel-receive! channel) 'from-thread)
  (join-thread thread))

(define graph
  (make-job-graph
   (list
    (make-job 'a 'test "a" '() '() '() #t (lambda () 'a-ok))
    (make-job 'b 'test "b" '() '() '() #t (lambda () 'b-ok))
    (make-job 'c 'test "c" '(a b) '() '() #t (lambda () 'c-ok)))
   '(c)))

(check-equal
 "job graph batches"
 (map (lambda (batch) (map job-id batch)) (job-graph-batches graph))
 '((a b) (c)))

(check-equal
 "job graph execution"
 (map job-result->list
      (run-job-graph! graph (make-job-runner-options 1 #f #t #f)))
 '((a done a-ok) (b done b-ok) (c done c-ok)))

(let ((events '()))
  (run-job-graph!
   graph
   (make-job-runner-options
    2
    #f
    #t
    #f
    (lambda (event)
      (set! events (cons event events)))))
  (check-equal "parallel job started events" (count-status 'started events) 3)
  (check-equal "parallel job done events" (count-status 'done events) 3)
  (check-equal "parallel job saw c"
               (member-equal? 'c
                              (map (lambda (event)
                                     (cadr (assq 'id (cdr event))))
                                   events))
               #t))

(check-equal
 "job graph dry run"
 (map job-result->list
      (run-job-graph! graph (make-job-runner-options 2 #t #t #f)))
 '((a planned #f) (b planned #f) (c planned #f)))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons jobs")
  (exit (if (= failures 0) 0 1)))
