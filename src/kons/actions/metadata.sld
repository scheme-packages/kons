(define-library (kons actions metadata)
  (export cmd-metadata)
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
          (kons library-discovery))

  (begin
(define (json-format? value)
  (and value (string=? value "json")))

(define (proper-list? value)
  (let loop ((item value))
    (cond
     ((null? item) #t)
     ((pair? item) (loop (cdr item)))
     (else #f))))

(define (metadata-object-entry? value)
  (and (pair? value)
       (symbol? (car value))))

(define (metadata-object? value)
  (and (proper-list? value)
       (not (null? value))
       (let loop ((items value))
         (cond
          ((null? items) #t)
          ((metadata-object-entry? (car items)) (loop (cdr items)))
          (else #f)))))

(define (metadata-list->json items)
  (list->vector (map metadata-value->json items)))

(define (metadata-object->json items)
  (map (lambda (item)
         (cons (car item) (metadata-value->json (cdr item))))
       items))

(define (metadata-value->json value)
  (cond
   ((symbol? value) (symbol->string value))
   ((or (string? value) (number? value) (boolean? value)) value)
   ((null? value) '#())
   ((metadata-object? value) (metadata-object->json value))
   ((proper-list? value) (metadata-list->json value))
   ((pair? value) (metadata-list->json (list (car value) (cdr value))))
   (else (internal-error "cannot convert metadata value to JSON" value))))

(define (write-metadata-json metadata)
  (json-write
   (cons (cons 'formatVersion 1)
         (metadata-value->json metadata))
   (current-output-port))
  (newline))

(define (cmd-metadata cmd)
  (let ((metadata (manifest-with-effective-libraries
                   (parse-manifest (command-manifest-path cmd)))))
    (if (json-format? (command-option cmd "format" "sexp"))
        (write-metadata-json metadata)
        (writeln metadata))))

  ))
