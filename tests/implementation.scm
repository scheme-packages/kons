(import (scheme base)
  (scheme process-context)
  (srfi 64)
  (kons implementation)
  (kons manifest)
  (kons runner)
  (kons util))

(test-begin "kons implementation")

(define (check-equal name got expected)
  (test-equal name expected got))

(check-equal
  "sagittarius r7rs command"
  (implementation-command-record
    'sagittarius
    '("src" "vendor")
    "main.scm"
    '("arg")
    'normal
    '()
    'debug)
  '(command
    (env ("SAGITTARIUS_LOADPATH" "src"))
    (argv "sash" "-r7" "-L" "src" "-A" "vendor" "main.scm" "arg")))

(check-equal
  "sagittarius r6rs dialect mode"
  (implementation-mode-id
    (implementation-mode-for-dialects 'sagittarius '(r6rs)))
  'sagittarius-r6rs)

(check-equal
  "capy r6rs dialect mode"
  (implementation-mode-id
    (implementation-mode-for-dialects 'capy '(r6rs)))
  'capy-r6rs)

(define dual-dialect-manifest
  (parse-manifest-exprs
    "/tmp/kons-implementation-test/kons.scm"
    '((package
        (name (example implementation))
        (version "0.1.0")
        (dialects r7rs r6rs)))))

(check-equal
  "capy default adapter prefers r7rs"
  (adapter-scheme dual-dialect-manifest 'capy)
  'capy)

(check-equal
  "capy explicit r6rs adapter"
  (adapter-scheme dual-dialect-manifest 'capy 'r6rs)
  'capy-r6rs)

(check-equal
  "guile explicit r6rs adapter"
  (adapter-scheme dual-dialect-manifest 'guile 'r6rs)
  'guile-r6rs)

(check-equal
  "capy r6rs command"
  (implementation-command-record
    'capy-r6rs
    '("src" "vendor")
    "main.sps"
    '()
    'normal
    '()
    'debug)
  '(command
    (env)
    (argv "capy" "--debug" "--r6rs" "-L" "src" "-A" "vendor" "-s" "main.sps" "--")))

(check-equal
  "mosh r6rs command"
  (implementation-command-record
    'mosh
    '("src" "vendor")
    "main.sps"
    '()
    'normal
    '()
    'debug)
  '(command
    (env ("MOSH_LOADPATH" "src:vendor"))
    (argv "mosh" "--disable-acc" "--loadpath" "src" "--loadpath" "vendor" "main.sps")))

(check-equal
  "mosh does not claim r7rs"
  (implementation-mode-for-dialects 'mosh '(r7rs))
  #f)

(check-equal
  "chez command uses Chez Scheme executable"
  (implementation-command 'chez)
  "chez")

(check-equal
  "mit command"
  (implementation-command-record
    'mit
    '("src" "vendor")
    "main.scm"
    '("arg")
    'normal
    '()
    'debug)
  '(command
    (env)
    (argv "sh"
     "-c"
     "script=$1; shift; tmp=${TMPDIR:-/tmp}/kons_mit_$$; prelude=\"$tmp/prelude.scm\"; mkdir -p \"$tmp\"; : > \"$prelude\"; trap 'rm -rf \"$tmp\"' 0 1 2 15; if [ -d 'src' ]; then printf '%s\n' '(parameterize ((param:hide-notifications? #t)) (find-scheme-libraries! (pathname-as-directory \"src\")))' >> \"$prelude\"; fi; if [ -d 'vendor' ]; then printf '%s\n' '(parameterize ((param:hide-notifications? #t)) (find-scheme-libraries! (pathname-as-directory \"vendor\")))' >> \"$prelude\"; fi; exec 'scheme' --batch-mode --quiet --load \"$prelude\" --load \"$script\" -- \"$@\""
     "kons-mit"
     "main.scm"
     "arg")))

(check-equal
  "stklos r7rs command"
  (implementation-command-record
    'stklos
    '("src" "vendor")
    "main.scm"
    '("arg")
    'normal
    '()
    'debug)
  '(command
    (env)
    (argv "stklos" "-Q" "-I" "src" "-A" "vendor" "-f" "main.scm" "arg")))

(check-equal
  "kawa r7rs command"
  (implementation-command-record
    'kawa
    '("src" "vendor")
    "main.scm"
    '()
    'normal
    '()
    'debug)
  `(command
    (env)
    (argv "kawa"
      "--r7rs"
      ,(string-append "-Dkawa.import.path="
         (absolute-path "src")
         "/*.sld:"
         (absolute-path "vendor")
         "/*.sld")
      "-f"
      "main.scm")))

(check-equal
  "loko r7rs command"
  (implementation-command-record
    'loko
    '("src" "vendor")
    "main.scm"
    '()
    'normal
    '()
    'debug)
  '(command
    (env ("LOKO_LIBRARY_PATH" "src:vendor"))
    (argv "loko" "-std=r7rs" "--program" "main.scm")))

(check-equal
  "ironscheme r6rs command"
  (implementation-command-record
    'ironscheme
    '("src" "vendor")
    "main.sps"
    '()
    'normal
    '()
    'debug)
  '(command
    (env ("IRONSCHEME_LIBRARY_PATH" "src:vendor"))
    (argv "ironscheme" "main.sps")))

(check-equal
  "skint r7rs command"
  (implementation-command-record
    'skint
    '("src" "vendor")
    "main.scm"
    '("arg")
    'normal
    '()
    'debug)
  '(command
    (env)
    (argv "skint" "-I" "src" "-A" "vendor" "--script" "main.scm" "arg")))

(check-equal
  "cyclone r7rs compile-run command"
  (implementation-command-record
    'cyclone
    '("src" "vendor")
    "main.scm"
    '("arg")
    'normal
    '()
    'debug)
  `(command
    (env)
    (argv "sh"
     "-c"
     ,(string-append
       "script=$1; shift; tmp=${TMPDIR:-/tmp}/kons_cyclone_$$; mkdir -p \"$tmp\"; "
       "trap 'rm -rf \"$tmp\"' 0 1 2 15; cp \"$script\" \"$tmp/main.scm\"; "
       "(cd \"$tmp\" && cyclone '-I' "
       (shell-quote (absolute-path "src"))
       " '-A' "
       (shell-quote (absolute-path "vendor"))
       " -o main main.scm) && \"$tmp/main\" \"$@\"")
     "kons-cyclone"
     "main.scm"
     "arg")))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons implementation")
  (exit (if (= failures 0) 0 1)))
