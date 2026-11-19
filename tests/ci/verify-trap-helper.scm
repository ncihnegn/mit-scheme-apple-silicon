;;;; Hardware SIGSEGV trap recovery and (code space) frame helper

(declare (usual-integrations))

(define (trigger-forged-vector-trap addr)
  (let ((bad ((ucode-primitive primitive-object-set-type 2)
              (ucode-type vector)
              addr)))
    (vector-ref bad 0)))
