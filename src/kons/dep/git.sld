(define-library (kons dep git)
  (export git-dependency-resolution-root
    git-dependency-source-root
    locked-git-entry-root
    git-checkout-ready?
    materialize-git-checkout!
    materialize-git-dependency
    materialize-locked-git-entry
    git-lock-entry)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons util)
    (kons names)
    (kons manifest)
    (kons dep shared)
    (kons dep store))

  (begin
    (define (git-dependency-url dep)
      (alist-ref dep 'url ""))

    (define (local-git-dependency-root root dep)
      (let ((url (git-dependency-url dep)))
        (cond
          ((file-exists? url) url)
          ((and (not (absolute-path? url))
              (file-exists? (path-join root url)))
            (path-join root url))
          (else #f))))

    (define (remote-git-dependency? root dep)
      (not (local-git-dependency-root root dep)))

    (define (git-dependency-cache-root dep)
      (path-join
        (path-join (kons-store-root) "git-cache")
        (safe-store-token (git-dependency-url dep))))

    (define (ensure-git-dependency-cache dep offline?)
      (let* ((url (git-dependency-url dep))
             (cache-root (git-dependency-cache-root dep))
             (cache-parent (dirname cache-root)))
        (cond
          ((file-exists? cache-root)
            (unless offline?
              (run-command
                (string-append "git -C " (shell-quote cache-root)
                  " fetch --quiet --tags origin")))
            cache-root)
          (offline?
            (dependency-error "git dependency cache is missing and offline/frozen mode is active" url))
          (else
            (run-command (string-append "mkdir -p " (shell-quote cache-parent)))
            (run-command
              (string-append "git clone --quiet " (shell-quote url) " " (shell-quote cache-root)))
            cache-root))))

    (define (git-dependency-resolution-root root dep offline?)
      (or (local-git-dependency-root root dep)
        (ensure-git-dependency-cache dep offline?)))

    (define (git-dependency-commit-at repo-root rev)
      (capture-first-line
        (string-append "git -C " (shell-quote repo-root)
          " rev-parse "
          (shell-quote (string-append (if rev rev "HEAD") "^{commit}")))))

    (define (git-dependency-commit root dep)
      (let ((repo-root (git-dependency-resolution-root root dep #f))
            (rev (alist-ref dep 'rev #f)))
        (git-dependency-commit-at repo-root rev)))

    (define (git-dependency-store-root root dep)
      (let* ((commit (git-dependency-commit root dep))
             (name-token (safe-store-token (name->string (alist-ref dep 'name '(dependency))))))
        (path-join (path-join (path-join (kons-store-root) "sources/git") commit) name-token)))

    (define (git-dependency-source-root root dep)
      (let* ((store-root (git-dependency-store-root root dep))
             (dep-root (if (file-exists? store-root)
                        store-root
                        (git-dependency-resolution-root root dep #f)))
             (package-root (and dep-root
                            (subpath-package-root dep-root (alist-ref dep 'subpath #f))))
             (dep-manifest-path (and package-root (path-join package-root "kons.scm"))))
        (unless dep-root
          (dependency-error "git dependency is not materialized; run `kons fetch` first" (alist-ref dep 'url "")))
        (if (and dep-manifest-path (file-exists? dep-manifest-path))
          (let ((dep-manifest (parse-manifest dep-manifest-path)))
            (path-join package-root (package-source-path dep-manifest)))
          package-root)))

    (define (locked-git-entry-root entry)
      (let* ((commit (lock-entry-ref entry 'commit ""))
             (name-token (safe-store-token (name->string (lock-entry-ref entry 'name '(dependency))))))
        (path-join (path-join (path-join (kons-store-root) "sources/git") commit) name-token)))

    (define git-checkout-ready-lock ".kons-ok")

    (define (git-checkout-ready? dest commit)
      (and (file-exists? (path-join dest git-checkout-ready-lock))
        (= (shell-command-status
            (string-append
              "test -d "
              (shell-quote (path-join dest ".git"))
              " && actual=$(git -C "
              (shell-quote dest)
              " rev-parse --verify HEAD 2>/dev/null)"
              " && test \"$actual\" = "
              (shell-quote commit)))
          0)))

    (define (mark-git-checkout-ready! dest)
      (call-with-output-file (path-join dest git-checkout-ready-lock)
        (lambda (out)
          (display "ok" out)
          (newline out))))

    (define (materialize-git-checkout! repo-root commit dest)
      (unless (git-checkout-ready? dest commit)
        (when (file-exists? dest)
          (run-command (string-append "rm -rf " (shell-quote dest))))
        (run-command (string-append "mkdir -p " (shell-quote (dirname dest))))
        (run-command
          (string-append "git clone --quiet " (shell-quote repo-root) " " (shell-quote dest)))
        (run-command
          (string-append "git -C " (shell-quote dest) " checkout --quiet " (shell-quote commit)))
        (run-command
          (string-append "git -C " (shell-quote dest) " submodule update --quiet --init --recursive"))
        (mark-git-checkout-ready! dest))
      dest)

    (define (materialize-git-dependency manifest dep offline?)
      (let* ((root (manifest-root manifest))
             (repo-root (git-dependency-resolution-root root dep offline?))
             (commit (git-dependency-commit-at repo-root (alist-ref dep 'rev #f)))
             (dest (git-dependency-store-root root dep)))
        (materialize-git-checkout! repo-root commit dest)
        (write-store-metadata
          'git
          commit
          (safe-store-token (name->string (alist-ref dep 'name '(dependency))))
          `(store-entry
            (type git)
            (name ,(alist-ref dep 'name '()))
            (url ,(alist-ref dep 'url ""))
            (rev ,(alist-ref dep 'rev #f))
            (subpath ,(alist-ref dep 'subpath #f))
            (source ,(if (remote-git-dependency? root dep) "remote-git" "local-git"))
            (commit ,commit)
            (root ,dest)))
        dest))

    (define (materialize-locked-git-entry manifest entry offline?)
      (let* ((root (manifest-root manifest))
             (url (lock-entry-ref entry 'url ""))
             (commit (lock-entry-ref entry 'commit ""))
             (dest (locked-git-entry-root entry)))
        (if (git-checkout-ready? dest commit)
          dest
          (let ((repo-root (or (let ((dep `((url . ,url))))
                                (local-git-dependency-root root dep))
                            (ensure-git-dependency-cache `((url . ,url)) offline?))))
            (materialize-git-checkout! repo-root commit dest)
            (write-store-metadata
              'git
              commit
              (safe-store-token (name->string (lock-entry-ref entry 'name '(dependency))))
              `(store-entry
                (type git)
                (name ,(lock-entry-ref entry 'name '()))
                (url ,url)
                (rev ,(lock-entry-ref entry 'rev #f))
                (subpath ,(lock-entry-ref entry 'subpath #f))
                (source ,(lock-entry-ref entry 'source "git"))
                (commit ,commit)
                (root ,dest)))
            dest))))

    (define (git-lock-entry manifest dep)
      (let ((repo-root (git-dependency-resolution-root (manifest-root manifest) dep #f))
            (rev (alist-ref dep 'rev #f)))
        (append
          `(package
            (scope ,(alist-ref dep 'scope 'runtime))
            (type git)
            (name ,(alist-ref dep 'name '()))
            (url ,(alist-ref dep 'url ""))
            (rev ,rev)
            (subpath ,(alist-ref dep 'subpath #f))
            (source ,(if (remote-git-dependency? (manifest-root manifest) dep) "remote-git" "local-git"))
            (commit ,(git-dependency-commit-at repo-root rev)))
          (dependency-selector-fields dep))))))
