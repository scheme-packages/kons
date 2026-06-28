(define-library (kons actions status)
  (export cmd-status)
  (import (scheme base)
    (scheme file)
    (scheme process-context)
    (scheme write)
    (kons util)
    (kons implementation)
    (kons manifest)
    (kons features)
    (kons lock)
    (kons runner)
    (kons options)
    (kons compat json)
    (kons actions status-shared))

  (begin
    (define (json-format? value)
      (and value (string=? value "json")))

    (define (proper-list? value)
      (let loop ((item value))
        (cond
          ((null? item) #t)
          ((pair? item) (loop (cdr item)))
          (else #f))))

    (define (status-object-entry? value)
      (and (pair? value)
        (symbol? (car value))))

    (define (status-object? value)
      (and (proper-list? value)
        (not (null? value))
        (let loop ((items value))
          (cond
            ((null? items) #t)
            ((status-object-entry? (car items)) (loop (cdr items)))
            (else #f)))))

    (define (status-list->json items)
      (list->vector (map status-value->json items)))

    (define (status-object->json items)
      (map (lambda (item)
            (cons (car item)
              (if (proper-list? (cdr item))
                (status-field-values->json (car item) (cdr item))
                (status-value->json (cdr item)))))
        items))

    (define (status-array-field? key)
      (memq key '(features
                  libraries
                  tests
                  benches
                  examples
                  scripts
                  bins
                  source-roots
                  load-paths
                  actions
                  locked-dependencies
                  runtime
                  dev)))

    (define (status-field-values->json key values)
      (cond
        ((null? values) '#())
        ((and (eq? key 'name) (null? (cdr values)))
          (status-name->json (car values)))
        ((status-array-field? key) (status-list->json values))
        ((null? (cdr values)) (status-value->json (car values)))
        (else (status-list->json values))))

    (define (status-name->json value)
      (cond
        ((and (proper-list? value)
            (not (null? value))
            (proper-list? (car value))
            (null? (cdr value)))
          (status-list->json (car value)))
        ((proper-list? value) (status-list->json value))
        (else (status-value->json value))))

    (define (status-section->json section)
      (map (lambda (field)
            (cons (car field) (status-field-values->json (car field) (cdr field))))
        (cdr section)))

    (define (status-value->json value)
      (cond
        ((symbol? value) (symbol->string value))
        ((or (string? value) (number? value) (boolean? value)) value)
        ((null? value) '#())
        ((and (pair? value) (symbol? (car value)) (status-object? (cdr value)))
          (status-object->json (cdr value)))
        ((status-object? value) (status-object->json value))
        ((proper-list? value) (status-list->json value))
        ((pair? value) (status-list->json (list (car value) (cdr value))))
        (else (internal-error "cannot convert status value to JSON" value))))

    (define (status-form->json form)
      (if (and (pair? form) (eq? (car form) 'status))
        (cons
          (cons 'formatVersion 1)
          (map (lambda (section)
                (cons (car section)
                  (if (or (eq? (car section) 'actions)
                       (eq? (car section) 'locked-dependencies))
                    (status-list->json (cdr section))
                    (status-section->json section))))
            (cdr form)))
        (status-value->json form)))

    (define (write-status-json form)
      (json-write (status-form->json form) (current-output-port))
      (newline))

    (define (cmd-status cmd)
      (let* ((manifest (parse-manifest (command-manifest-path cmd)))
             (features (active-features manifest cmd))
             (form (status-form manifest features cmd)))
        (ensure-supported-active-features manifest features cmd)
        (if (json-format? (command-option cmd "format" "sexp"))
          (write-status-json form)
          (writeln form))))))
