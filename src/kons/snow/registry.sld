(define-library (kons snow registry)
  (export snow-index-metadata?
    snow-index-metadata-repository-url
    snow-index-metadata-index-path
    snow-fetch-index!)
  (import (scheme base)
    (scheme file)
    (kons snow config)
    (kons snow format)
    (kons util))

  (begin
    (define-record-type <snow-index-metadata>
      (make-snow-index-metadata repository-url index-path)
      snow-index-metadata?
      (repository-url snow-index-metadata-repository-url)
      (index-path snow-index-metadata-index-path))

    (define (metadata-root repository-url)
      (path-join (snow-metadata-root) (safe-store-token repository-url)))

    (define (index-cache-path root)
      (path-join root "repo.scm"))

    (define (download-file! url output)
      (run-command (string-append "mkdir -p " (shell-quote (dirname output))))
      (cond
        ((file-exists? url)
          (run-command
            (string-append "cp " (shell-quote url) " " (shell-quote output))))
        (else
          (let ((status
                  (shell-command-status
                    (string-append
                      "curl --connect-timeout 10 --max-time 120 -fsSL "
                      (shell-quote url)
                      " -o "
                      (shell-quote output)
                      " >/dev/null 2>&1"))))
            (unless (= status 0)
              (dependency-error "Snow repository could not be fetched" url))))))

    (define (cached-index repository-url root)
      (let ((path (index-cache-path root)))
        (unless (file-exists? path)
          (dependency-error "missing offline cache for Snow repository" repository-url))
        (read-snow-repository path)
        (make-snow-index-metadata repository-url path)))

    (define (fetch-live-index! repository-url root)
      (let ((tmp (temporary-file-path "kons-snow-repo.scm"))
            (path (index-cache-path root)))
        (download-file! repository-url tmp)
        (read-snow-repository tmp)
        (run-command (string-append "mkdir -p " (shell-quote root)))
        (run-command
          (string-append "cp " (shell-quote tmp) " " (shell-quote path)))
        (when (file-exists? tmp)
          (delete-file tmp))
        (make-snow-index-metadata repository-url path)))

    (define (snow-fetch-index! source offline?)
      (let* ((repository-url (snow-repository-url source))
             (root (metadata-root repository-url)))
        (if offline?
          (cached-index repository-url root)
          (fetch-live-index! repository-url root))))))
