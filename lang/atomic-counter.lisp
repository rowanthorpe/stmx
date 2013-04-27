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


(in-package :stmx.lang)

;;;; ** atomic counter


(deftype counter-num ()
  #+stmx-fixnum-is-large 'fixnum
  #-stmx-fixnum-is-large 'bignum)


#+(and stmx-have-sbcl.atomic-ops stmx-fixnum-is-large-power-of-two)
(eval-always

 (defstruct (atomic-counter (:constructor %make-atomic-counter))
   ;; we assume that sb-ext:word is the same or wider than fixnum
   (version 1 :type sb-ext:word))

 (declaim (inline incf-atomic-counter
                  get-atomic-counter)))


#-(and stmx-have-sbcl.atomic-ops stmx-fixnum-is-large-power-of-two)
(eval-always

 (defstruct (atomic-counter (:constructor %make-atomic-counter))
   (version 0 :type counter-num)
   (lock (make-lock "ATOMIC-COUNTER"))))



(declaim (ftype (function () atomic-counter) make-atomic-counter)
         (inline
           make-atomic-counter))

(defun make-atomic-counter ()
  "Create and return a new ATOMIC-COUNTER."
  (%make-atomic-counter))
    


(declaim (ftype (function (atomic-counter) counter-num) incf-atomic-counter))

(defun incf-atomic-counter (counter)
  "Increase atomic COUNTER by one and return its new value."
  (declare (type atomic-counter counter))


  #+(and stmx-fixnum-is-large-power-of-two stmx-have-sbcl.atomic-ops)
  (the fixnum
    (logand most-positive-fixnum
            (sb-ext:atomic-incf (atomic-counter-version counter))))

  #-(and stmx-fixnum-is-large-power-of-two stmx-have-sbcl.atomic-ops)
  ;; locking version
  (let ((lock (atomic-counter-lock counter)))
    (acquire-lock lock)
    (unwind-protect
         (the counter-num
           #+stmx-fixnum-is-large-power-of-two
           ;; fast modulus arithmetic
           (setf (atomic-counter-version counter)
                 (logand most-positive-fixnum
                         (1+ (atomic-counter-version counter))))

           #-stmx-fixnum-is-large-power-of-two
           (progn
             #+stmx-fixnum-is-large
             ;; fixnum arithmetic
             (setf (atomic-counter-version counter)
                   (let ((n (atomic-counter-version counter)))
                     (the fixnum
                       (if (= n most-positive-fixnum)
                           0
                           (1+ n)))))

             #-stmx-fixnum-is-large
             ;; general version: slow bignum arithmetic
             (incf (atomic-counter-version counter))))
                
      (release-lock lock))))


(declaim (ftype (function (atomic-counter) counter-num) get-atomic-counter))

(defun get-atomic-counter (counter)
  "Return current value of atomic COUNTER."
  (declare (type atomic-counter counter))
       
  #+(and stmx-have-sbcl.atomic-ops stmx-fixnum-is-large-power-of-two)
  (progn
    (sb-thread:barrier (:read))
    (the fixnum
      (logand most-positive-fixnum
              (1-
               (logand most-positive-fixnum
                       (atomic-counter-version counter))))))

  #-(and stmx-have-sbcl.atomic-ops stmx-fixnum-is-large-power-of-two)
  ;; locking version
  (the counter-num
    (let ((lock (atomic-counter-lock counter)))
      (acquire-lock lock)
      (unwind-protect
           (atomic-counter-version counter)
        (release-lock lock)))))
