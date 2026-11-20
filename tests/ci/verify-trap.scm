;;;; Hardware SIGSEGV trap recovery & (code space) frame verification driver

(declare (usual-integrations))

(define (get-ci-tmpdir)
  (let ((dir (get-environment-variable "SCM_CI_TMPDIR")))
    (if (or (not dir) (string-null? dir))
        (error "SCM_CI_TMPDIR environment variable must be set"))
    (if (char=? (string-ref dir (- (string-length dir) 1)) #\/)
        dir
        (string-append dir "/"))))

(let* ((tmp-dir (get-ci-tmpdir))
       (helper-src
        (merge-pathnames "verify-trap-helper.scm"
                         (directory-pathname (current-load-pathname))))
       (trap-scm (string-append tmp-dir "trap_helper.scm"))
       (trap-com (string-append tmp-dir "trap_helper.com"))
       (env (extend-top-level-environment (->environment '(runtime microcode-data)))))
  (copy-file helper-src trap-scm)
  (compile-file trap-scm '() (->environment '(runtime microcode-data)))
  (load trap-com env)
  (let ((trap-report #f))
    (call-with-current-continuation
     (lambda (escape)
       (bind-condition-handler
           (list condition-type:hardware-trap)
           (lambda (condition)
             (let* ((cp-env (->environment '(runtime continuation-parser)))
                    (me-env (->environment '(runtime microcode-errors)))
                    (k (condition/continuation condition))
                    (frame ((access continuation/first-subproblem me-env) k))
                    (expr ((access cframe-dbg-expression cp-env) frame))
                    (dbg-printer-apply (access dbg-printer-apply cp-env))
                    (out
                     (call-with-output-string
                       (lambda (port)
                         (dbg-printer-apply expr #t port)))))
               (set! trap-report (list (condition/report-string condition) out))
               (escape #t)))
         (lambda ()
           ((environment-lookup env 'trigger-forged-vector-trap) #x100)))))
    (if (not trap-report)
        (error "Hardware trap did not fire!"))
    (display "TRAP_CONDITION: ") (display (car trap-report)) (newline)
    (display "TRAP_FRAME:\n") (display (cadr trap-report)) (newline)
    (if (not (substring? "(code space)" (cadr trap-report)))
        (error "Missing (code space) annotation in trap frame!" (cadr trap-report))))
  ;; Verify post-trap recovery: SSP (x28), Free (x20), W^X RX restore, GC.
  (let ((after-fn (compile-procedure (lambda (x y) (+ (* x x) (* y y))))))
    (if (not (= (after-fn 3 4) 25))
        (error "Post-trap compiled procedure failed!"))
    (gc-flip)
    (if (not (= (after-fn 5 12) 169))
        (error "Post-trap GC check failed!")))
  (display "FORGE_TRAP_RECOVERY_OK\n"))
