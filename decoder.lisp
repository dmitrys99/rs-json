;;; decoder.lisp --- JSON decoder

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

(defvar next-char nil
  "The last character read by the ‘next-char’ function.")
(declaim (type (or null character) next-char))

(defsubst next-char (&optional (eof-error-p t))
  "Read the next character from ‘*standard-input*’."
  (setf next-char (read-char *standard-input* eof-error-p nil)))

(defsubst next-char* (&optional (eof-error-p t))
  "Like the ‘next-char’ function but skip over whitespace characters."
  (loop
    (next-char eof-error-p)
    (unless (and next-char (whitespace-char-p next-char))
      (return)))
  next-char)

(defvar nesting-depth 0
  "The current number of nested structures.")
(declaim (type integer nesting-depth))

(defsubst incr-nesting ()
  "Increase the nesting depth."
  (incf nesting-depth)
  (when (and *maximum-nesting-depth* (> nesting-depth *maximum-nesting-depth*))
    (%syntax-error "Слишком много вложенных структур, должно быть не больше ~A." *maximum-nesting-depth*)))

(defsubst decr-nesting ()
  "Decrease the nesting depth."
  (decf nesting-depth))

(defun %syntax-error (&optional (datum nil datum-supplied-p) &rest arguments)
  "Signal a syntax error."
  (when next-char
    (unread-char next-char *standard-input*))
  (cond ((stringp datum)
	 (error 'syntax-error
		:stream *standard-input*
		:position (file-position *standard-input*)
		:format-control datum
		:format-arguments arguments))
	(datum-supplied-p
	 (apply #'error (or datum 'syntax-error)
		:stream *standard-input*
		:position (file-position *standard-input*)
		arguments))
	(next-char
	 (error 'syntax-error
		:stream *standard-input*
		:position (file-position *standard-input*)
		:format-control "Неожиданный символ ‘~A’."
		:format-arguments (list next-char)))
	(t
	 (error 'syntax-error
		:stream *standard-input*
		:position (file-position *standard-input*)
		:format-control "Файл рано закончился."
		:format-arguments ()))))

(defun %read (stream &optional junk-allowed)
  "Common entry point for all read functions."
  ;; Using a non-volatile scratch buffer for parsing numbers
  ;; and literals reduces running time by approximately 10 %
  ;; and memory requirements by 20 % on file ‘large.json’.
  (let ((*scratch* (make-scratch-buffer))
	(*standard-input* stream)
	(next-char nil)
	(nesting-depth 0))
    ;; Read first character.
    (next-char* nil)
    (unless next-char
      (%syntax-error))
    ;; Parse the JSON value.
    (let ((data (parse-value)))
      ;; Check for end of file.
      (when next-char
	(unless junk-allowed
	  (%syntax-error))
	(unread-char next-char stream))
      ;; Return values.
      (values data (file-position stream)))))

(defun parse (source &key junk-allowed)
  "Read a JSON value.

First argument SOURCE is the input object.  Value is either a
 stream, a string, or a pathname.  The special value ‘t’ is
 equal to ‘*standard-input*’
If keyword argument JUNK-ALLOWED is true, do not signal an error
 of type ‘syntax-error’ if a non-whitespace character occurs after
 the JSON value.  Default value is false.

The ‘parse’ function expects exactly one JSON value.  Any value
is accepted, not only an object or array.  Optional leading and
trailing whitespace is ignored.

Return value is the Lisp representation of the JSON value.
Secondary value is the position where the parsing ends, or
‘nil’ if the position can not be determined.

Exceptional situations:

   * Signals an ‘end-of-file’ error if the input ends in the
     middle of a JSON value.

   * Signals a ‘syntax-error’ if the input contains an invalid
     JSON structure.

   * May signal an ‘arithmetic-error’ if a JSON number can not
     be represented as a Lisp number.

   * Signals a ‘program-error’ if JSON objects are parsed as
     hash tables, ‘*allow-duplicate-object-keys*’ is bound to
     ‘:append’, and a duplicate object member occurs."
  (etypecase source
    (stream
     (%read source junk-allowed))
    (string
     (with-input-from-string (stream source)
       (%read stream junk-allowed)))
    (pathname
     (with-open-file (stream source :external-format
			     #-ecl (uiop:encoding-external-format :utf-8)
			     #+ecl :utf-8)
       (setf *parsed-file* source)
       (%read stream junk-allowed)))
    ((member t)
     (%read *standard-input* junk-allowed))))

(defun parse-value ()
  "Parse any JSON value."
  (case next-char
    (#\{
     (parse-object))
    (#\[
     (parse-array))
    (#\"
     (parse-string))
    ((#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9 #\- #\+ #\.)
     (parse-number))
    (t
     (parse-literal))))

(defun parse-object ()
  "Parse a JSON object."
  (let ((object (when (eq *object-as* :hash-table)
		  (make-hash-table :test #'equal)))
	(emptyp t) key-string key value dup)
    ;; Discard opening brace.
    (next-char* nil)
    (unless next-char
      (%syntax-error))
    (incr-nesting)
    ;; Parse object members.
    (loop
      (case next-char
	(#\}
	 (return))
	(#\,
	 (when emptyp
	   (%syntax-error "Запятая перед частью объекта."))
	 ;; Discard comma.
	 (next-char*)
	 ;; Check for trailing comma.
	 (when (and *allow-trailing-comma* (char= next-char #\}))
	   (return)))
	(t
	 (when (not emptyp)
	   (%syntax-error "Пропущена запятая после части объекта."))))
      ;; Read the key.
      (setf key-string (if (char= next-char #\")
			   (parse-string)
			 (progn
			   (when (not *allow-literal-object-keys*)
			     (%syntax-error "Ключ объекта должен быть строкой в кавычках."))
			   (parse-literal t)))
	    key (funcall *object-key-decoder* key-string))
      ;; Check if the key already exists.
      (setf dup (ecase *object-as*
		  (:hash-table
		   (nth-value 1 (gethash key object)))
		  (:alist
		   (assoc key object :test #'equal))
		  (:plist
		   ;; Like ‘(nth-value 2 (get-properties object (list key)))’
		   ;; but without consing.  Keys can be strings, too.
		   (do ((plist object (cddr plist)))
		       ((null plist) nil)
		     (when (equal (car plist) key)
		       (return plist))))))
      (when (and dup (not *allow-duplicate-object-keys*))
        (%syntax-error "Повтор ключа объекта ‘~A’." key-string))
      ;; Read the key/value separator.
      (when (null next-char)
	(error 'end-of-file :stream *standard-input*))
      (unless (char= next-char #\:)
        (%syntax-error "Пропущено двоеточие между ключом и значением объекта."))
      (next-char*)
      ;; Read the value.
      (setf value (parse-value))
      (cond ((or (not dup) (eq *allow-duplicate-object-keys* :append))
	     ;; First occurrence of the key.
	     (ecase *object-as*
	       (:hash-table
		(when dup (error 'program-error))
		(setf (gethash key object) value))
	       (:alist
		(setf object (acons key value object)))
	       (:plist
		(setf object (nconc object (list key value))))))
	    ((not (eq *allow-duplicate-object-keys* :ignore))
	     ;; Successive occurrence of the same key.
	     ;; Replace existing value.
	     (ecase *object-as*
	       (:hash-table
		(setf (gethash key object) value))
	       (:alist
		(rplacd dup value))
	       (:plist
		(setf (second dup) value)))))
      ;; Object is not empty.
      (setf emptyp nil))
    ;; Discard closing brace and skip trailing whitespace.
    (decr-nesting)
    (next-char* nil)
    ;; Return value.
    (when (eq *object-as* :alist)
      (setf object (nreverse object)))
    (when *decode-object-hook*
      (setf object (funcall *decode-object-hook* object)))
    object))

(defun parse-array ()
  "Parse a JSON array."
  (let ((array (when (eq *array-as* :vector)
		 ;; Start with an almost empty array to reduce
		 ;; initial memory allocation.
		 (make-array 1 :adjustable t :fill-pointer 0)))
	(emptyp t) element)
    ;; Discard opening bracket.
    (next-char*)
    (incr-nesting)
    ;; Parse array elements.
    (loop
      (case next-char
        (#\]
	 (return))
	(#\,
	 (when emptyp
	   (%syntax-error "Ведущая запятая перед элементом массива."))
	 ;; Discard comma.
	 (next-char*)
	 ;; Check for trailing comma.
	 (when (and *allow-trailing-comma* (char= next-char #\]))
	   (return)))
	(t
	 (when (not emptyp)
	   (%syntax-error "Пропущена запятая после элемента массива."))))
      ;; Read the array element.
      (setf element (parse-value))
      (if (eq *array-as* :vector)
	  (vector-push-extend element array)
        (push element array))
      ;; Array is not empty.
      (setf emptyp nil))
    ;; Discard closing bracket and skip trailing whitespace.
    (decr-nesting)
    (next-char* nil)
    ;; Return value.
    (when (not (eq *array-as* :vector))
      (setf array (nreverse array)))
    (when *decode-array-hook*
      (setf array (funcall *decode-array-hook* array)))
    array))

(defun parse-string ()
  "Parse a JSON string."
  (with-output-to-string (buffer)
    (labels ((outc (char)
	       "Добавить символ к выходному буферу."
	       (write-char char buffer)))
      ;; Parse quoted string.
      (loop
	;; Initially, this call discards the
	;; opening quote character.
	(next-char)
	(case next-char
	  (#\"
	   ;; Discard closing quote character
	   ;; and skip trailing whitespace.
	   (next-char* nil)
	   (return))
	  (#\\
	   ;; Escape sequence.
	   (next-char)
	   (case next-char
	     (#\" (outc #\"))
	     (#\\ (outc #\\))
	     (#\/ (outc #\/))
	     (#\b (outc #\Backspace))
	     (#\f (outc #\Page))
	     (#\n (outc #\Linefeed))
	     (#\r (outc #\Return))
	     (#\t (outc #\Tab))
	     (#\u
	      #-cmucl
	      (outc (parse-unicode-escape))
	      #+cmucl
	      (multiple-value-bind (high low)
		  (parse-unicode-escape)
		(outc high)
		(when low
		  (outc low))))
	     (t
	      (%syntax-error "В строке неизвестная escape-последовательность ‘\\~A’." next-char))))
	  (t
	   ;; Any other character.
	   ;;
	   ;; “All code points may be placed within the
	   ;; quotation marks except for the code points
	   ;; that must be escaped: quotation mark (U+0022),
	   ;; reverse solidus (U+005C), and the control
	   ;; characters U+0000 to U+001F.”
	   (when (<= 0 (char-code next-char) #x1F)
	     (%syntax-error "Необработанный символ в строке: ‘~A’." next-char))
	   (outc next-char)))))))

(defun parse-unicode-escape ()
  "Helper function for ‘parse-string’."
  (flet ((parse-hex ()
	   "Read four hexadecimal digits and return the corresponding numerical value."
	   (logior (ash (or (digit-char-p (next-char) 16) (%syntax-error)) 12)
		   (ash (or (digit-char-p (next-char) 16) (%syntax-error))  8)
		   (ash (or (digit-char-p (next-char) 16) (%syntax-error))  4)
		   (or (digit-char-p (next-char) 16) (%syntax-error)))))
    (let ((high (parse-hex)))
      (if (not (<= #xD800 high #xDFFF))
	  ;; A regular character.
	  (code-char high)
	;; A surrogate pair.
	(progn
	  (unless (and (char= (next-char) #\\)
		       (char= (next-char) #\u))
	    (%syntax-error))
	  (let ((low (parse-hex)))
            (unless (and (<= #xD800 high #xDBFF)
			 (<= #xDC00 low #xDFFF))
	      (%syntax-error "В строке некорректная суррогатная пара UTF-16 U+~4,'0X и U+~4,'0X." high low))
	    #-cmucl
            (code-char (+ (ash (- high #xD800) 10)
                          (- low #xDC00)
			  #x10000))
	    ;; CMUCL strings use UTF-16 encoding.  Just return the
	    ;; surrogate pair as is.
	    #+cmucl
	    (values (code-char high) (code-char low))))))))

(defun parse-number ()
  "Parse a JSON number."
  ;; The idea is to read the number into a string buffer and report
  ;; syntax errors as soon as possible.  Once the number is read, use
  ;; the Lisp reader to convert it into a Lisp object.
  (with-scratch-buffer ()
    (labels ((read-digits ()
	       "Read a sequence of digits."
	       (let ((length 0))
		 (loop
		   (unless (and next-char
				(standard-char-p next-char)
				(digit-char-p next-char))
		     (return))
		   (incf length)
		   (outc next-char)
		   (next-char nil))
		 length)))
      ;; See ‘read-number:read-float’.
      (prog ((digits 0)
	     (strictp (not *allow-lax-numbers*)))
	 ;; Optional number sign.
	 (cond ((char= next-char #\-)
		(outc #\-)
		(next-char))
	       ((char= next-char #\+)
		(when strictp
		  (%syntax-error "Число начинается с плюса."))
		(next-char)))
	 ;; Integer part.
	 (cond ((char= next-char #\0)
		(incf digits)
		(outc #\0)
		(next-char nil))
	       (t
		(incf digits (read-digits))
		(when (and strictp (zerop digits))
		  (%syntax-error "Целая часть числа не должна быть пустой."))))
	 (when (null next-char)
	   (return))
	 ;; Optional fractional part.
	 (when (char= next-char #\.)
	   (outc #\.)
	   ;; Skip decimal point.  If the integer part
	   ;; is empty, the fractional part must be not
	   ;; empty.
	   (next-char (or strictp (zerop digits)))
	   (when (null next-char)
	     ;; Lisp reads ‘1.’ as an integer.
	     (outc #\0)
	     (return))
	   ;; Fractional part.
	   (cond ((and (standard-char-p next-char)
		       (digit-char-p next-char))
		  (incf digits (read-digits)))
		 (t
		  (when (or strictp (zerop digits))
		    (%syntax-error "Дробная часть числа не должна быть пустой."))
		  (outc #\0)))
	   (when (null next-char)
	     (return)))
	 ;; Need at least one digit.
	 (when (zerop digits)
	   (%syntax-error "Число должно состоять по крайней мере из одной цифры."))
	 ;; Optional exponent part.
	 (when (or (char= next-char #\E)
		   (char= next-char #\e))
	   (outc next-char)
	   ;; Skip exponent marker.
	   (next-char)
	   ;; Exponent.
	   (cond ((char= next-char #\-)
		  (outc #\-)
		  (next-char))
		 ((char= next-char #\+)
		  (next-char)))
	   (when (zerop (read-digits))
	     (%syntax-error "Экспонента числа не должна быть пустой.")))))
    (prog1
	(handler-case
	    (let ((*read-default-float-format* 'double-float))
	      (read-from-string (current-buffer) t nil :start (point-min) :end (point-max)))
	  (arithmetic-error (condition)
	    ;; Re-throw the error.
	    (error condition))
	  (error ()
	    (error 'arithmetic-error
		   :operation 'read-from-string
		   :operands (list (buffer-string)))))
      ;; Skip trailing whitespace.
      (when (and next-char (whitespace-char-p next-char))
	(next-char* nil)))))

(defun parse-literal (&optional identifierp)
  "Parse a JSON literal name token, i.e. ‘true’, ‘false’, or ‘null’.

If optional argument IDENTIFIERP is true, accept any valid JavaScript
 identifier.

Return either the Lisp value of the literal name token or the identifier
name (a string)."
  ;; The idea is to parse a JavaScript identifier name and then check
  ;; whether or not it is a literal name token.
  (with-scratch-buffer ()
    ;; Identifier names do not start with a digit.
    (unless (or (alpha-char-p next-char)
		(char= next-char #\$)
		(char= next-char #\_))
      (%syntax-error))
    (loop
      (outc next-char)
      (next-char nil)
      (unless (and next-char
		   (or (alpha-char-p next-char)
		       (digit-char-p next-char)
		       (char= next-char #\$)
		       (char= next-char #\_)))
	(return)))
    (let ((buffer (current-buffer))
	  (start (point-min))
	  (end (point-max)))
      (prog1
	  (if (not identifierp)
	      ;; Expect a literal name token.
	      (cond ((string= buffer "true"  :start1 start :end1 end)
		     *true*)
		    ((string= buffer "false" :start1 start :end1 end)
		     *false*)
		    ((string= buffer "null"  :start1 start :end1 end)
		     *null*)
		    ((%syntax-error "Неизвестный литерал ‘~A’." (buffer-string))))
	    ;; Accept any identifier name.
	    (let ((name (buffer-string)))
	      (if (or (string= name "true")
		      (string= name "false")
		      (string= name "null"))
		  (%syntax-error "Литерал ‘~A’ не является допустимым идентификатором." name)
		name)))
	;; Skip trailing whitespace.
	(when (and next-char (whitespace-char-p next-char))
	  (next-char* nil))))))

;;; decoder.lisp ends here
