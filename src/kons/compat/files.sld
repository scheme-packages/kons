(define-library (kons compat files)
  (export current-directory
          file-directory?
          directory-list)
  (import (conduit))
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
    (cyclone
     (import (scheme base)
             (scheme file)))
    (mit
     (import (scheme base)
             (scheme file)
             (only (mit legacy runtime)
                   ->namestring
                   directory-read
                   file-namestring
                   pathname-as-directory
                   pwd)
             (rename (only (mit legacy runtime)
                           file-directory?)
                     (file-directory? mit-file-directory?))))
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

(define (shell-quote-char ch out)
  (if (char=? ch #\')
      (cons #\' (cons #\\ (cons #\' (cons #\' out))))
      (cons ch out)))

(define (shell-quote s)
  (let loop ((i 0) (out (list #\')))
    (if (< i (string-length s))
        (loop (+ i 1) (shell-quote-char (string-ref s i) out))
        (list->string (reverse (cons #\' out))))))

(define temporary-counter 0)

(define (next-temporary-path prefix)
  (set! temporary-counter (+ temporary-counter 1))
  (string-append "/tmp/" prefix "-" (number->string temporary-counter) ".tmp"))

(define (delete-file-if-exists path)
  (when (file-exists? path)
    (delete-file path)))

(define (string-lines text)
  (let ((len (string-length text)))
    (let loop ((i 0) (start 0) (out '()))
      (cond
       ((= i len)
        (reverse
         (if (= start len)
             out
             (cons (substring text start len) out))))
       ((char=? (string-ref text i) #\newline)
        (loop (+ i 1) (+ i 1) (cons (substring text start i) out)))
       (else (loop (+ i 1) start out))))))

(define (capture-first-line cmd)
  (let ((lines (string-lines (process-output->string cmd))))
    (if (null? lines) "" (car lines))))

(define (capture-lines cmd)
  (string-lines (process-output->string cmd)))

(define (current-directory)
  (cond-expand
    (capy (capy-current-directory))
    (gauche (gauche-current-directory))
    (guile (getcwd))
    (chibi (chibi-current-directory))
    (cyclone (capture-first-line "pwd"))
    (mit (->namestring (pwd)))
    (else ".")))

(define (file-directory? path)
  (and (file-exists? path)
       (cond-expand
         (capy (capy-file-directory? path))
         (gauche (gauche-file-directory? path))
         (guile (guile-file-directory? path))
         (chibi (chibi-file-directory? path))
         (cyclone (= (shell-command (string-append "test -d " (shell-quote path))) 0))
         (mit (mit-file-directory? path))
         (else #t))))

(define (directory-list path)
  (cond-expand
    (capy (remove-dot-entries (capy-directory-list path)))
    (gauche (remove-dot-entries (gauche-directory-list path)))
    (guile (remove-dot-entries (scandir path)))
    (chibi (remove-dot-entries (chibi-directory-list path)))
    (cyclone
     (remove-dot-entries
      (capture-lines
       (string-append
        "for p in " (shell-quote path) "/* "
        (shell-quote path) "/.[!.]* "
        (shell-quote path) "/..?*; do "
        "[ -e \"$p\" ] || continue; basename \"$p\"; "
        "done"))))
    (mit
     (remove-dot-entries
      (map file-namestring
           (directory-read (pathname-as-directory path) #f))))
    (else '())))
  ))
