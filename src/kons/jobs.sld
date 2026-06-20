(define-library (kons jobs)
  (export make-job
          job?
          job-id
          job-kind
          job-label
          job-deps
          job-metadata
          job-resources
          job-parallel-safe?
          job-run
          make-job-graph
          job-graph?
          job-graph-jobs
          job-graph-roots
          make-job-result
          job-result?
          job-result-id
          job-result-status
          job-result-value
          job-result-metadata
          make-job-runner-options
          job-runner-options?
          job-runner-options-jobs
          job-runner-options-dry-run?
          job-runner-options-fail-fast?
          job-runner-options-log-lock
          job-runner-options-event-handler
          validate-job-graph
          job-graph-batches
          run-job-graph!
          job-graph->plan-form)
  (import (scheme base)
          (kons compat threads)
          (kons util))

  (begin
    (define-record-type <job>
      (%make-job id kind label deps metadata resources parallel-safe? run)
      job?
      (id job-id)
      (kind job-kind)
      (label job-label)
      (deps job-deps)
      (metadata job-metadata)
      (resources job-resources)
      (parallel-safe? job-parallel-safe?)
      (run job-run))

    (define-record-type <job-graph>
      (%make-job-graph jobs roots)
      job-graph?
      (jobs job-graph-jobs)
      (roots job-graph-roots))

    (define-record-type <job-result>
      (make-job-result id status value metadata)
      job-result?
      (id job-result-id)
      (status job-result-status)
      (value job-result-value)
      (metadata job-result-metadata))

    (define-record-type <job-runner-options>
      (%make-job-runner-options jobs dry-run? fail-fast? log-lock event-handler)
      job-runner-options?
      (jobs job-runner-options-jobs)
      (dry-run? job-runner-options-dry-run?)
      (fail-fast? job-runner-options-fail-fast?)
      (log-lock job-runner-options-log-lock)
      (event-handler job-runner-options-event-handler))

    (define (make-job id kind label deps metadata resources parallel-safe? run)
      (%make-job id kind label deps metadata resources parallel-safe? run))

    (define (make-job-graph jobs roots)
      (%make-job-graph jobs roots))

    (define (default-job-event-handler event)
      #f)

    (define (make-job-runner-options jobs dry-run? fail-fast? log-lock . maybe-event-handler)
      (%make-job-runner-options
       jobs
       dry-run?
       fail-fast?
       log-lock
       (if (null? maybe-event-handler)
           default-job-event-handler
           (car maybe-event-handler))))

    (define (member-equal? x xs)
      (let loop ((items xs))
        (cond
         ((null? items) #f)
         ((equal? x (car items)) #t)
         (else (loop (cdr items))))))

    (define (find-job id jobs)
      (let loop ((items jobs))
        (cond
         ((null? items) #f)
         ((equal? id (job-id (car items))) (car items))
         (else (loop (cdr items))))))

    (define (ensure-unique-job-ids jobs)
      (let loop ((items jobs) (seen '()))
        (cond
         ((null? items) #t)
         ((member-equal? (job-id (car items)) seen)
          (internal-error "duplicate job id" (job-id (car items))))
         (else
          (loop (cdr items) (cons (job-id (car items)) seen))))))

    (define (ensure-known-deps jobs)
      (for-each
       (lambda (job)
         (for-each
          (lambda (dep)
            (unless (find-job dep jobs)
              (internal-error "job dependency not found" (job-id job) dep)))
          (job-deps job)))
       jobs))

    (define (visit-job job jobs visiting visited)
      (let ((id (job-id job)))
        (cond
         ((member-equal? id visited) visited)
         ((member-equal? id visiting)
          (internal-error "job graph contains a cycle" id))
         (else
          (let loop ((deps (job-deps job)) (visited visited))
            (if (null? deps)
                (cons id visited)
                (loop (cdr deps)
                      (visit-job (find-job (car deps) jobs)
                                 jobs
                                 (cons id visiting)
                                 visited))))))))

    (define (ensure-acyclic jobs)
      (let loop ((items jobs) (visited '()))
        (if (null? items)
            #t
            (loop (cdr items)
                  (visit-job (car items) jobs '() visited)))))

    (define (validate-job-graph graph)
      (let ((jobs (job-graph-jobs graph)))
        (ensure-unique-job-ids jobs)
        (ensure-known-deps jobs)
        (ensure-acyclic jobs)
        graph))

    (define (deps-complete? job complete)
      (let loop ((deps (job-deps job)))
        (cond
         ((null? deps) #t)
         ((member-equal? (car deps) complete) (loop (cdr deps)))
         (else #f))))

    (define (remove-ready jobs ready)
      (filter (lambda (job) (not (member-equal? (job-id job) ready))) jobs))

    (define (job-graph-batches graph)
      (validate-job-graph graph)
      (let loop ((remaining (job-graph-jobs graph))
                 (complete '())
                 (batches '()))
        (if (null? remaining)
            (reverse batches)
            (let ((ready (filter (lambda (job)
                                   (deps-complete? job complete))
                                 remaining)))
              (when (null? ready)
                (internal-error "job graph has no ready jobs"))
              (loop (remove-ready remaining (map job-id ready))
                    (append (reverse (map job-id ready)) complete)
                    (cons ready batches))))))

    (define (resources-conflict? a b)
      (let loop ((items (job-resources a)))
        (cond
         ((null? items) #f)
         ((member-equal? (car items) (job-resources b)) #t)
         (else (loop (cdr items))))))

    (define (conflicts-with-any? job jobs)
      (let loop ((items jobs))
        (cond
         ((null? items) #f)
         ((resources-conflict? job (car items)) #t)
         (else (loop (cdr items))))))

    (define (take-runnable batch limit)
      (let loop ((items batch) (selected '()) (rest '()) (count 0))
        (cond
         ((null? items) `(,(reverse selected) ,(reverse rest)))
         ((or (>= count limit)
              (not (job-parallel-safe? (car items)))
              (conflicts-with-any? (car items) selected))
          (loop (cdr items) selected (cons (car items) rest) count))
         (else
          (loop (cdr items) (cons (car items) selected) rest (+ count 1))))))

    (define (job-event status job value)
      `(job
        (id ,(job-id job))
        (kind ,(job-kind job))
        (label ,(job-label job))
        (status ,status)
        (value ,value)
        (metadata ,(job-metadata job))))

    (define (run-one-job job dry-run? emit)
      (if dry-run?
          (let ((result (make-job-result (job-id job) 'planned #f (job-metadata job))))
            (emit (job-event 'planned job #f))
            result)
          (begin
            (emit (job-event 'started job #f))
            (guard (ex
                    (else
                     (let ((result (make-job-result (job-id job) 'failed ex (job-metadata job))))
                       (emit (job-event 'failed job ex))
                       result)))
              (let* ((value ((job-run job)))
                     (result (make-job-result (job-id job) 'done value (job-metadata job))))
                (emit (job-event 'done job value))
                result)))))

    (define (failed-result results)
      (let loop ((items results))
        (cond
         ((null? items) #f)
         ((eq? (job-result-status (car items)) 'failed) (car items))
         (else (loop (cdr items))))))

    (define (raise-failed-results! results fail-fast?)
      (let ((failed (and fail-fast? (failed-result results))))
        (when failed
          (raise (job-result-value failed)))))

    (define (run-job-chunk jobs dry-run? workers event-handler fail-fast?)
      (if (or dry-run? (= workers 1) (not (job-threads-available?)))
          (let ((results (map (lambda (job)
                                (run-one-job job dry-run? event-handler))
                              jobs)))
            (raise-failed-results! results fail-fast?)
            results)
          (let* ((channel (make-channel))
                 (total (length jobs))
                 (threads (map (lambda (job)
                                 (spawn-thread
                                  (lambda ()
                                    (channel-send!
                                     channel
                                     `(result ,(run-one-job
                                                job
                                                dry-run?
                                                (lambda (event)
                                                  (channel-send! channel `(event ,event)))))))))
                               jobs)))
            (let loop ((remaining total) (results '()))
              (if (= remaining 0)
                  (begin
                    (for-each join-thread threads)
                    (channel-close! channel)
                    (raise-failed-results! (reverse results) fail-fast?)
                    (reverse results))
                  (let ((message (channel-receive! channel)))
                    (cond
                     ((not message) (loop remaining results))
                     ((eq? (car message) 'event)
                      (event-handler (cadr message))
                      (loop remaining results))
                     ((eq? (car message) 'result)
                      (loop (- remaining 1) (cons (cadr message) results)))
                     (else (loop remaining results)))))))))

    (define (normalize-worker-count raw)
      (if (and (integer? raw) (> raw 0)) raw 1))

    (define (run-batch batch dry-run? workers out event-handler fail-fast?)
      (let loop ((remaining batch) (out out))
        (if (null? remaining)
            out
            (let* ((picked (take-runnable remaining workers))
                   (chunk (car picked))
                   (rest (cadr picked)))
              (if (null? chunk)
                  (let ((job (car remaining)))
                    (let ((result (run-one-job job dry-run? event-handler)))
                      (raise-failed-results! (list result) fail-fast?)
                      (loop (cdr remaining)
                            (append out (list result)))))
                  (loop rest
                        (append out
                                (run-job-chunk
                                 chunk
                                 dry-run?
                                 workers
                                 event-handler
                                 fail-fast?))))))))

    (define (run-job-graph! graph options)
      (let ((workers (normalize-worker-count (job-runner-options-jobs options)))
            (dry-run? (job-runner-options-dry-run? options))
            (fail-fast? (job-runner-options-fail-fast? options))
            (event-handler (job-runner-options-event-handler options)))
        (let loop ((batches (job-graph-batches graph)) (out '()))
          (if (null? batches)
              out
              (loop (cdr batches)
                    (run-batch
                     (car batches)
                     dry-run?
                     workers
                     out
                     event-handler
                     fail-fast?))))))

    (define (job->plan-form job)
      `(job
        (id ,(job-id job))
        (kind ,(job-kind job))
        (label ,(job-label job))
        (deps ,@(job-deps job))
        (resources ,@(job-resources job))
        (parallel-safe ,(job-parallel-safe? job))
        (metadata ,@(job-metadata job))))

    (define (job-graph->plan-form graph)
      `(job-graph
        (roots ,@(job-graph-roots graph))
        (jobs ,@(map job->plan-form (job-graph-jobs graph)))))))
