(define-library (kons ui)
  (export set-ui-enabled!
    ui-enabled?
    ui-colorize
    ui-symbol
    ui-status
    ui-status-done
    ui-status-fail
    ui-progress
    ui-display-status
    ui-clear-active-line
    ui-fresh-line)
  (import (scheme base)
    (scheme process-context)
    (scheme write))

  (begin
    (define current-ui-enabled
      (not (or (get-environment-variable "NO_COLOR")
            (get-environment-variable "KONS_NO_COLOR"))))

    (define current-ui-line-active #f)

    (define (set-ui-enabled! enabled?)
      (set! current-ui-enabled enabled?))

    (define (ui-enabled?)
      current-ui-enabled)

    (define (ansi code)
      (string-append (string (integer->char 27)) "[" code "m"))

    (define (ui-clear-line)
      (display (string #\return) (current-error-port))
      (display (string-append (string (integer->char 27)) "[K") (current-error-port)))

    (define (ui-fresh-line)
      (when (and (ui-enabled?) current-ui-line-active)
        (newline (current-error-port))
        (set! current-ui-line-active #f)))

    (define (ui-clear-active-line)
      (when (and (ui-enabled?) current-ui-line-active)
        (ui-clear-line)
        (set! current-ui-line-active #f)))

    (define (ui-color-code color)
      (case color
        ((red) "31")
        ((green) "32")
        ((yellow) "33")
        ((blue) "34")
        ((magenta) "35")
        ((cyan) "36")
        ((dim) "2")
        ((bold) "1")
        (else "0")))

    (define (ui-colorize color text)
      (if (ui-enabled?)
        (string-append (ansi (ui-color-code color)) text (ansi "0"))
        text))

    (define (ui-symbol kind)
      (case kind
        ((work) "")
        ((done) "")
        ((fail) "")
        ((bar) "#")
        ((empty) "-")
        (else "")))

    (define (status-verb label final? failed?)
      (cond
        (failed? "Error")
        ((and (>= (string-length label) 7)
            (string=? (substring label 0 7) "running"))
          "Running")
        ((and (>= (string-length label) 8)
            (string=? (substring label 0 8) "checking"))
          (if final? "Checked" "Checking"))
        ((and (>= (string-length label) 7)
            (string=? (substring label 0 7) "writing"))
          (if final? "Wrote" "Writing"))
        ((and (>= (string-length label) 7)
            (string=? (substring label 0 7) "copying"))
          (if final? "Copied" "Copying"))
        ((and (>= (string-length label) 8)
            (string=? (substring label 0 8) "creating"))
          (if final? "Created" "Creating"))
        ((and (>= (string-length label) 9)
            (string=? (substring label 0 9) "preparing"))
          (if final? "Prepared" "Preparing"))
        ((and final?
            (>= (string-length label) 8)
            (string=? (substring label 0 8) "compiled"))
          "Compiled")
        (final? "Finished")
        (else "Working")))

    (define (status-message label message)
      (cond
        (message (string-append label " " message))
        (else label)))

    (define (ui-write-line symbol color label message final?)
      (ui-clear-line)
      (let ((verb (status-verb label final? (string=? symbol "!"))))
        (display-padding (max 1 (- 12 (string-length verb))))
        (display (ui-colorize color verb) (current-error-port))
        (display " " (current-error-port))
        (display (status-message label message) (current-error-port)))
      (if final?
        (begin
          (newline (current-error-port))
          (set! current-ui-line-active #f))
        (set! current-ui-line-active #t)))

    (define (ui-status label . maybe-message)
      (when (ui-enabled?)
        (ui-write-line (ui-symbol 'work) 'cyan label
          (if (null? maybe-message) #f (car maybe-message))
          #f)))

    (define (ui-status-done label . maybe-message)
      (when (ui-enabled?)
        (ui-write-line (ui-symbol 'done) 'green label
          (if (null? maybe-message) #f (car maybe-message))
          #t)))

    (define (ui-status-fail label . maybe-message)
      (when (ui-enabled?)
        (ui-write-line (ui-symbol 'fail) 'red label
          (if (null? maybe-message) #f (car maybe-message))
          #t)))

    (define (bar-fill width done total)
      (if (or (= total 0) (= width 0))
        0
        (quotient (* width done) total)))

    (define (repeat-char text n)
      (let loop ((i n) (out ""))
        (if (<= i 0)
          out
          (loop (- i 1) (string-append out text)))))

    (define (ui-progress label done total . maybe-message)
      (when (ui-enabled?)
        (let* ((width 20)
               (filled (bar-fill width done total))
               (empty (- width filled))
               (message (if (null? maybe-message) #f (car maybe-message))))
          (ui-clear-line)
          (display (ui-colorize 'blue "[") (current-error-port))
          (display (ui-colorize 'green (repeat-char (ui-symbol 'bar) filled)) (current-error-port))
          (display (repeat-char (ui-symbol 'empty) empty) (current-error-port))
          (display (ui-colorize 'blue "]") (current-error-port))
          (display " " (current-error-port))
          (display done (current-error-port))
          (display "/" (current-error-port))
          (display total (current-error-port))
          (display " " (current-error-port))
          (display label (current-error-port))
          (when message
            (display " " (current-error-port))
            (display message (current-error-port)))
          (set! current-ui-line-active #t))))

    (define (display-padding count)
      (let loop ((n count))
        (when (> n 0)
          (display " " (current-error-port))
          (loop (- n 1)))))

    (define (ui-display-status label color message)
      (when (ui-enabled?)
        (ui-clear-active-line)
        (display-padding (max 1 (- 12 (string-length label))))
        (display (ui-colorize color label) (current-error-port))
        (when message
          (display " " (current-error-port))
          (display message (current-error-port)))
        (newline (current-error-port))))))
