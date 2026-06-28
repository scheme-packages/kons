(define-library (kons actions graph)
  (export cmd-graph)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons util)
    (kons names)
    (kons manifest)
    (kons features)
    (kons lock)
    (kons options)
    (kons compat json)
    (kons actions paths)
    (kons actions lock-shared)
    (kons actions tree-clean))

  (begin
    (define (graph-node-id value)
      (cond
        ((symbol? value) (symbol->string value))
        ((string? value) value)
        ((number? value) (number->string value))
        ((null? value) "")
        ((pair? value)
          (let loop ((items value) (out ""))
            (cond
              ((null? items) out)
              ((string=? out "") (loop (cdr items) (graph-node-id (car items))))
              (else (loop (cdr items)
                     (string-append out "/" (graph-node-id (car items))))))))
        (else "value")))

    (define (graph-entry-type entry)
      (or (lock-entry-type entry)
        (and (pair? entry) (car entry))
        'dependency))

    (define (graph-node-label entry)
      (case (graph-entry-type entry)
        ((registry)
          (string-append
            (name->string (lock-entry-ref entry 'name '()))
            " "
            (lock-entry-ref entry 'version "")))
        ((system)
          (string-append "system " (graph-node-id (lock-entry-rest entry 'names))))
        (else
          (string-append
            (symbol->string (graph-entry-type entry))
            " "
            (name->string (lock-entry-ref entry 'name '()))))))

    (define (graph-node-id-for-entry entry)
      (or (lock-entry-ref entry 'id #f)
        (let ((version (graph-node-id (lock-entry-ref entry 'version "")))
              (prefix (string-append
                       (symbol->string (graph-entry-type entry))
                       ":"
                       (graph-node-id (lock-entry-ref entry 'name (lock-entry-rest entry 'names))))))
          (if (string=? version "")
            prefix
            (string-append prefix ":" version)))))

    (define (graph-node-from-lock-entry entry)
      `(node
        (id ,(graph-node-id-for-entry entry))
        (label ,(graph-node-label entry))
        (type ,(graph-entry-type entry))
        (name ,(lock-entry-ref entry 'name (lock-entry-rest entry 'names)))
        (version ,(lock-entry-ref entry 'version #f))))

    (define (root-node-id)
      "root")

    (define (root-node manifest)
      `(node
        (id ,(root-node-id))
        (label ,(name->string (package-name manifest)))
        (type root)
        (name ,(package-name manifest))
        (version ,(package-version manifest))))

    (define (graph-edge id from to label kind)
      `(edge
        (id ,id)
        (from ,from)
        (to ,to)
        (label ,label)
        (kind ,kind)))

    (define (graph-edge-from-lock-edge index edge)
      (graph-edge
        (string-append "edge-" (number->string index))
        (graph-node-id (lock-entry-ref edge 'from 'root))
        (lock-entry-ref edge 'to "")
        (name->string (lock-entry-ref edge 'name '()))
        (lock-entry-ref edge 'kind 'runtime)))

    (define (root-edge-for-entry index entry)
      (graph-edge
        (string-append "root-edge-" (number->string index))
        (root-node-id)
        (graph-node-id-for-entry entry)
        (graph-node-label entry)
        (lock-entry-scope entry)))

    (define (root-lock-entry? entry)
      (and (not (eq? (graph-entry-type entry) 'registry))
        (not (eq? (lock-entry-ref entry 'scope 'runtime) 'normal))))

    (define (indexed-map proc items)
      (let loop ((items items) (index 0) (out '()))
        (if (null? items)
          (reverse out)
          (loop (cdr items) (+ index 1) (cons (proc index (car items)) out)))))

    (define (locked-graph-form manifest features lock)
      (let ((entries (lock-package-entries lock))
            (edges (lock-edge-entries lock)))
        `(graph
          (root
           (name ,(package-name manifest))
           (version ,(package-version manifest))
           (scheme ,(lock-root-scheme lock))
           (target ,(lock-root-target lock))
           (profile ,(lock-root-profile lock))
           (features ,@(lock-root-features lock)))
          (source lockfile)
          (nodes
           ,(root-node manifest)
           ,@(map graph-node-from-lock-entry entries))
          (edges
           ,@(if (null? edges)
              (indexed-map root-edge-for-entry entries)
              (append
                (indexed-map graph-edge-from-lock-edge edges)
                (indexed-map root-edge-for-entry (filter root-lock-entry? entries))))))))

    (define (live-dependency-node-id dep)
      (string-append
        (symbol->string (alist-ref dep 'type 'dependency))
        ":"
        (graph-node-id (alist-ref dep 'name (alist-ref dep 'names '())))))

    (define (live-dependency-label dep)
      (let ((name (alist-ref dep 'name (alist-ref dep 'names '()))))
        (if (null? name)
          (symbol->string (alist-ref dep 'type 'dependency))
          (graph-node-id name))))

    (define (live-node dep)
      `(node
        (id ,(live-dependency-node-id dep))
        (label ,(live-dependency-label dep))
        (type ,(alist-ref dep 'type 'dependency))
        (name ,(alist-ref dep 'name (alist-ref dep 'names '())))))

    (define (live-edge index dep)
      (graph-edge
        (string-append "edge-" (number->string index))
        (root-node-id)
        (live-dependency-node-id dep)
        (live-dependency-label dep)
        (alist-ref dep 'scope 'runtime)))

    (define (candidate-graph-form manifest features cmd)
      (let ((deps (all-dependencies-for manifest #t features cmd)))
        `(graph
          (root
           (name ,(package-name manifest))
           (version ,(package-version manifest))
           (scheme ,(command-selected-scheme cmd))
           (target ,(command-option cmd "target" #f))
           (profile ,(command-selected-profile cmd))
           (features ,@features))
          (source candidate)
          (nodes
           ,(root-node manifest)
           ,@(map live-node deps))
          (edges
           ,@(indexed-map live-edge deps)))))

    (define (dot-escape text)
      (let loop ((chars (string->list text)) (out ""))
        (cond
          ((null? chars) out)
          ((char=? (car chars) #\")
            (loop (cdr chars) (string-append out "\\\"")))
          ((char=? (car chars) #\\)
            (loop (cdr chars) (string-append out "\\\\")))
          (else
            (loop (cdr chars) (string-append out (string (car chars))))))))

    (define (dot-string value)
      (string-append "\"" (dot-escape (graph-node-id value)) "\""))

    (define (graph-section form name)
      (let ((found (assq name (cdr form))))
        (if found (cdr found) '())))

    (define (graph-field form name default)
      (let ((found (and (pair? form) (assq name (cdr form)))))
        (if found (cadr found) default)))

    (define (graph-field-values form name)
      (let ((found (and (pair? form) (assq name (cdr form)))))
        (if found (cdr found) '())))

    (define (graph-single-value values)
      (cond
        ((null? values) #f)
        ((null? (cdr values)) (car values))
        (else values)))

    (define (graph-value->json value)
      (cond
        ((symbol? value) (symbol->string value))
        ((or (string? value) (number? value) (boolean? value)) value)
        ((null? value) '#())
        ((pair? value) (list->vector (map graph-value->json value)))
        (else #f)))

    (define (graph-entry->json entry)
      (map (lambda (field)
            (cons (car field)
              (graph-value->json (graph-single-value (cdr field)))))
        (cdr entry)))

    (define (graph-entries->json entries)
      (list->vector (map graph-entry->json entries)))

    (define (graph-form->json form)
      `((formatVersion . 1)
        (root . ,(graph-entry->json (assq 'root (cdr form))))
        (source . ,(graph-value->json
                    (graph-single-value (graph-field-values form 'source))))
        (nodes . ,(graph-entries->json (graph-section form 'nodes)))
        (edges . ,(graph-entries->json (graph-section form 'edges)))))

    (define (display-dot-node node)
      (display "  ")
      (display (dot-string (graph-field node 'id "")))
      (display " [label=")
      (display (dot-string (graph-field node 'label "")))
      (displayln "];"))

    (define (display-dot-edge edge)
      (display "  ")
      (display (dot-string (graph-field edge 'from "")))
      (display " -> ")
      (display (dot-string (graph-field edge 'to "")))
      (let ((label (graph-field edge 'label "")))
        (unless (string=? label "")
          (display " [label=")
          (display (dot-string label))
          (display "]")))
      (displayln ";"))

    (define (write-graph-dot form)
      (displayln "digraph kons_dependencies {")
      (for-each display-dot-node (graph-section form 'nodes))
      (for-each display-dot-edge (graph-section form 'edges))
      (displayln "}"))

    (define (write-graph cmd form)
      (writeln form))

    (define (cmd-graph cmd)
      (let* ((manifest (parse-manifest (command-manifest-path cmd)))
             (features (active-features manifest cmd))
             (lock (matching-lock manifest features cmd)))
        (ensure-supported-active-features manifest features cmd)
        (when (and (not lock) (command-locked-mode? cmd))
          (if (file-exists? (command-lock-path manifest cmd))
            (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`")
            (lockfile-error "kons.lock missing; run `kons update` first")))
        (if lock
          (write-graph cmd (locked-graph-form manifest features lock))
          (write-graph cmd (candidate-graph-form manifest features cmd)))))))
