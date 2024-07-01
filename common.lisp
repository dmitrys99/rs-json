;;; common.lisp --- common definitions

;; Copyright (C) 2023 Ralph Schleicher

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;;
;;    * Redistributions of source code must retain the above copyright
;;      notice, this list of conditions and the following disclaimer.
;;
;;    * Redistributions in binary form must reproduce the above copyright
;;      notice, this list of conditions and the following disclaimer in
;;      the documentation and/or other materials provided with the
;;      distribution.
;;
;;    * Neither the name of the copyright holder nor the names of its
;;      contributors may be used to endorse or promote products derived
;;      from this software without specific prior written permission.
;;
;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
;; FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE
;; COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
;; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
;; BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
;; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
;; CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
;; LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
;; ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;; POSSIBILITY OF SUCH DAMAGE.

;;; Code:

(in-package :rs-json)

(defmacro defconst (name value &optional doc)
  "Define a constant variable.

This is like ‘defconstant’ except that the initially set value
is reused when the ‘defconst’ form is evaluated again."
  `(defconstant ,name (if (boundp ',name) (symbol-value ',name) ,value)
     ,@(when doc (list doc))))

(defmacro defsubst (name arg-list &body body)
  "Define an inline function.

This is like ‘defun’ except that the function is globally marked
for inline expansion by the compiler."
  `(progn
     (declaim (inline ,name))
     (defun ,name ,arg-list
       ,@body)))

(defsubst whitespace-char-p (char)
  "Return true if CHAR is a whitespace character.
Argument CHAR has to be a character object."
  #-ecl (declare (type character char))
  (or (char= char #\Space)
      (char= char #\Tab)
      (char= char #\Linefeed)
      (char= char #\Return)
      (char= char #\Newline)))

(define-condition json-error (stream-error simple-condition)
  ()
  (:documentation "Base class for all JSON errors.

Class precedence list:

     ‘json-error’, ‘stream-error’, ‘error’, ..."))

(define-condition syntax-error (json-error)
  ((position
    :accessor syntax-error-position
    :initarg :position
    :initform nil))
  (:documentation "Condition type for a syntax error.

Class precedence list:

     ‘syntax-error’, ‘json-error’, ...")
  (:report (lambda (condition stream)
	     (format stream "~%JSON: ")
	     (when (stringp (simple-condition-format-control condition))
	       (apply #'format stream
		      (simple-condition-format-control condition)
		      (simple-condition-format-arguments condition)))
	     (format stream "~%JSON: ")
	     (alexandria:when-let ((input (stream-error-stream condition)))
	       (format stream "~A" (or *parsed-file* input))
	       (alexandria:when-let ((position (syntax-error-position condition)))
		 (format stream ":~S" position)))
	     )))

(define-condition encoding-error (json-error)
  ()
  (:documentation "Condition type for an encoding error.

Class precedence list:

     ‘encoding-error’, ‘json-error’, ...")
  (:report (lambda (condition stream)
	     (format stream "Failed to encode a Lisp object as JSON")
	     (alexandria:when-let ((output (stream-error-stream condition)))
	       (format stream " in ~S" output))
	     (format stream ".")
	     (when (stringp (simple-condition-format-control condition))
	       (terpri stream)
	       (apply #'format stream
		      (simple-condition-format-control condition)
		      (simple-condition-format-arguments condition))))))

(defvar *scratch* nil
  "The default scratch buffer.")

(defparameter initial-scratch-buffer-size 200
  "The initial number of characters allocated for a scratch buffer.
Value has to be a positive integer.")
(declaim (type (integer 1) initial-scratch-buffer-size))

(defparameter scratch-buffer-growth-rate 2.0
  "The number of characters to be added if a scratch buffer has to grow.
Quite similar to the rehash size of hash tables.")
(declaim (type (or (integer 1) (float (1.0))) scratch-buffer-growth-rate))

(defun make-scratch-buffer (&optional (size initial-scratch-buffer-size))
  "Create a scratch buffer."
  (check-type size (integer 0))
  (make-array size :element-type 'character :adjustable t :fill-pointer 0))

(defun scratch-buffer-p (&optional (buffer *scratch*))
  "Return true if BUFFER is a scratch buffer."
  (and (stringp buffer)
       (adjustable-array-p buffer)
       (array-has-fill-pointer-p buffer)))

(defmacro with-scratch-buffer ((&optional buffer) &body body)
  "Establish a new region in a scratch buffer."
  (let ((buf (gensym "BUF"))
	(mark (gensym "MARK"))
	(incr (gensym "INCR")))
    `(let ((,buf (or ,buffer *scratch*)))
       (unless (scratch-buffer-p ,buf)
	 (error 'type-error :datum ,buf :expected-type 'string))
       ;; Save the current buffer position and predetermine the number
       ;; of elements for an array extension.
       (let ((,mark (length ,buf))
	     (,incr (max (etypecase scratch-buffer-growth-rate
			   (integer
			    scratch-buffer-growth-rate)
			   (float
			    (ceiling
			     (* (1- scratch-buffer-growth-rate)
				(array-total-size ,buf)))))
			 initial-scratch-buffer-size)))
	 (flet ((current-buffer ()
		  "Return the scratch buffer."
		  ,buf)
		(buffer-string ()
		  "Return a copy of the scratch buffer contents."
		  (subseq ,buf ,mark (length ,buf)))
		(displaced-buffer-string ()
		  "Return a displaced array to the scratch buffer contents."
		  (make-array (- (length ,buf) ,mark) :element-type 'character :displaced-to ,buf :displaced-index-offset ,mark))
		(point-min ()
		  "Return the beginning of the scratch buffer."
		  ,mark)
		(point-max ()
		  "Return the end of the scratch buffer."
		  (length ,buf))
		(outc (char)
		  "Append a character to the scratch buffer."
		  #-ecl (declare (type character char))
		  (vector-push-extend char ,buf ,incr)))
	   (declare (inline current-buffer buffer-string displaced-buffer-string point-min point-max outc))
	   (unwind-protect
		(progn ,@body)
	     (setf (fill-pointer ,buf) ,mark)))))))

;;; common.lisp ends here
