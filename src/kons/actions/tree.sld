(define-library (kons actions tree)
  (export cmd-tree)
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
          (kons actions paths)
          (kons actions lock-shared)
          (kons actions tree-clean))

  (begin
(define (cmd-tree cmd)
  (let* ((manifest (parse-manifest (command-manifest-path cmd)))
         (features (active-features manifest cmd))
         (lock (matching-lock manifest features cmd)))
    (ensure-supported-active-features manifest features cmd)
    (when (and (not lock) (command-locked-mode? cmd))
      (if (file-exists? (project-lock-path manifest))
          (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`")
          (lockfile-error "kons.lock missing; run `kons update` first")))
    (if lock
        (writeln
         `(tree
           (root
            (name ,(package-name manifest))
            (version ,(package-version manifest))
            (scheme ,(lock-root-scheme lock))
            (target ,(lock-root-target lock))
            (profile ,(lock-root-profile lock))
            (features ,@(lock-root-features lock)))
           (source lockfile)
           (dependencies
            ,@(map tree-dependency-from-lock-entry
                   (lock-package-entries lock)))))
        (writeln
         `(tree
           (root
            (name ,(package-name manifest))
            (version ,(package-version manifest))
            (scheme ,(command-selected-scheme cmd))
            (target ,(command-option cmd "target" #f))
            (profile ,(command-selected-profile cmd))
            (features ,@features))
           (source candidate)
           (dependencies
            ,@(map tree-dependency-from-live
                   (all-dependencies-for manifest #t features cmd))))))))

  ))
