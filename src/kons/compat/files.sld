(define-library (kons compat files)
  (export current-directory
          file-directory?
          directory-list)
  (cond-expand
    (capy
     (import (scheme base)
             (scheme file)
             (rename (core)
                     (file-directory? capy-file-directory?))
             (rename (core files)
                     (current-directory capy-current-directory)
                     (directory-list capy-directory-list))))
    (gauche
     (import (scheme base)
             (scheme file)
             (rename (gauche base)
                     (sys-getcwd gauche-current-directory)
                     (file-is-directory? gauche-file-directory?)
                     (sys-readdir gauche-directory-list))))
    (guile
     (import (scheme base)
             (scheme file)
             (only (guile) getcwd)
             (rename (only (guile) file-is-directory?)
                     (file-is-directory? guile-file-directory?))
             (only (ice-9 ftw) scandir)))
    (chibi
     (import (scheme base)
             (scheme file)
             (rename (chibi filesystem)
                     (current-directory chibi-current-directory)
                     (file-directory? chibi-file-directory?)
                     (directory-files chibi-directory-list))))
    (else
     (import (scheme base)
             (scheme file))))

  (begin
(define (dot-entry? entry)
  (or (string=? entry ".")
      (string=? entry "..")))

(define (remove-dot-entries entries)
  (let loop ((items entries) (out '()))
    (cond
     ((null? items) (reverse out))
     ((dot-entry? (car items)) (loop (cdr items) out))
     (else (loop (cdr items) (cons (car items) out))))))

(define (current-directory)
  (cond-expand
    (capy (capy-current-directory))
    (gauche (gauche-current-directory))
    (guile (getcwd))
    (chibi (chibi-current-directory))
    (else ".")))

(define (file-directory? path)
  (and (file-exists? path)
       (cond-expand
         (capy (capy-file-directory? path))
         (gauche (gauche-file-directory? path))
         (guile (guile-file-directory? path))
         (chibi (chibi-file-directory? path))
         (else #t))))

(define (directory-list path)
  (cond-expand
    (capy (remove-dot-entries (capy-directory-list path)))
    (gauche (remove-dot-entries (gauche-directory-list path)))
    (guile (remove-dot-entries (scandir path)))
    (chibi (remove-dot-entries (chibi-directory-list path)))
    (else '())))
  ))
