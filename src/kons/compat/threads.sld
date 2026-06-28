(define-library (kons compat threads)
  (export threads-available?
    job-threads-available?
    default-worker-count
    spawn-thread
    join-thread
    make-lock
    call-with-lock
    with-lock
    make-condvar
    condvar-wait!
    condvar-signal!
    condvar-broadcast!
    make-channel
    channel?
    channel-send!
    channel-receive!
    channel-drain!
    channel-close!)
  (cond-expand
    (capy
      (import (scheme base)
        (rename (core threading)
          (call-with-new-thread capy-call-with-new-thread)
          (join-thread capy-join-thread)
          (make-mutex capy-make-mutex)
          (with-mutex capy-with-mutex)
          (make-condition capy-make-condition)
          (condition-wait capy-condition-wait)
          (condition-signal capy-condition-signal)
          (condition-broadcast capy-condition-broadcast))))
    (guile
      (import (scheme base)
        (rename (ice-9 threads)
          (call-with-new-thread guile-call-with-new-thread)
          (join-thread guile-join-thread)
          (make-mutex guile-make-mutex)
          (with-mutex guile-with-mutex)
          (current-processor-count guile-current-processor-count)
          (make-condition-variable guile-make-condition-variable)
          (wait-condition-variable guile-wait-condition-variable)
          (signal-condition-variable guile-signal-condition-variable)
          (broadcast-condition-variable guile-broadcast-condition-variable))))
    (gauche
      (import (scheme base)
        (rename (gauche threads)
          (make-thread gauche-make-thread)
          (thread-start! gauche-thread-start!)
          (thread-join! gauche-thread-join!)
          (make-mutex gauche-make-mutex)
          (mutex-lock! gauche-mutex-lock!)
          (mutex-unlock! gauche-mutex-unlock!)
          (with-locking-mutex gauche-with-locking-mutex)
          (gauche-thread-type gauche-thread-type)
          (make-condition-variable gauche-make-condition-variable)
          (condition-variable-signal! gauche-condition-variable-signal!)
          (condition-variable-broadcast! gauche-condition-variable-broadcast!))))
    (else
      (import (scheme base))))

  (begin
    (define-record-type <channel>
      (%make-channel lock condition queue closed?)
      channel?
      (lock channel-lock)
      (condition channel-condition)
      (queue channel-queue set-channel-queue!)
      (closed? channel-closed? set-channel-closed?!))

    (define (positive-integer-or default value)
      (if (and (integer? value) (> value 0)) value default))

    (define (threads-available?)
      (cond-expand
        (capy #t)
        (guile #t)
        (gauche (if (gauche-thread-type) #t #f))
        (else #f)))

    (define (job-threads-available?)
      (cond-expand
        (else (threads-available?))))

    (define (default-worker-count)
      (cond-expand
        (guile (positive-integer-or 1 (guile-current-processor-count)))
        (else 1)))

    (define (spawn-thread thunk)
      (cond-expand
        (capy (capy-call-with-new-thread thunk))
        (guile (guile-call-with-new-thread thunk))
        (gauche (gauche-thread-start! (gauche-make-thread thunk)))
        (else thunk)))

    (define (join-thread thread)
      (cond-expand
        (capy (capy-join-thread thread))
        (guile (guile-join-thread thread))
        (gauche (gauche-thread-join! thread))
        (else (thread))))

    (define (make-lock)
      (cond-expand
        (capy (capy-make-mutex))
        (guile (guile-make-mutex))
        (gauche (gauche-make-mutex))
        (else #f)))

    (define (call-with-lock lock thunk)
      (cond-expand
        (capy (capy-with-mutex lock (thunk)))
        (guile (guile-with-mutex lock (thunk)))
        (gauche (gauche-with-locking-mutex lock thunk))
        (else (thunk))))

    (define-syntax with-lock
      (syntax-rules ()
        ((_ lock body ...)
          (call-with-lock lock (lambda () body ...)))))

    (define (make-condvar)
      (cond-expand
        (capy (capy-make-condition))
        (guile (guile-make-condition-variable))
        (gauche (gauche-make-condition-variable))
        (else #f)))

    (define (condvar-wait! condition lock)
      (cond-expand
        (capy (capy-condition-wait condition lock))
        (guile (guile-wait-condition-variable condition lock))
        (gauche
          (begin
            (gauche-mutex-unlock! lock condition)
            (gauche-mutex-lock! lock)))
        (else #f)))

    (define (condvar-signal! condition)
      (cond-expand
        (capy (capy-condition-signal condition))
        (guile (guile-signal-condition-variable condition))
        (gauche (gauche-condition-variable-signal! condition))
        (else #f)))

    (define (condvar-broadcast! condition)
      (cond-expand
        (capy (capy-condition-broadcast condition))
        (guile (guile-broadcast-condition-variable condition))
        (gauche (gauche-condition-variable-broadcast! condition))
        (else #f)))

    (define (make-channel)
      (%make-channel (make-lock) (make-condvar) '() #f))

    (define (channel-send! channel value)
      (call-with-lock
        (channel-lock channel)
        (lambda ()
          (unless (channel-closed? channel)
            (set-channel-queue! channel (append (channel-queue channel) (list value)))
            (condvar-signal! (channel-condition channel))))))

    (define (channel-receive! channel)
      (call-with-lock
        (channel-lock channel)
        (lambda ()
          (let loop ()
            (cond
              ((pair? (channel-queue channel))
                (let ((value (car (channel-queue channel))))
                  (set-channel-queue! channel (cdr (channel-queue channel)))
                  value))
              ((channel-closed? channel) #f)
              ((threads-available?)
                (condvar-wait! (channel-condition channel) (channel-lock channel))
                (loop))
              (else #f))))))

    (define (channel-drain! channel)
      (call-with-lock
        (channel-lock channel)
        (lambda ()
          (let ((events (channel-queue channel)))
            (set-channel-queue! channel '())
            events))))

    (define (channel-close! channel)
      (call-with-lock
        (channel-lock channel)
        (lambda ()
          (set-channel-closed?! channel #t)
          (condvar-broadcast! (channel-condition channel)))))))
