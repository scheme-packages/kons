(define-library (kons snow lock)
  (export locked-snow-refs
    snow-resolution-lock-data)
  (import (scheme base)
    (kons util)
    (kons resolver)
    (kons snow config)
    (kons snow format)
    (kons snow registry)
    (kons snow resolver)
    (kons dep shared))

  (begin
    (define (snow-lock-ref alist key default)
      (let ((found (assoc key alist)))
        (if found (cdr found) default)))

    (define (lock-entry-snow? entry)
      (and (pair? entry)
        (eq? (car entry) 'package)
        (eq? (lock-entry-ref entry 'type #f) 'snow)))

    (define (locked-snow-ref entry)
      `((name . ,(lock-entry-ref
                  entry
                  'resolver-name
                  (snow-package-name->resolver-name
                    (lock-entry-ref entry 'name '()))))
        (version . ,(lock-entry-ref entry 'version ""))
        (registry . ,(lock-entry-ref entry 'source default-snow-source-alias))))

    (define (locked-snow-refs lock)
      (if lock
        (map locked-snow-ref
          (filter lock-entry-snow? (lock-package-entries lock)))
        '()))

    (define (edge-ref edge key default)
      (snow-lock-ref edge key default))

    (define (edge-for-candidate id edges)
      (let loop ((items edges))
        (cond
          ((null? items) #f)
          ((equal? id (edge-ref (car items) 'to #f)) (car items))
          (else (loop (cdr items))))))

    (define (lock-edge-entry edge)
      `(edge
        (from ,(edge-ref edge 'from 'root))
        (to ,(edge-ref edge 'to ""))
        (name ,(edge-ref edge 'name '()))
        (req ,(edge-ref edge 'req "*"))
        (kind ,(edge-ref edge 'kind 'runtime))
        (features ,@(edge-ref edge 'features '()))
        (optional ,(edge-ref edge 'optional #f))
        ,@(dependency-selector-fields edge)))

    (define (snow-requirement-source req)
      (snow-lock-ref req 'registry default-snow-source-alias))

    (define (source-known? source sources)
      (let loop ((items sources))
        (cond
          ((null? items) #f)
          ((string=? source (car items)) #t)
          (else (loop (cdr items))))))

    (define (unique-snow-sources requirements)
      (let loop ((items requirements) (out '()))
        (cond
          ((null? items) (reverse out))
          (else
            (let ((source (snow-requirement-source (car items))))
              (if (source-known? source out)
                (loop (cdr items) out)
                (loop (cdr items) (cons source out))))))))

    (define (snow-source-candidates source offline?)
      (let* ((metadata (snow-fetch-index! source offline?))
             (packages (read-snow-repository (snow-index-metadata-index-path metadata))))
        (snow-packages->resolver-candidates packages source)))

    (define (lock-value-key value)
      (cond
        ((symbol? value) (symbol->string value))
        ((string? value) value)
        ((number? value) (number->string value))
        ((null? value) "")
        ((pair? value)
          (let loop ((items value) (out ""))
            (cond
              ((null? items) out)
              ((string=? out "") (loop (cdr items) (lock-value-key (car items))))
              (else
                (loop (cdr items)
                  (string-append out "/" (lock-value-key (car items))))))))
        (else "value")))

    (define (snow-key-component value)
      (cond
        ((symbol? value) (symbol->string value))
        ((string? value) value)
        ((number? value) (number->string value))
        (else (lock-value-key value))))

    (define (snow-resolver-name->key name)
      (cond
        ((and (pair? name)
            (eq? (car name) 'snow)
            (pair? (cdr name))
            (eq? (cadr name) 'list))
          (let loop ((items (cddr name)) (out "snow/list"))
            (if (null? items)
              out
              (loop (cdr items)
                (string-append out "/" (safe-store-token (snow-key-component (car items))))))))
        (else (safe-store-token (lock-value-key name)))))

    (define (absolute-snow-url repository-url url)
      (cond
        ((string-contains? url "://") url)
        ((string-prefix? "/" url)
          (let* ((scheme-pos (string-substring-index repository-url "://"))
                 (start (if scheme-pos (+ scheme-pos 3) 0))
                 (slash (string-index-from repository-url #\/ start)))
            (if slash
              (string-append (substring repository-url 0 slash) url)
              (string-append repository-url url))))
        (else
          (string-append
            (if (string-suffix? "/" repository-url)
              repository-url
              (string-append (dirname repository-url) "/"))
            url))))

    (define (string-substring-index text needle)
      (let ((tlen (string-length text))
            (nlen (string-length needle)))
        (let loop ((i 0))
          (cond
            ((= nlen 0) 0)
            ((> (+ i nlen) tlen) #f)
            ((string=? (substring text i (+ i nlen)) needle) i)
            (else (loop (+ i 1)))))))

    (define (string-index-from text ch start)
      (let ((len (string-length text)))
        (let loop ((i start))
          (cond
            ((= i len) #f)
            ((char=? (string-ref text i) ch) i)
            (else (loop (+ i 1)))))))

    (define (maybe-lock-field key value)
      (if value `((,key ,value)) '()))

    (define (snow-source-cache-path key version sha256 url)
      (path-join
        (path-join (snow-sources-root) key)
        (safe-store-token
          (string-append version "-" (or sha256 url)))))

    (define (snow-candidate-lock-entry candidate edges)
      (let* ((id (candidate-id candidate))
             (edge (edge-for-candidate id edges))
             (resolver-name (snow-lock-ref candidate 'name '()))
             (key (snow-resolver-name->key resolver-name))
             (version (snow-lock-ref candidate 'version ""))
             (source (snow-lock-ref candidate 'registry default-snow-source-alias))
             (source-url (snow-repository-url source))
             (url (absolute-snow-url source-url (snow-lock-ref candidate 'snow-url "")))
             (sha256 (snow-lock-ref candidate 'snow-sha256 #f)))
        (append
          `(package
            (id ,id)
            (scope ,(if edge (edge-ref edge 'kind 'runtime) 'runtime))
            (type snow)
            (name ,(snow-lock-ref candidate 'snow-name '()))
            (package-name ,(snow-lock-ref candidate 'snow-package-name '()))
            (resolver-name ,resolver-name)
            (key ,key)
            (req ,(if edge (edge-ref edge 'req "*") "*"))
            (version ,version)
            (source ,source)
            (source-url ,source-url)
            (url ,url))
          (maybe-lock-field 'sha256 sha256)
          (maybe-lock-field 'size (snow-lock-ref candidate 'snow-size #f))
          `((source-cache-path
             ,(snow-source-cache-path key version sha256 url))
            (optional #f)))))

    (define (snow-resolution-lock-data deps offline? preferred-refs manifest cmd)
      (let ((requirements (map snow-dependency->resolver-requirement deps)))
        (if (null? requirements)
          (cons '() '())
          (let* ((sources (unique-snow-sources requirements))
                 (candidates (append-map
                              (lambda (source)
                                (snow-source-candidates source offline?))
                              sources))
                 (resolution (resolve-snow-dependencies
                              requirements
                              candidates
                              preferred-refs))
                 (edges (resolution-edges resolution)))
            (cons
              (map (lambda (candidate)
                    (snow-candidate-lock-entry candidate edges))
                (resolution-packages resolution))
              (map lock-edge-entry edges))))))))
