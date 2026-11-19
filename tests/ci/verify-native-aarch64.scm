;;;; End-to-end native AArch64 runtime & compiler verification suite

(declare (usual-integrations))

(define object-datum (make-primitive-procedure 'object-datum 1))

(define (check label pred)
  (if (not pred)
      (error "Verification check failed:" label)))

(define (check-equal label actual expected)
  (if (not (equal? actual expected))
      (error "Verification check failed:" label 'actual: actual 'expected: expected)))

(define (get-ci-tmpdir)
  (let ((dir (get-environment-variable "SCM_CI_TMPDIR")))
    (if (or (not dir) (string-null? dir))
        (error "SCM_CI_TMPDIR environment variable must be set"))
    (if (char=? (string-ref dir (- (string-length dir) 1)) #\/)
        dir
        (string-append dir "/"))))

(define scratch-dir (get-ci-tmpdir))

(display "=== [0/5] Native AArch64 architecture identification ===\n")
(check-equal 'compiled-code-type microcode-id/compiled-code-type 'aarch64)
(display "    [0/5] OK\n")

(display "=== [1/5] Dynamic eval, closures, lexprs, apply, primitives, unbound traps ===\n")
(check-equal 'dynamic-eval
             (eval '(let ((x 21)) (+ x x)) user-initial-environment)
             42)

(let ((sq (compile-procedure (lambda (x) (* x x)))))
  (check 'compiled-in-code-arena (code-address? sq))
  (check-equal 'compile-procedure-sq (sq 12) 144))

(let* ((mk-counter
        (compile-procedure
         (lambda (start)
           (let ((n start))
             (lambda (delta)
               (set! n (+ n delta))
               n)))))
       (c1 (mk-counter 10))
       (c2 (mk-counter 100)))
  (check 'closure-type (compiled-closure? c1))
  (check-equal 'closure-c1-a (c1 5) 15)
  (check-equal 'closure-c1-b (c1 7) 22)
  (check-equal 'closure-c2 (c2 23) 123))

(let ((lexpr (compile-procedure
              (lambda (a b . rest)
                (list a b (length rest) (apply + rest))))))
  (check-equal 'lexpr-2 (lexpr 1 2) '(1 2 0 0))
  (check-equal 'lexpr-4 (lexpr 1 2 3 4) '(1 2 2 7))
  (check-equal 'lexpr-apply (apply lexpr '(10 20 1 2 3 4 5)) '(10 20 5 15)))

(let ((tramp-apply
       (compile-procedure
        (lambda (f v i xs)
          (list (apply f (list v i))
                (apply + xs))))))
  (check-equal 'primitive-and-apply-trampolines
               (tramp-apply vector-ref '#(a b c d) 2 '(1 2 3 4 5 6 7 8 9 10))
               '(c 55)))

;; Unbound operator lookup trap + store-value restart inside compiled code.
(let* ((trap-caller
        (compile-procedure
         (lambda (x y)
           (unassigned-test-op-xyz x y))))
       (hit-trap? #f)
       (res
        (bind-condition-handler
            (list condition-type:unbound-variable)
            (lambda (cond)
              (set! hit-trap? #t)
              (store-value (compile-procedure (lambda (a b) (+ (* 100 a) b)))
                           cond))
          (lambda ()
            (trap-caller 3 7)))))
  (check 'unbound-trap-fired hit-trap?)
  (check-equal 'unbound-trap-restarted res 307)
  (check-equal 'unbound-trap-linked-after (trap-caller 4 5) 405))
(display "    [1/5] OK\n")

(display "=== [2/5] Far UUO link (>128 MiB) & compiled compile-file execution ===\n")
(let* ((caller-scm (string-append scratch-dir "far_caller_tmp.scm"))
       (callee-scm (string-append scratch-dir "far_callee_tmp.scm"))
       (env (make-top-level-environment))
       (make-dummy-code-block
        (lambda (nw)
          (let ((bv (make-vector nw #f)))
            ((make-primitive-procedure 'vector-set! 3)
             bv 0
             ((make-primitive-procedure 'primitive-object-set-type 2)
              (microcode-type 'manifest-nm-vector)
              (- nw 1)))
            (install-compiled-code-block bv)))))
  (call-with-output-file caller-scm
    (lambda (p)
      (write-string "(define (far-caller x) (far-callee (+ x 1)))\n" p)))
  (call-with-output-file callee-scm
    (lambda (p)
      (write-string "(define (far-callee y) (+ (* y 7) 2))\n" p)
      (do ((k 0 (+ k 1)))
          ((= k 80))
        (write-string "(define (far-pad-" p)
        (display k p)
        (write-string " a b) (+ a (* b " p)
        (display (+ k 3) p)
        (write-string ")))\n" p))))
  (compile-file caller-scm)
  (compile-file callee-scm)
  (load (string-append scratch-dir "far_caller_tmp.com") env)
  ;; Sweep any compiler temps, then allocate ~144 MiB of 8 MiB spacer blocks
  ;; (collecting each temporary heap vector right away so default --heap suffices)
  ;; and plug pre-spacer holes so loading far_callee_tmp.com lands >128 MiB away.
  (gc-flip)
  (let ((spacers '())
        (plugs '()))
    (do ((i 0 (+ i 1)))
        ((= i 18))
      (let ((s (make-dummy-code-block 1000000)))
        (check 'spacer-in-code-arena (code-address? s))
        (set! spacers (cons s spacers))
        (gc-flip)))
    (let ((top-spacer (car spacers)))
      (let loop ()
        (let ((d (make-dummy-code-block 512)))
          (set! plugs (cons d plugs))
          (if (<= (object-datum d) (object-datum top-spacer))
              (loop)))))
    (load (string-append scratch-dir "far_callee_tmp.com") env)
    (let* ((caller-proc (environment-lookup env 'far-caller))
           (callee-proc (environment-lookup env 'far-callee))
           (dist (abs (- (object-datum callee-proc)
                         (object-datum caller-proc)))))
      (display "    caller=") (display (number->string (object-datum caller-proc) 16))
      (display " callee=") (display (number->string (object-datum callee-proc) 16))
      (display " dist=") (display dist) (newline)
      (check 'far-uuo-dist->128mb (> dist #x8000000))
      ;; First call links UUO cache with br x1; subsequent calls execute patched UUO link.
      (check-equal 'far-uuo-call-1 ((environment-lookup env 'far-caller) 10) 79)
      (check-equal 'far-uuo-call-2 ((environment-lookup env 'far-caller) 20) 149)
      (check-equal 'far-uuo-call-3 ((environment-lookup env 'far-caller) 0) 9))
    ;; Clear strong references so gc-flip below reclaims spacers and plugs.
    (set! plugs #f)
    (set! spacers #f)))
(gc-flip)
(display "    [2/5] OK\n")

(display "=== [3/5] Repeated compile + compile-file + gc-flip mark-sweep reclamation ===\n")
(let ((scratch-scm (string-append scratch-dir "loop_test_tmp.scm"))
      (scratch-com (string-append scratch-dir "loop_test_tmp.com")))
  (call-with-output-file scratch-scm
    (lambda (p)
      (write-string "(define (loop-fn x) (+ (* x x) 17))\n" p)))
  (let ((after-warmup #f)
        (after-50 #f))
    (do ((i 0 (+ i 1)))
        ((= i 50))
      (let ((p (compile-procedure (lambda (x y) (+ (* x i) y)))))
        (check-equal 'loop-proc (p 3 4) (+ (* 3 i) 4)))
      (if (= (remainder i 10) 0)
          (begin
            (compile-file scratch-scm)
            (let ((e (make-top-level-environment)))
              (load scratch-com e)
              (check-equal 'loop-load ((environment-lookup e 'loop-fn) 5) 42))))
      (gc-flip)
      (if (= i 10)
          (set! after-warmup (cdr (code-space-bounds))))
      (if (= i 49)
          (set! after-50 (cdr (code-space-bounds)))))
    (display "    code_alloc_next warmup=") (display after-warmup)
    (display " after-50=") (display after-50) (newline)
    ;; Must stay bounded (mark-sweep reclaims freed blocks & retracts tail / reuses holes).
    (check 'code-arena-reclaimed (< (- after-50 after-warmup) 65536))))
(display "    [3/5] OK\n")

(display "=== [4/5] Weak pairs & ephemerons keyed by dynamically compiled procedures ===\n")
(define (make-weak-and-ephem-live)
  (let* ((p1 (compile-procedure (lambda (x) (+ x 11))))
         (p2 (compile-procedure (lambda (x) (+ x 22))))
         (wp (weak-cons p1 'weak-datum))
         (ep (make-ephemeron p2 (list 'ephem-datum p2))))
    (check 'weak-live-before-gc (weak-pair/car? wp))
    (check-equal 'weak-car-before ((weak-car wp) 5) 16)
    (check 'ephem-live-before-gc (not (ephemeron-broken? ep)))
    (check 'ephem-datum-before (pair? (ephemeron-datum ep)))
    ;; Keep p1/p2 alive across a GC while referenced:
    (gc-flip)
    (check 'weak-still-live-with-ref (weak-pair/car? wp))
    (check 'ephem-still-live-with-ref (not (ephemeron-broken? ep)))
    (cons wp ep)))

(let* ((refs (make-weak-and-ephem-live))
       (wp (car refs))
       (ep (cdr refs)))
  ;; Overwrite registers/stack via a deep non-tail sum before GC so p1/p2 aren't pinned in stale frames.
  (letrec ((burn (lambda (n) (if (= n 0) 0 (+ 1 (burn (- n 1)))))))
    (check-equal 'burn (burn 500) 500))
  (gc-flip)
  (check 'weak-cleared-after-gc (not (weak-pair/car? wp)))
  (check 'ephem-broken-after-gc (ephemeron-broken? ep)))
(display "    [4/5] OK\n")

(display "=== [5/5] copy-program on compiled expression ===\n")
(let ((src-scm (string-append scratch-dir "copy_prog_tmp.scm"))
      (src-com (string-append scratch-dir "copy_prog_tmp.com")))
  (call-with-output-file src-scm
    (lambda (p)
      (write-string "(lambda (n) (+ (* n 10) 5))\n" p)))
  (compile-file src-scm)
  (let* ((orig (fasload src-com #t))
         (orig-expr (if (scode-comment? orig) (scode-comment-expression orig) orig))
         (copied (copy-program orig-expr))
         (copied-block (compiled-code-address->block copied))
         (orig-block (compiled-code-address->block orig-expr)))
    (check 'orig-is-cc (compiled-code-address? orig-expr))
    (check 'copied-is-cc (compiled-code-address? copied))
    (check 'copied-in-code-arena (code-address? copied-block))
    (check 'copied-distinct-block (not (eq? copied-block orig-block)))
    (let ((fn (scode-eval copied (make-top-level-environment))))
      (check-equal 'copy-program-eval (fn 8) 85))))
(display "    [5/5] OK\n")
(display "ALL_VERIFY_NATIVE_OK\n")
