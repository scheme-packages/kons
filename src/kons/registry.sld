(define-library (kons registry)
  (export default-registry-alias
          default-registry-url
          registries-path
          credentials-path
          registry-source-root
          registry-archive-path
          registry-package-root
          registry-package-source-root
          registry-ref
          registry-token
          registry-url
          registry-name->url
          registry-list
          write-registry-list!
          registry-add!
          registry-remove!
          registry-default!
          registry-login!
          registry-logout!
          resolve-registry-version
          download-registry-package!
          registry-http-json
          registry-http-json/token
          registry-http-upload
          registry-http-upload/token
          registry-http-action
          registry-http-action/token
          json-string)
  (import (scheme base)
          (scheme file)
          (scheme process-context)
          (kons util)
          (kons names)
          (kons manifest))

  (begin
(define default-registry-alias "default")
(define default-registry-url "https://kons.playxe.org")

(define json-field-code
  "const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
let value = data;

for (const key of process.argv[2].split('.')) {
  value = value?.[key];
}

if (value === undefined || value === null) process.exit(2);
if (typeof value === 'object') console.log(JSON.stringify(value));
else console.log(String(value));")

(define registry-error-message-code
  "const fs = require('fs');
const text = fs.existsSync(process.argv[1])
  ? fs.readFileSync(process.argv[1], 'utf8')
  : '';
let data = null;

try {
  data = JSON.parse(text);
} catch {}

if (!data) {
  console.log(text.trim() || 'registry request failed');
  process.exit(0);
}

const lines = [];
lines.push(data.message || data.error || 'registry request failed');

const fields = data.details && data.details.fields;
if (Array.isArray(fields)) {
  for (const field of fields) {
    lines.push(`${field.field}: ${field.message}`);
  }
} else if (data.details) {
  lines.push(JSON.stringify(data.details));
}

console.log(lines.join('\\n'));")

(define url-encode-code
  "console.log(
  encodeURIComponent(process.argv[1])
);")

(define json-string-code
  "process.stdout.write(
  JSON.stringify(process.argv[1])
);")

(define (registry-config-root)
  (path-join (kons-home) "config"))

(define (registries-path)
  (path-join (registry-config-root) "registries.scm"))

(define (credentials-path)
  (path-join (kons-home) "credentials.scm"))

(define (ensure-private-root!)
  (run-command (string-append "mkdir -p " (shell-quote (registry-config-root))))
  (run-command (string-append "mkdir -p " (shell-quote (kons-home)))))

(define (read-one-expr path default)
  (if (file-exists? path)
      (let ((exprs (read-all-exprs path)))
        (if (null? exprs) default (car exprs)))
      default))

(define (registry-list)
  (let ((expr (read-one-expr (registries-path) '(registries))))
    (if (and (pair? expr) (eq? (car expr) 'registries))
        (cdr expr)
        '())))

(define (credentials-list)
  (let ((expr (read-one-expr (credentials-path) '(credentials))))
    (if (and (pair? expr) (eq? (car expr) 'credentials))
        (cdr expr)
        '())))

(define (write-registry-list! registries)
  (ensure-private-root!)
  (write-expr-file (registries-path) (cons 'registries registries)))

(define (write-credentials-list! credentials)
  (ensure-private-root!)
  (write-expr-file (credentials-path) (cons 'credentials credentials))
  (run-command (string-append "chmod 600 " (shell-quote (credentials-path)))))

(define (entry-field entry key default)
  (field-ref (cdr entry) key default))

(define (registry-entry-name entry)
  (entry-field entry 'name ""))

(define (registry-entry-url entry)
  (entry-field entry 'url ""))

(define (registry-entry-default? entry)
  (entry-field entry 'default #f))

(define (find-registry-entry name)
  (let loop ((items (registry-list)))
    (cond
     ((null? items) #f)
     ((and (pair? (car items))
           (eq? (caar items) 'registry)
           (string=? (registry-entry-name (car items)) name))
      (car items))
     (else (loop (cdr items))))))

(define (default-registry-entry)
  (let loop ((items (registry-list)))
    (cond
     ((null? items) #f)
     ((and (pair? (car items))
           (eq? (caar items) 'registry)
           (registry-entry-default? (car items)))
      (car items))
     (else (loop (cdr items))))))

(define (registry-name->url name)
  (cond
   ((or (not name) (string=? name "") (string=? name default-registry-alias))
    (or (get-environment-variable "KONS_REGISTRY")
        (let ((entry (or (default-registry-entry)
                         (find-registry-entry default-registry-alias))))
          (if entry (registry-entry-url entry) default-registry-url))))
   ((or (string-prefix? "http://" name)
        (string-prefix? "https://" name))
    name)
   (else
    (let ((entry (find-registry-entry name)))
      (unless entry (dependency-error "unknown registry" name))
      (registry-entry-url entry)))))

(define (string-prefix? prefix s)
  (let ((plen (string-length prefix))
        (slen (string-length s)))
    (and (>= slen plen)
         (string=? prefix (substring s 0 plen)))))

(define (registry-url registry)
  (registry-name->url registry))

(define (without-trailing-slash s)
  (let ((len (string-length s)))
    (if (and (> len 0) (char=? (string-ref s (- len 1)) #\/))
        (substring s 0 (- len 1))
        s)))

(define (registry-ref registry)
  (or registry default-registry-alias))

(define (registry-token registry)
  (or (get-environment-variable "KONS_REGISTRY_TOKEN")
      (let ((url (registry-url registry))
            (name (registry-ref registry)))
        (let loop ((items (credentials-list)))
          (cond
           ((null? items) #f)
           ((and (pair? (car items))
                 (eq? (caar items) 'credential)
                 (or (string=? (entry-field (car items) 'registry "") name)
                     (string=? (entry-field (car items) 'url "") url)))
            (entry-field (car items) 'token #f))
           (else (loop (cdr items))))))))

(define (replace-named-entry entries new-entry)
  (let ((name (registry-entry-name new-entry)))
    (let loop ((items entries) (out '()) (done? #f))
      (cond
       ((null? items) (reverse (if done? out (cons new-entry out))))
       ((and (pair? (car items))
             (eq? (caar items) 'registry)
             (string=? (registry-entry-name (car items)) name))
        (loop (cdr items) (cons new-entry out) #t))
       (else (loop (cdr items) (cons (car items) out) done?))))))

(define (clear-default entries)
  (map (lambda (entry)
         (if (and (pair? entry) (eq? (car entry) 'registry))
             `(registry
               (name ,(registry-entry-name entry))
               (url ,(registry-entry-url entry))
               (default #f))
             entry))
       entries))

(define (registry-add! name url default?)
  (write-registry-list!
   (replace-named-entry
    (if default? (clear-default (registry-list)) (registry-list))
    `(registry (name ,name) (url ,(without-trailing-slash url)) (default ,default?)))))

(define (registry-remove! name)
  (write-registry-list!
   (filter (lambda (entry)
             (not (and (pair? entry)
                       (eq? (car entry) 'registry)
                       (string=? (registry-entry-name entry) name))))
           (registry-list))))

(define (registry-default! name)
  (let ((entry (find-registry-entry name)))
    (unless entry (dependency-error "unknown registry" name))
    (write-registry-list!
     (replace-named-entry
      (clear-default (registry-list))
      `(registry (name ,name) (url ,(registry-entry-url entry)) (default #t))))))

(define (replace-credential credentials new-entry)
  (let ((name (entry-field new-entry 'registry "")))
    (let loop ((items credentials) (out '()) (done? #f))
      (cond
       ((null? items) (reverse (if done? out (cons new-entry out))))
       ((and (pair? (car items))
             (eq? (caar items) 'credential)
             (string=? (entry-field (car items) 'registry "") name))
        (loop (cdr items) (cons new-entry out) #t))
       (else (loop (cdr items) (cons (car items) out) done?))))))

(define (registry-login! registry token)
  (let ((name (registry-ref registry)))
    (write-credentials-list!
     (replace-credential
      (credentials-list)
      `(credential
        (registry ,name)
        (url ,(registry-url name))
        (token ,token))))))

(define (registry-logout! registry)
  (let ((name (registry-ref registry)))
    (write-credentials-list!
     (filter (lambda (entry)
               (not (and (pair? entry)
                         (eq? (car entry) 'credential)
                         (string=? (entry-field entry 'registry "") name))))
             (credentials-list)))))

(define (registry-source-root)
  (path-join (kons-store-root) "registry"))

(define (registry-archive-path registry name version checksum)
  (path-join
   (path-join
    (path-join (registry-source-root) "archives")
    (safe-store-token (registry-url registry)))
   (string-append
    (safe-store-token name)
    "-"
    (safe-store-token version)
    "-"
    (safe-store-token checksum)
    ".kons")))

(define (registry-package-root registry name version checksum)
  (path-join
   (path-join
    (path-join (registry-source-root) "sources")
    (safe-store-token (registry-url registry)))
   (string-append
    (safe-store-token name)
    "-"
    (safe-store-token version)
    "-"
    (safe-store-token checksum))))

(define (registry-package-source-root registry name version checksum)
  (let* ((root (registry-package-root registry name version checksum))
         (manifest-path (path-join root "kons.scm")))
    (unless (file-exists? manifest-path)
      (dependency-error "registry dependency is not materialized; run `kons fetch` first" name version))
    (let ((manifest (parse-manifest manifest-path)))
      (path-join root (package-source-path manifest)))))

(define (node-json-field file path)
  (capture-first-line
   (string-append
    "node -e "
    (shell-quote json-field-code)
    " "
    (shell-quote file)
    " "
    (shell-quote path))))

(define (registry-response-error-message file)
  (capture-first-line
   (string-append
    "node -e "
    (shell-quote registry-error-message-code)
    " "
    (shell-quote file))))

(define (http-success-status? status)
  (and (>= status 200) (< status 300)))

(define (delete-temp-file path)
  (when (file-exists? path)
    (delete-file path)))

(define (registry-http-request method registry path body-file explicit-token)
  (let ((body (temporary-file-path "registry-response.json"))
        (code (temporary-file-path "registry-status.txt")))
    (let ((status
           (shell-command-status
            (string-append
             "curl -sSL -X "
             (shell-quote method)
             (curl-auth-header/token registry explicit-token)
             (if body-file
                 (string-append
                  " -H " (shell-quote "Content-Type: application/json")
                  " --data-binary @"
                  (shell-quote body-file))
                 "")
             " -w " (shell-quote "%{http_code}")
             " -o " (shell-quote body)
             " "
             (shell-quote (http-url registry path))
             " > " (shell-quote code)))))
      (unless (= status 0)
        (dependency-error "registry request failed" (http-url registry path)))
      (let ((http-code (string->number (call-with-input-file code read-line))))
        (delete-temp-file code)
        (if (and http-code (http-success-status? http-code))
            body
            (let ((message (registry-response-error-message body)))
              (delete-temp-file body)
              (dependency-error message (http-url registry path) (if http-code http-code "unknown"))))))))

(define (curl-auth-header/token registry explicit-token)
  (let ((token (or explicit-token (registry-token registry))))
    (if token
        (string-append " -H " (shell-quote (string-append "Authorization: Bearer " token)))
        "")))

(define (curl-auth-header registry)
  (curl-auth-header/token registry #f))

(define (http-url registry path)
  (string-append (without-trailing-slash (registry-url registry)) path))

(define (registry-http-json/token registry path explicit-token)
  (registry-http-request "GET" registry path #f explicit-token))

(define (registry-http-json registry path)
  (registry-http-json/token registry path #f))

(define (registry-http-action/token method registry path explicit-token)
  (delete-temp-file
   (registry-http-request method registry path #f explicit-token)))

(define (registry-http-action method registry path)
  (registry-http-action/token method registry path #f))

(define (registry-http-upload/token registry path json-file explicit-token)
  (delete-temp-file
   (registry-http-request "PUT" registry path json-file explicit-token)))

(define (registry-http-upload registry path json-file)
  (registry-http-upload/token registry path json-file #f))

(define (url-encode s)
  (capture-first-line
   (string-append
    "node -e "
    (shell-quote url-encode-code)
    " "
    (shell-quote s))))

(define (resolve-registry-version dep)
  (let* ((registry (registry-ref (alist-ref dep 'registry #f)))
         (name (name->string (alist-ref dep 'name '())))
         (req (alist-ref dep 'version "*"))
         (json (registry-http-json
                registry
                (string-append "/api/v1/packages/"
                               (url-encode name)
                               "/resolve?req="
                               (url-encode req))))
         (version (node-json-field json "version"))
         (checksum (node-json-field json "package.latest.checksum"))
         (download (string-append (without-trailing-slash (registry-url registry))
                                  "/api/v1/packages/"
                                  name
                                  "/"
                                  version
                                  "/download")))
    `((version . ,version)
      (checksum . ,checksum)
      (download . ,download)
      (registry . ,registry))))

(define (download-registry-package! registry name version checksum download offline?)
  (let* ((archive (registry-archive-path registry name version checksum))
         (root (registry-package-root registry name version checksum)))
    (cond
     ((file-exists? root) root)
     (offline? (dependency-error "registry dependency cache is missing and offline/frozen mode is active" name version))
     (else
      (run-command (string-append "mkdir -p " (shell-quote (dirname archive))))
      (unless (file-exists? archive)
        (run-command
         (string-append "curl -fsSL " (shell-quote download) " -o " (shell-quote archive))))
      (let ((actual (capture-first-line
                     (string-append "sha256sum " (shell-quote archive) " | awk '{print $1}'"))))
        (unless (string=? actual checksum)
          (dependency-error "registry archive checksum mismatch" name version checksum actual)))
      (run-command (string-append "rm -rf " (shell-quote root)))
      (run-command (string-append "mkdir -p " (shell-quote root)))
      (run-command
       (string-append "tar -xf " (shell-quote archive) " -C " (shell-quote root)))
      root))))

(define (json-string value)
  (capture-first-line
   (string-append
    "node -e "
    (shell-quote json-string-code)
    " "
    (shell-quote value))))

  ))
