(import (scheme base)
        (scheme process-context)
        (srfi 64)
        (kons actions doctor-shared)
        (kons util))

(test-begin "kons doctor")

(define root "/tmp/kons-doctor-test")
(define bin-dir (path-join root "bin"))
(define output-path (path-join root "doctor.out"))

(define (check-output pattern)
  (shell-command-status
   (string-append
    "grep -F "
    (shell-quote pattern)
    " "
    (shell-quote output-path)
    " >/dev/null")))

(test-equal
 "missing command path is false"
 #f
 (command-path "__kons_missing_doctor_command__"))

(test-equal
 "missing command report is unavailable"
 '(missing
   (command "__kons_missing_doctor_command__")
   (role "test tool")
   (required #t)
   (available #f))
 (command-report 'missing "__kons_missing_doctor_command__" "test tool" #t))

(test-equal
 "required missing tool fails doctor ok"
 #f
 (doctor-ok?
  (list
   (command-report 'missing "__kons_missing_doctor_command__" "test tool" #t))))

(let ((capy-path (command-path "capy"))
      (dirname-path (command-path "dirname"))
      (cache-home (or (get-environment-variable "XDG_CACHE_HOME")
                      (path-join root "cache"))))
  (when (and capy-path dirname-path)
    (run-command (string-append "rm -rf " (shell-quote root)))
    (run-command (string-append "mkdir -p " (shell-quote bin-dir)))
    (run-command
     (string-append
      "ln -sf " (shell-quote capy-path) " " (shell-quote (path-join bin-dir "capy"))))
    (run-command
     (string-append
      "ln -sf " (shell-quote dirname-path) " " (shell-quote (path-join bin-dir "dirname"))))
    (test-equal
     "launcher doctor falls back to available manager"
     0
     (shell-command-status
      (string-append
       "PATH=" (shell-quote bin-dir)
       " XDG_CACHE_HOME=" (shell-quote cache-home)
       " KONS_SCHEME=ironscheme ./bin/kons doctor >"
       (shell-quote output-path))))
    (test-equal
     "launcher doctor preserves selected scheme"
     0
     (check-output "(selected-scheme ironscheme)"))
    (test-equal
     "launcher doctor reports selected scheme action"
     0
     (check-output "(install-selected-scheme ironscheme)"))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons doctor")
  (exit (if (= failures 0) 0 1)))
