;; -*- lisp -*-

;; This file is part of STMX.
;; Copyright (c) 2013 Massimiliano Ghilardi
;;
;; This library is free software: you can redistribute it and/or
;; modify it under the terms of the Lisp Lesser General Public License
;; (http://opensource.franz.com/preamble.html), known as the LLGPL.
;;
;; This library is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;; See the Lisp Lesser General Public License for more details.


(in-package :stmx)

;;;; ** Validating


(defun valid? (log)
  "Return t if LOG is valid, i.e. it contains an up-to-date view
of TVARs that were read during the transaction."
  (declare (type tlog log))

  (log.trace "Tlog ~A valid?.." (~ log))
  (do-txhash (var val) (tlog-reads log)
    (if (eq val (raw-value-of var))
        (log.trace "Tlog ~A tvar ~A is up-to-date" (~ log) (~ var))
        (progn
          (log.trace "Tlog ~A conflict for tvar ~A: expecting ~A, found ~A"
                     (~ log) (~ var) val (raw-value-of var))
          (log.debug "Tlog ~A ..not valid" (~ log))
          (return-from valid? nil))))
  (log.trace "Tlog ~A ..is valid" (~ log))
  t)



(defun valid-and-unlocked? (log)
  "Return t if LOG is valid and unlocked, i.e. it contains an up-to-date view
of TVARs that were read during the transaction and none of them is locked
by other threads."
  (declare (type tlog log))

  (log.trace "Tlog ~A valid-and-unlocked?.." (~ log))
  (do-txhash (var val) (tlog-reads log)
    (if (eq val (raw-value-of var))
        (progn
          (log.trace "Tlog ~A tvar ~A is up-to-date" (~ log) (~ var))
          (unless (tvar-unlocked? var log)
            (log.debug "Tlog ~A tvar ~A is locked!" (~ log) (~ var))
            (return-from valid-and-unlocked? nil)))
        (progn
          (log.trace "Tlog ~A conflict for tvar ~A: expecting ~A, found ~A"
                     (~ log) (~ var) val (raw-value-of var))
          (log.debug "Tlog ~A ..not valid" (~ log))
          (return-from valid-and-unlocked? nil))))
  (log.trace "Tlog ~A ..is valid and unlocked" (~ log))
  t)



(declaim (inline invalid? shallow-valid? shallow-invalid?))

(defun invalid? (log)
  "Return (not (valid? LOG))."
  (declare (type tlog log))
  (not (valid? log)))




(defun shallow-valid? (log)
  "Return T if a TLOG is valid. Similar to (valid? log),
but does *not* check log parents for validity."
  (declare (type tlog log))
  ;; current implementation always performs a deep validation
  (valid? log))
  

(declaim (inline shallow-invalid?))
(defun shallow-invalid? (log)
  "Return (not (shallow-valid? LOG))."
  (declare (type tlog log))
  (not (shallow-valid? log)))


(declaim (ftype (function (tvar tvar) (values boolean &optional)) tvar>))

(defun tvar> (var1 var2)
  (declare (type tvar var1 var2))
  "Compare var1 and var2 with respect to age: newer tvars usually have larger
tvar-id and are considered \"larger\". Returns (> (tvar-id var1) (tvar-id var2))."
  (> (the fixnum (tvar-id var1))
     (the fixnum (tvar-id var2)))
  #+never
  (< (the fixnum (sb-impl::get-lisp-obj-address var1))
     (the fixnum (sb-impl::get-lisp-obj-address var2)))
  #+never
  (< (the fixnum (sxhash var1))
     (the fixnum (sxhash var2))))




(defmacro try-lock-tvars (txhash-vars locked-n)
  "Optionally sort VARS in (tvar> ...) order,
then non-blocking acquire their locks in such order.
Reason: acquiring in unspecified order may cause livelock, as two transactions
may repeatedly try acquiring the same two TVARs in opposite order.

Return the number of VARS locked successfully."
  (let ((vars (gensym "VARS-"))
        (var  (gensym "VAR-"))
        (blk  (gensym "BLOCK-")))

    `(let ((,vars ,txhash-vars))
       (declare (type txhash-table ,vars))

       ;;(setf vars (sort vars #'tvar>))
       
       (block ,blk
         (do-txhash (,var) ,vars
           (unless (try-lock-tvar ,var)
             (return-from ,blk nil))
           (incf ,locked-n))
         t))))


(declaim (inline unlock-tvars))
(defun unlock-tvars (txhash-vars locked-n locked-all?)
  "Release locked (rest VARS) in same order of acquisition."
  (declare (type txhash-table txhash-vars)
           (type fixnum locked-n))

  (if locked-all?
      (do-txhash (var) txhash-vars
        (unlock-tvar var))
      (do-txhash (var) txhash-vars
        (when (= -1 (decf locked-n))
          (return))
        (unlock-tvar var))))




;;;; ** Committing


(defun ensure-tlog-before-commit (log)
  "Create tlog-before-commit log if nil, and return it."
  (declare (type tlog log))
  (the tlog-func-vector
    (or (tlog-before-commit log)
        (setf (tlog-before-commit log)
              (make-array 1 :element-type 'function :fill-pointer 0 :adjustable t)))))

(defun ensure-tlog-after-commit (log)
  "Create tlog-after-commit log if nil, and return it."
  (declare (type tlog log))
  (the tlog-func-vector
    (or (tlog-after-commit log)
        (setf (tlog-after-commit log)
              (make-array 1 :element-type 'function :fill-pointer 0 :adjustable t)))))



(defun call-before-commit (func &optional (log (current-tlog)))
  "Register FUNC function to be invoked immediately before the current transaction commits.

IMPORTANT: See BEFORE-COMMIT for what FUNC must not do."
  (declare (type function func)
           (type tlog log))
  (vector-push-extend func (ensure-tlog-before-commit log))
  func)

(defun call-after-commit (func &optional (log (current-tlog)))
  "Register FUNC function to be invoked after the current transaction commits.

IMPORTANT: See AFTER-COMMIT for what FUNC must not do."
  (declare (type function func)
           (type tlog log))
  (vector-push-extend func (ensure-tlog-after-commit log))
  func)



(defmacro before-commit (&body body)
  "Register BODY to be invoked immediately before the current transaction commits.
If BODY signals an error when executed, the error is propagated to the caller,
further code registered with BEFORE-COMMIT are not executed,
and the transaction rollbacks.

BODY can read and write normally to transactional memory, and in case of conflicts
the whole transaction (not only the code registered with before-commit)
is re-executed from the beginning.

WARNING: BODY cannot (retry) - attempts to do so will signal an error.
Starting a nested transaction and retrying inside that is acceptable,
as long as the (retry) does not propagate outside BODY."
  `(call-before-commit (lambda () ,@body)))


(defmacro after-commit (&body body)
  "Register BODY to be invoked after the current transaction commits.
If BODY signals an error when executed, the error is propagated
to the caller and further code registered with AFTER-COMMIT is not executed,
but the transaction remains committed.

WARNING: Code registered with after-commit has a number or restrictions:

1) BODY must not write to *any* transactional memory: the consequences
are undefined.

2) BODY can only read from transactional memory already read or written
during the same transaction. Reading from other transactional memory
has undefined consequences.

3) BODY cannot (retry) - attempts to do so will signal an error.
Starting a nested transaction and retrying inside that is acceptable
as long as the (retry) does not propagate outside BODY."
  `(call-after-commit (lambda () ,@body)))



(defun loop-funcall-on-appendable-vector (funcs)
  "Call each function in FUNCS vector. Take care that functions being invoked
can register other functions - or themselves again - with (before-commit ...)
or with (after-commit ...).
This means new elements can be appended to FUNCS vector during the loop
=> (loop for func across funcs ...) is not enough."
  (declare (type tlog-func-vector funcs))
  (loop for i from 0
     while (< i (length funcs))
     do
       (funcall (the function (aref funcs i)))))


(defun invoke-before-commit (log)
  "Before committing, call in order all functions registered
with (before-commit)
If any of them signals an error, the transaction will rollback
and the error will be propagated to the caller"
  (declare (type tlog log))
  (when-bind funcs (tlog-before-commit log)
    ;; restore recording and log as the current tlog, functions may need them
    ;; to read and write transactional memory
    (with-recording-to-tlog log
      (handler-case
          (loop-funcall-on-appendable-vector funcs)
        (rerun-error ()
          (log.trace "Tlog ~A before-commit wants to rerun" (~ log))
          (return-from invoke-before-commit nil)))))
  t)



(defmacro invoke-after-commit-macro (log &optional (when-form t) &body cleanup)
  "After committing, call in order all functions registered with (after-commit)
If any of them signals an error, it will be propagated to the caller
but the TLOG will remain committed.
CLEANUP forms will be invoked after all functions registered with (after-commit),
even if they signal an error."
  (with-gensyms (tlog funcs)
    `(let ((,tlog ,log)
           (,funcs nil))
       (declare (type tlog ,tlog))
       (if (and ,when-form (setf ,funcs (tlog-after-commit ,tlog)))
           (unwind-protect
                ;; restore recording and log as the current tlog, functions may need them
                ;; to read transactional memory
                (with-recording-to-tlog log
                  (loop-funcall-on-appendable-vector ,funcs))
             ,@cleanup)
           (progn
             ,@cleanup))
       t)))


(defun invoke-after-commit (log)
  "After committing, call in order all functions registered with (after-commit)
If any of them signals an error, it will be propagated to the caller
but the TLOG will remain committed."
  (declare (type tlog log))
  (invoke-after-commit-macro log))


(defun commit (log)
  "Commit a TLOG to memory.

It returns a boolean specifying whether or not the transaction
log was committed.  If the transaction log cannot be committed
it either means that:
a) the TLOG is invalid - then the whole transaction must be re-executed
b) another TLOG is writing the same TVARs being committed
   so that TVARs locks could not be aquired - also in this case
   the whole transaction will be re-executed, as there is little hope
   that the TLOG will still be valid."
   
  (declare (type tlog log))

  ;; before-commit functions run without locks.
  ;; WARNING: they may access transactional memory,
  ;;          modifying tlog reads and writes!
  (unless (invoke-before-commit log)
    (return-from commit nil))


  (let* ((writes (tlog-writes log))
         (locked-n    0)
         (locked-all? nil)
         (changed     (tlog-changed log))
         (new-version +invalid-version+)
         (success     nil))

    (declare (type txhash-table writes)
             (type fixnum locked-n new-version)
             (type fast-vector changed)
             (type boolean locked-all? success))

    (when (zerop (txhash-table-count writes))
      (log.debug "Tlog ~A committed (nothing to write)" (~ log))
      (invoke-after-commit log)
      (return-from commit t))

    (unwind-protect
         (block nil
           ;; we must lock TVARs that will been written: expensive
           ;; but needed to ensure concurrent commits do not conflict.
           (log.trace "before (try-lock-tvars)")

           (unless (setf locked-all? (try-lock-tvars writes locked-n))
             (log.debug "Tlog ~A failed to lock tvars, not committed" (~ log))
             (return))

           (log.trace "Tlog ~A acquired locks..." (~ log))

           (setf new-version (incf-atomic-counter *tlog-counter*))

           ;; check for log validity one last time, with locks held.
           ;; Also ensure that TVARs in (tlog-reads log) are not locked
           ;; by other threads. For the reason, see doc/consistent-reads.md
           (unless (valid-and-unlocked? log)
             (log.debug "Tlog ~A is invalid or reads are locked, not committed" (~ log))
             (return))

           (log.trace "Tlog ~A committing..." (~ log))

           ;; COMMIT, i.e. actually write new values into TVARs
           (do-txhash (var val) writes
             (let1 current-val (raw-value-of var)
               (when (not (eq val current-val))
                 (set-tvar-version-and-value var new-version val)
                 (fast-vector-push-extend var changed)
                 (log.trace "Tlog ~A tvar ~A changed value from ~A to ~A"
                            (~ log) (~ var) current-val val))))

           (log.debug "Tlog ~A ...committed" (~ log))
           (setf success t))

      ;;(compare-locked-tvars writes locked locked-n)
      (unlock-tvars writes locked-n locked-all?)
      (log.trace "Tlog ~A ...released locks" (~ log))

      (invoke-after-commit-macro log success
        (do-fast-vector (var) changed
          (log.trace "Tlog ~A notifying threads waiting on tvar ~A"
                     (~ log) (~ var))
          (notify-tvar-high-load var))))

        ;; after-commit functions run without locks

    success))
                   





                   



;;;; ** Merging


(defun merge-tlog-reads (log1 log2)
  "Merge (tlog-reads LOG1) and (tlog-reads LOG2).

Return merged TLOG (either LOG1 or LOG2) if tlog-reads LOG1 and LOG2
are compatible, i.e. if they contain the same values for the TVARs
common to both, otherwise return NIL.
\(in the latter case, the merge will not be completed).

Destructively modifies (tlog-reads log1) and (tlog-reads log2)."
  (declare (type tlog log1 log2))
  (let* ((reads1 (tlog-reads log1))
         (reads2 (tlog-reads log2))
         (n1 (txhash-table-count reads1))
         (n2 (txhash-table-count reads2)))
         
    (when (< n1 n2)
      (rotatef log1 log2)
      (rotatef reads1 reads2)
      (rotatef n1 n2)) ;; guarantees n1 >= n2

    (if (or (zerop n2) (merge-txhash-tables reads1 reads2))
        log1
        nil)))

  


(defun commit-nested (log)
  "Commit LOG into its parent log; return LOG.

Unlike (commit log), this function is guaranteed to always succeed.

Implementation note: copy tlog-reads, tlog-writes, tlog-before-commit
and tlog-after-commit into parent, or swap them with parent"

  (declare (type tlog log))
  (let1 parent (the tlog (tlog-parent log))

    (rotatef (tlog-reads parent) (tlog-reads log))
    (rotatef (tlog-writes parent) (tlog-writes log))

    (when-bind funcs (tlog-before-commit log)
      (if-bind parent-funcs (tlog-before-commit parent)
        (loop for func across funcs do
             (vector-push-extend func parent-funcs))
        (rotatef (tlog-before-commit log) (tlog-before-commit parent))))

    (when-bind funcs (tlog-after-commit log)
      (if-bind parent-funcs (tlog-after-commit parent)
        (loop for func across funcs do
             (vector-push-extend func parent-funcs))
        (rotatef (tlog-after-commit log) (tlog-after-commit parent))))

    log))

