(define-library (kons actions registry)
  (export cmd-registry
          cmd-login
          cmd-logout
          cmd-search
          cmd-info
          cmd-yank
          cmd-unyank
          cmd-owner)
  (import (scheme base)
          (scheme process-context)
          (scheme write)
          (kons util)
          (kons names)
          (kons manifest)
          (kons options)
          (kons registry))

  (begin
(define (registry-option cmd)
  (or (command-string-option cmd "index")
      (command-string-option cmd "registry")
      default-registry-alias))

(define (token-option cmd)
  (command-string-option cmd "token"))

(define (command-string-option cmd name)
  (let ((value (command-option cmd name #f)))
    (if (string? value) value #f)))

(define (second xs) (car (cdr xs)))
(define (third xs) (car (cdr (cdr xs))))

(define (string-join xs sep)
  (let loop ((rest xs) (out ""))
    (cond
     ((null? rest) out)
     ((string=? out "") (loop (cdr rest) (car rest)))
     (else (loop (cdr rest) (string-append out sep (car rest)))))))

(define url-encode-code
  "console.log(
  encodeURIComponent(process.argv[1])
);")

(define registry-index-api-code
  "const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));

if (!data.api) process.exit(2);
console.log(data.api);")

(define search-results-code
  "const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const packages = data.packages || [];

if (!packages.length) {
  console.log('No packages found.');
  process.exit(0);
}

for (const [index, p] of packages.entries()) {
  const version = p.latest?.version ? `v${p.latest.version}` : 'unpublished';
  const description = p.description || 'No description';
  const owners = (p.owners || []).map((o) => o.username).filter(Boolean);
  const keywords = (p.keywords || []).slice(0, 6);
  const links = [
    p.repository || p.repo ? `repo ${p.repository || p.repo}` : '',
    p.homepage || p.site ? `site ${p.homepage || p.site}` : '',
    p.documentation || p.docs ? `docs ${p.documentation || p.docs}` : '',
  ].filter(Boolean);
  const meta = [
    owners.length ? `by ${owners.join(', ')}` : '',
    keywords.length ? `#${keywords.join(' #')}` : '',
  ].filter(Boolean).join('  ');

  if (index) console.log('');
  console.log(`${p.name}  ${version}`);
  console.log(`  ${description}`);
  if (meta) console.log(`  ${meta}`);
  for (const link of links) console.log(`  ${link}`);
}")

(define package-info-code
  "const fs = require('fs');
const p = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).package;

console.log(`${p.name} ${p.latest?.version || ''}`);
if (p.description) console.log(p.description);
if (p.repository) console.log(`repository: ${p.repository}`);

const versions = (p.versions || [])
  .map((v) => `${v.version}${v.yanked ? ' (yanked)' : ''}`)
  .join(', ');
console.log(`versions: ${versions}`);")

(define owner-list-code
  "const fs = require('fs');
const p = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).package;

for (const o of p.owners || []) {
  console.log(`${o.username} ${o.displayName || ''}`);
}")

(define (default-package-name cmd)
  (name->string (package-name (parse-manifest (command-manifest-path cmd)))))

(define (string-index s ch)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (cond
       ((= i len) #f)
       ((char=? (string-ref s i) ch) i)
       (else (loop (+ i 1)))))))

(define (rest-strings cmd)
  (filter string? (command-rest cmd)))

(define (first-rest cmd label)
  (let ((items (rest-strings cmd)))
    (if (pair? items)
        (car items)
        (usage-error (string-append label " requires an argument")))))

(define (second-rest cmd label)
  (let ((items (rest-strings cmd)))
    (if (and (pair? items) (pair? (cdr items)))
        (second items)
        (usage-error (string-append label " requires another argument")))))

(define (url-encode s)
  (capture-first-line
    (string-append
    "node -e "
    (shell-quote url-encode-code)
    " "
    (shell-quote s))))

(define (display-registry-entry entry)
  (display (field-ref (cdr entry) 'name ""))
  (display " ")
  (display (field-ref (cdr entry) 'url ""))
  (when (field-ref (cdr entry) 'default #f)
    (display " (default)"))
  (newline))

(define (cmd-registry cmd)
  (let ((items (rest-strings cmd)))
    (if (null? items)
        (usage-error "registry requires a subcommand: list, add, remove, default, index")
        (let ((action (car items)))
          (cond
           ((string=? action "list")
            (let ((items (registry-list)))
              (if (null? items)
                  (displayln "no registries configured")
                  (for-each display-registry-entry items))))
           ((string=? action "add")
            (unless (and (pair? (cdr items)) (pair? (cdr (cdr items))))
              (usage-error "registry add requires NAME URL"))
            (registry-add! (second items) (third items) (command-flag? cmd "default"))
            (displayln "registry added"))
           ((string=? action "remove")
            (unless (pair? (cdr items)) (usage-error "registry remove requires NAME"))
            (registry-remove! (second items))
            (displayln "registry removed"))
           ((string=? action "default")
            (unless (pair? (cdr items)) (usage-error "registry default requires NAME"))
            (registry-default! (second items))
            (displayln "default registry updated"))
           ((string=? action "index")
            (unless (pair? (cdr items)) (usage-error "registry index requires INDEX-URL"))
            (let* ((index-url (second items))
                   (name (if (pair? (cdr (cdr items))) (third items) default-registry-alias))
                   (json (registry-http-json index-url ""))
                   (api (capture-first-line
                         (string-append
                          "node -e "
                          (shell-quote registry-index-api-code)
                          " "
                          (shell-quote json)))))
              (registry-add! name api (command-flag? cmd "default"))
              (display "registry indexed ")
              (display name)
              (display " ")
              (displayln api)))
           (else (usage-error "unknown registry subcommand" action)))))))

(define (cmd-login cmd)
  (let* ((registry (registry-option cmd))
         (token (or (command-option cmd "token" #f)
                    (get-environment-variable "KONS_REGISTRY_TOKEN")
                    (first-rest cmd "login"))))
    (registry-login! registry token)
    (display "logged in to ")
    (displayln registry)))

(define (cmd-logout cmd)
  (let ((registry (registry-option cmd)))
    (registry-logout! registry)
    (display "logged out of ")
    (displayln registry)))

(define (cmd-search cmd)
  (let* ((query (string-join (rest-strings cmd) " "))
         (registry (registry-option cmd))
         (limit (command-string-option cmd "limit"))
         (json (registry-http-json registry
                                   (string-append "/api/v1/search?q="
                                                  (url-encode query)
                                                  (if limit
                                                      (string-append "&per_page=" (url-encode limit))
                                                      "")))))
    (when (string=? query "")
      (usage-error "search requires a query"))
    (run-command (string-append "node -e "
                                (shell-quote search-results-code)
                                " "
                                (shell-quote json)))))

(define (cmd-info cmd)
  (let* ((name (first-rest cmd "info"))
         (registry (registry-option cmd))
         (json (registry-http-json registry
                                   (string-append "/api/v1/packages/" (url-encode name)))))
    (run-command (string-append "node -e "
                                (shell-quote package-info-code)
                                " "
                                (shell-quote json)))))

(define (yank-parts cmd unyank?)
  (let* ((items (rest-strings cmd))
         (first (and (pair? items) (car items)))
         (at (and first (string-index first #\@)))
         (version (or (command-string-option cmd "version")
                      (command-string-option cmd "vers")
                      (and at (substring first (+ at 1) (string-length first)))
                      (and (pair? items) (pair? (cdr items)) (second items)))))
    (unless version
      (usage-error (string-append (if unyank? "unyank" "yank") " requires a version")))
    (cons (cond
           (at (substring first 0 at))
           (first first)
           (else (default-package-name cmd)))
          version)))

(define (cmd-yank* cmd unyank?)
  (let* ((parts (yank-parts cmd unyank?))
         (name (car parts))
         (version (cdr parts))
         (registry (registry-option cmd)))
    (registry-http-action/token
     (if unyank? "PUT" "DELETE")
     registry
     (string-append "/api/v1/packages/" name "/" version "/" (if unyank? "unyank" "yank"))
     (token-option cmd))
    (display (if unyank? "unyanked " "yanked "))
    (display name)
    (display " ")
    (displayln version)))

(define (cmd-yank cmd) (cmd-yank* cmd (command-flag? cmd "undo")))
(define (cmd-unyank cmd) (cmd-yank* cmd #t))

(define (cmd-owner cmd)
  (let* ((items (rest-strings cmd))
         (flag-add (command-string-option cmd "add"))
         (flag-remove (command-string-option cmd "remove"))
         (legacy-action (and (pair? items) (car items)))
         (action (cond
                  (flag-add "add")
                  (flag-remove "remove")
                  (legacy-action legacy-action)
                  (else "list")))
         (name (cond
                ((or flag-add flag-remove)
                 (if (pair? items) (car items) (usage-error "owner add/remove requires package name")))
                ((pair? (cdr items)) (second items))
                ((string=? action "list") (usage-error "owner list requires package name"))
                (else (usage-error "owner add/remove requires package name"))))
         (user (cond
                (flag-add flag-add)
                (flag-remove flag-remove)
                ((pair? (cdr (cdr items))) (third items))
                (else #f)))
         (registry (registry-option cmd)))
    (cond
     ((string=? action "list")
      (let ((json (registry-http-json registry
                                      (string-append "/api/v1/packages/" (url-encode name)))))
        (run-command (string-append "node -e "
                                    (shell-quote owner-list-code)
                                    " "
                                    (shell-quote json)))))
     ((or (string=? action "add") (string=? action "remove"))
      (unless user (usage-error "owner add/remove requires username"))
      (registry-http-action/token
       (if (string=? action "add") "PUT" "DELETE")
       registry
       (string-append "/api/v1/packages/" name "/owners/" user)
       (token-option cmd))
      (displayln "owner updated"))
     (else (usage-error "unknown owner subcommand" action)))))

  ))
