(define-library (kons conditions)
  (export condition-options
    condition-predicate-true?
    condition-option-active?
    condition-option-names
    condition-option-keys
    condition-option-value
    condition-option-name?
    condition-option-value?
    condition-predicate?)
  (import (scheme base)
    (kons util))

  (begin
    (define (string-member? value items)
      (let loop ((xs items))
        (cond
          ((null? xs) #f)
          ((string=? value (car xs)) #t)
          (else (loop (cdr xs))))))

    (define (symbol-value value)
      (cond
        ((symbol? value) (symbol->string value))
        ((string? value) value)
        ((number? value) (number->string value))
        ((boolean? value) (if value "true" "false"))
        (else #f)))

    (define (option-member? option options)
      (let loop ((items options))
        (cond
          ((null? items) #f)
          ((equal? option (car items)) #t)
          (else (loop (cdr items))))))

    (define (dedupe-options options)
      (let loop ((items options) (out '()))
        (cond
          ((null? items) (reverse out))
          ((option-member? (car items) out) (loop (cdr items) out))
          (else (loop (cdr items) (cons (car items) out))))))

    (define (condition-option-name? option)
      (and (pair? option)
        (symbol? (car option))
        (eq? (cdr option) #t)))

    (define (condition-option-value? option)
      (and (pair? option)
        (symbol? (car option))
        (string? (cdr option))))

    (define (condition-option-keys options)
      (let loop ((items options) (out '()))
        (cond
          ((null? items) (dedupe-symbols (reverse out)))
          ((and (pair? (car items)) (symbol? (caar items)))
            (loop (cdr items) (cons (caar items) out)))
          (else (loop (cdr items) out)))))

    (define (condition-option-names options)
      (let loop ((items options) (out '()))
        (cond
          ((null? items) (dedupe-symbols (reverse out)))
          ((condition-option-name? (car items))
            (loop (cdr items) (cons (caar items) out)))
          (else (loop (cdr items) out)))))

    (define (condition-option-value key options)
      (let loop ((items options))
        (cond
          ((null? items) #f)
          ((and (pair? (car items))
              (eq? (caar items) key)
              (string? (cdar items)))
            (cdar items))
          (else (loop (cdr items))))))

    (define (condition-option-active? options key . maybe-value)
      (if (null? maybe-value)
        (option-member? (cons key #t) options)
        (let ((expected (symbol-value (car maybe-value))))
          (and expected (option-member? (cons key expected) options)))))

    (define architectures
      '("x86" "i386" "i486" "i586" "i686" "x86_64" "amd64"
        "arm" "armv7" "aarch64" "mips" "mips64" "powerpc" "powerpc64"
        "riscv32" "riscv64" "s390x" "wasm32" "wasm64"))

    (define concrete-target-oses
      '("windows" "linux" "macos" "darwin" "ios" "android" "freebsd"
        "dragonfly" "openbsd" "netbsd" "none" "wasi" "emscripten"))

    (define target-oses
      (append concrete-target-oses '("unknown")))

    (define target-envs
      '("gnu" "gnueabi" "gnueabihf" "msvc" "musl" "sgx" "uclibc"
        "macabi"))

    (define target-abis
      '("eabi" "eabihf" "macabi" "sim" "llvm" "gnueabi" "gnueabihf"))

    (define (normalize-arch arch)
      (cond
        ((or (not arch) (string=? arch "")) #f)
        ((or (string=? arch "amd64") (string=? arch "x64")) "x86_64")
        ((or (string=? arch "i386") (string=? arch "i486")
           (string=? arch "i586") (string=? arch "i686"))
          "x86")
        ((string=? arch "armv7") "arm")
        (else arch)))

    (define (normalize-os os)
      (cond
        ((or (not os) (string=? os "")) #f)
        ((string=? os "darwin") "macos")
        ((or (string=? os "mingw32") (string=? os "mingw64")
           (string=? os "cygwin") (string=? os "msys"))
          "windows")
        (else os)))

    (define (target-part parts known)
      (let loop ((items parts))
        (cond
          ((null? items) #f)
          ((string-member? (car items) known) (car items))
          (else (loop (cdr items))))))

    (define (target-contains? target needle)
      (and target (string-contains? target needle)))

    (define (detect-arch target parts)
      (normalize-arch
        (or (target-part parts architectures)
          (cond
            ((target-contains? target "x86_64") "x86_64")
            ((target-contains? target "amd64") "amd64")
            ((target-contains? target "aarch64") "aarch64")
            ((target-contains? target "riscv64") "riscv64")
            ((target-contains? target "riscv32") "riscv32")
            ((target-contains? target "wasm32") "wasm32")
            ((target-contains? target "wasm64") "wasm64")
            (else #f)))))

    (define (detect-os target parts)
      (normalize-os
        (or (target-part parts concrete-target-oses)
          (cond
            ((target-contains? target "windows") "windows")
            ((target-contains? target "linux") "linux")
            ((target-contains? target "darwin") "darwin")
            ((target-contains? target "macos") "macos")
            ((target-contains? target "android") "android")
            ((target-contains? target "freebsd") "freebsd")
            ((target-contains? target "openbsd") "openbsd")
            ((target-contains? target "netbsd") "netbsd")
            ((target-contains? target "wasi") "wasi")
            (else #f)))))

    (define (detect-env parts)
      (let ((env (target-part parts target-envs)))
        (cond
          ((or (equal? env "gnueabi") (equal? env "gnueabihf")) "gnu")
          (env env)
          (else ""))))

    (define (detect-abi parts)
      (let ((abi (target-part parts target-abis)))
        (cond
          ((equal? abi "gnueabi") "eabi")
          ((equal? abi "gnueabihf") "eabihf")
          (abi abi)
          (else ""))))

    (define (detect-vendor parts)
      (if (and (pair? (cdr parts)) (string-member? (car parts) architectures))
        (cadr parts)
        #f))

    (define (target-family-options os arch)
      (cond
        ((or (string=? arch "wasm32") (string=? arch "wasm64"))
          '((target-family . "wasm")))
        ((or (not os) (string=? os "unknown")) '())
        ((string=? os "windows")
          '((target-family . "windows") (windows . #t)))
        ((or (string=? os "linux")
           (string=? os "macos")
           (string=? os "ios")
           (string=? os "android")
           (string=? os "freebsd")
           (string=? os "dragonfly")
           (string=? os "openbsd")
           (string=? os "netbsd"))
          '((target-family . "unix") (unix . #t)))
        (else '())))

    (define (pointer-width arch)
      (cond
        ((not arch) #f)
        ((or (string=? arch "x86_64")
           (string=? arch "aarch64")
           (string=? arch "mips64")
           (string=? arch "powerpc64")
           (string=? arch "riscv64")
           (string=? arch "s390x")
           (string=? arch "wasm64"))
          "64")
        (else "32")))

    (define (endian arch)
      (cond
        ((or (not arch) (string=? arch "")) #f)
        ((or (string=? arch "s390x") (string=? arch "powerpc")) "big")
        (else "little")))

    (define (common-atomic-options pointer)
      (append
        '((target-has-atomic . "8")
          (target-has-atomic . "16")
          (target-has-atomic . "32")
          (target-has-atomic . "ptr"))
        (if (and pointer (string=? pointer "64"))
          '((target-has-atomic . "64"))
          '())))

    (define (fallback-condition-options target)
      (let* ((effective (if (and target (not (string=? target "")))
                          target
                          (host-target-string)))
             (parts (string-split effective #\-))
             (arch (detect-arch effective parts))
             (os (detect-os effective parts))
             (env (detect-env parts))
             (abi (detect-abi parts))
             (vendor (detect-vendor parts))
             (ptr (pointer-width arch))
             (end (endian arch)))
        (append
          `((target . ,effective))
          (if arch `((target-arch . ,arch)) '())
          (if os `((target-os . ,os)) '())
          (target-family-options os arch)
          `((target-env . ,env)
            (target-abi . ,abi))
          (if vendor `((target-vendor . ,vendor)) '())
          (if ptr `((target-pointer-width . ,ptr)) '())
          (if end `((target-endian . ,end)) '())
          (common-atomic-options ptr)
          '((panic . "unwind")))))

    (define (command-first-line command fallback)
      (let ((result (capture-command-lines/status command)))
        (if (and (= (car result) 0) (pair? (cadr result)))
          (car (cadr result))
          fallback)))

    (define (host-target-string)
      (let* ((sys (command-first-line "uname -s 2>/dev/null" "unknown"))
             (mach (command-first-line "uname -m 2>/dev/null" "unknown"))
             (arch (normalize-arch mach))
             (os (cond
                   ((string=? sys "Linux") "linux")
                   ((string=? sys "Darwin") "macos")
                   ((string=? sys "FreeBSD") "freebsd")
                   ((string=? sys "OpenBSD") "openbsd")
                   ((string=? sys "NetBSD") "netbsd")
                   (else "unknown"))))
        (string-append (or arch mach) "-unknown-" os)))

    (define (remove-option-name name options)
      (filter
        (lambda (option)
          (not (and (pair? option) (eq? (car option) name))))
        options))

    (define (profile-options profile base)
      (let ((without-debug (remove-option-name 'debug-assertions base)))
        (if (eq? profile 'release)
          without-debug
          (cons (cons 'debug-assertions #t) without-debug))))

    (define (feature-options features)
      (append
        (map (lambda (feature) (cons feature #t)) features)
        (map
          (lambda (feature) (cons 'feature (symbol->string feature)))
          features)))

    (define (symbol-context-options key value)
      (if value
        `((,key . ,(symbol->string value)))
        '()))

    (define (bare-context-options value)
      (if value
        `((,value . #t))
        '()))

    (define (command-context-options scheme dialect profile compile-mode)
      (append
        (bare-context-options scheme)
        (symbol-context-options 'scheme scheme)
        (symbol-context-options 'implementation scheme)
        (bare-context-options dialect)
        (symbol-context-options 'dialect dialect)
        (symbol-context-options 'profile profile)
        (symbol-context-options 'compile-mode compile-mode)))

    (define (context-option-ref items index)
      (let loop ((rest items) (n index))
        (cond
          ((null? rest) #f)
          ((= n 0) (car rest))
          (else (loop (cdr rest) (- n 1))))))

    (define (condition-options target profile features . maybe-context)
      (dedupe-options
        (append
          (profile-options profile (fallback-condition-options target))
          (feature-options features)
          (command-context-options
            (context-option-ref maybe-context 0)
            (context-option-ref maybe-context 1)
            profile
            (context-option-ref maybe-context 2)))))

    (define (condition-key-value-form? pred)
      (and (pair? pred)
        (symbol? (car pred))
        (not (memq (car pred) '(and or all any not condition)))
        (pair? (cdr pred))
        (null? (cddr pred))))

    (define (condition-key-value pred)
      (cadr pred))

    (define (condition-predicate? pred)
      (cond
        ((boolean? pred) #t)
        ((symbol? pred) #t)
        ((not (pair? pred)) #f)
        ((eq? (car pred) 'and)
          (let loop ((items (cdr pred)))
            (or (null? items)
              (and (condition-predicate? (car items)) (loop (cdr items))))))
        ((eq? (car pred) 'or)
          (let loop ((items (cdr pred)))
            (or (null? items)
              (and (condition-predicate? (car items)) (loop (cdr items))))))
        ((eq? (car pred) 'not)
          (and (pair? (cdr pred))
            (null? (cddr pred))
            (condition-predicate? (cadr pred))))
        ((condition-key-value-form? pred) #t)
        (else #f)))

    (define (condition-predicate-true? pred options)
      (cond
        ((eq? pred #t) #t)
        ((eq? pred #f) #f)
        ((eq? pred 'true) #t)
        ((eq? pred 'false) #f)
        ((symbol? pred) (condition-option-active? options pred))
        ((and (pair? pred) (eq? (car pred) 'and))
          (let loop ((items (cdr pred)))
            (or (null? items)
              (and (condition-predicate-true? (car items) options)
                (loop (cdr items))))))
        ((and (pair? pred) (eq? (car pred) 'or))
          (let loop ((items (cdr pred)))
            (and (pair? items)
              (or (condition-predicate-true? (car items) options)
                (loop (cdr items))))))
        ((and (pair? pred) (eq? (car pred) 'not) (pair? (cdr pred)))
          (not (condition-predicate-true? (cadr pred) options)))
        ((condition-key-value-form? pred)
          (condition-option-active? options (car pred) (condition-key-value pred)))
        (else #f)))))
