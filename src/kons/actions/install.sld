(define-library (kons actions install)
  (export cmd-install)
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
          (kons ui)
          (kons options)
          (kons actions activation)
          (kons actions paths)
          (kons actions targets))

  (begin
(define (installed-compiled-root cmd raw-name)
  (path-join
   (path-join (install-lib-dir cmd) "compiled")
   (safe-store-token raw-name)))

(define (installed-dependency-plan-root cmd source)
  (if (file-exists? source)
      (installed-dependency-root cmd source)
      (path-join
       (path-join (install-lib-dir cmd) "dependencies")
       (string-append
        (safe-store-token (absolute-path source))
        "-planned"))))

(define (copy-installed-source-root source dest)
  (ui-status "copying dependency sources" dest)
  (copy-source-root source dest)
  (ui-status-done "copied dependency sources" dest))

(define (copy-installed-source-roots sources destinations)
  (cond
   ((and (null? sources) (null? destinations)) '())
   ((or (null? sources) (null? destinations))
    (manifest-error "install source and destination counts do not match"))
   (else
    (copy-installed-source-root (car sources) (car destinations))
    (copy-installed-source-roots (cdr sources) (cdr destinations)))))

(define (cmd-install cmd)
  (let* ((manifest (parse-manifest (install-manifest-path cmd)))
         (features (active-features manifest cmd))
         (dir (install-bin-dir cmd))
         (raw-name (command-option cmd "name"
                                 (command-option cmd "bin"
                                               (default-binary-name manifest))))
         (bin-path (path-join dir raw-name)))
    (ensure-supported-active-features manifest features cmd)
    (unless (command-flag? cmd "plan")
      (ensure-runtime-activation-ready! manifest features cmd))
    (let* ((live-src (map absolute-path (activation-source-roots-with-build manifest #f features cmd)))
           (source-path (package-source-path manifest))
           (app-root (path-join (path-join (install-lib-dir cmd) "bin") raw-name))
           (installed-root-source (path-join app-root source-path))
           (installed-deps-plan (map (lambda (source) (installed-dependency-plan-root cmd source))
                                     (cdr live-src)))
           (src-plan (cons installed-root-source installed-deps-plan))
           (live-main (selected-install-script manifest cmd))
           (main (selected-install-main-path manifest cmd installed-root-source))
           (scheme (adapter-scheme manifest (command-selected-scheme cmd)))
           (install-compile-mode (command-runtime-compile-mode manifest features cmd #t))
           (installed-compiled-plan (if (eq? install-compile-mode 'compiled)
                                        (list (installed-compiled-root cmd raw-name))
                                        '()))
           (launcher-cmd (launcher-command-for-cmd manifest cmd scheme src-plan main installed-compiled-plan))
           (activation-path (string-append bin-path ".activation.scm")))
      (if (command-flag? cmd "plan")
          (writeln
           `(install-plan
             (root ,(package-name manifest))
             (profile ,(command-selected-profile cmd))
             (features ,@features)
             (launcher-name ,raw-name)
             (launcher ,bin-path)
             (activation ,activation-path)
             (install-root ,(install-root-prefix cmd))
             (lib-root ,(install-lib-dir cmd))
             (source-roots ,@live-src)
             (installed-source-roots ,@src-plan)
             (compiled-load-paths ,@installed-compiled-plan)
             (main ,main)
             (scheme ,scheme)
             (command ,(adapter-command scheme
                                       src-plan
                                       main
                                       '()
                                       (if (null? installed-compiled-plan) 'normal 'compiled)
                                       installed-compiled-plan
                                       (command-selected-profile cmd)))))
          (let ((installed-deps (map (lambda (source) (install-dependency-root cmd source))
                                     (cdr live-src))))
            (unless (file-exists? live-main)
              (manifest-error "main script not found" live-main))
            (ui-status "creating install directory" dir)
            (run-command (string-append "mkdir -p " (shell-quote dir)))
            (ui-status-done "created install directory" dir)
            (ui-status "copying package sources" installed-root-source)
            (copy-source-root (absolute-path (manifest-source-root manifest)) installed-root-source)
            (ui-status-done "copied package sources" installed-root-source)
            (copy-installed-source-roots (cdr live-src) installed-deps)
            (when (eq? install-compile-mode 'compiled)
              (let ((local-compiled-root (compiled-output-dir manifest features cmd)))
                (compile-implementation-libraries manifest features cmd live-src)
                (ui-status "copying compiled artifacts" (installed-compiled-root cmd raw-name))
                (copy-source-root local-compiled-root
                                  (installed-compiled-root cmd raw-name))
                (ui-status-done "copied compiled artifacts" (installed-compiled-root cmd raw-name))))
            (ui-status "writing launcher" bin-path)
            (write-launcher bin-path launcher-cmd)
            (ui-status-done "wrote launcher" bin-path)
            (ui-status "writing activation metadata" activation-path)
            (write-expr-file
             activation-path
             (activation-metadata manifest
                                  cmd
                                  bin-path
                                  main
                                  (cons installed-root-source installed-deps)
                                  features
                                  scheme
                                  (if (eq? install-compile-mode 'compiled)
                                      (list (installed-compiled-root cmd raw-name))
                                      '())))
            (run-command (string-append "chmod +x " (shell-quote bin-path)))
            (ui-status-done "wrote activation metadata" activation-path)
            (display "installed ")
            (displayln bin-path))))))

  ))
