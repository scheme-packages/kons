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
    (cyclone
     (import (scheme base)
             (scheme file)
             (kons compat process)))
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

(define (capture-first-line cmd)
  (let ((tmp (next-temporary-path "kons-cyclone-line")))
    (system (string-append cmd " > " (shell-quote tmp)))
    (let ((line (call-with-input-file tmp read-line)))
      (delete-file-if-exists tmp)
      line)))

(define (capture-lines cmd)
  (let ((tmp (next-temporary-path "kons-cyclone-lines")))
    (system (string-append cmd " > " (shell-quote tmp)))
    (let ((lines
           (call-with-input-file
            tmp
            (lambda (in)
              (let loop ((line (read-line in)) (out '()))
                (if (eof-object? line)
                    (reverse out)
                    (loop (read-line in) (cons line out))))))))
      (delete-file-if-exists tmp)
      lines)))

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
         (cyclone (= (system (string-append "test -d " (shell-quote path))) 0))
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
