;;; A BibTeX re-implementation in Common Lisp - the BST interpreter
;;; Copr. 2001, 2002 Matthias Koeppe <mkoeppe@mail.math.uni-magdeburg.de>
;;; This is free software, licensed under GNU GPL (see file COPYING)

(in-package bibtex-compiler)

(defvar *bst-readtable*
  (let ((*readtable* (copy-readtable nil)))
    ;; comment character
    (set-syntax-from-char #\% #\;)
    ;; CL's package marker : is an ordinary constituent in BST...
    ;; Here's just a quick fix to make := work
    (set-macro-character #\:
			 #'(lambda (stream char)
			     (declare (ignore char))
			     (let ((sym (read stream nil nil t)))
			       (unless (symbolp sym)
				 (error "Bad syntax"))
			       (intern
				(string-upcase 
				 (concatenate 'string ":" (symbol-name sym)))))))
			       
    ;; function lists
    (set-macro-character #\{
			 #'(lambda (stream char)
			     (declare (ignore char))
			     (read-delimited-list #\} stream t)))
    (set-syntax-from-char #\} #\))
    ;; quote
    (set-macro-character #\'
			 #'(lambda (stream char)
			     (declare (ignore char))
			     (list 'quote (read stream nil nil t))))
    ;; numbers
    (set-macro-character #\#
			 #'(lambda (stream char)
			     (declare (ignore char))
			     (read stream nil nil t)))
    ;; double-quote; BST strings have no escape
    (set-macro-character #\"
			 #'(lambda (stream char)
			     (declare (ignore char))
			     (coerce
			      (loop as char = (read-char stream nil nil t)
				    until (char= char #\")
				    collect char)
			      'string)))
    *readtable*))


;;;

(defvar *bst-stream* nil)

(defun bst-read (&key (eof-ok nil))
  (let ((result
	 (let ((*readtable* *bst-readtable*))
	   (read *bst-stream* nil '*EOF*))))
    (when (and (not eof-ok)
	       (eq result '*EOF*))
      (error "Unexpected end of file"))
    result))

;;;

(defvar *read-seen-p* nil "Non-nil if the BST READ command has been seen.")
(defvar *entry-seen-p* nil "Non-nil if the BST ENTRY command has been seen.")

(defstruct bst-command
  function
  args)

(defvar *bst-commands* (make-hash-table :test 'equalp))

(defmacro define-bst-command (name args &body body)
  `(setf (gethash ,(string name) *bst-commands*)
    (make-bst-command :function (lambda ,args ,@body)
     :args ',args)))

(defun get-bst-commands-and-process (stream)
  (let* ((*bst-stream* stream)
	 (*entry-seen-p* nil)
	 (*read-seen-p* nil))
    (loop
     (when (and *bst-compiling*
		(char= (peek-char t *bst-stream* nil #\x) #\%))
       ;; Copy top-level comments; replace N leading % signs with N+1 semicola
       (terpri *lisp-stream*)
       (loop while (char= (peek-char t *bst-stream* nil #\x) #\%)
	     do
	     (princ ";" *lisp-stream*)
	     (loop while (char= (peek-char nil *bst-stream* nil #\x) #\%)
		   do (read-char *bst-stream*) (princ ";" *lisp-stream*))
	     (princ (read-line *bst-stream* nil "") *lisp-stream*)
	     (terpri *lisp-stream*)))
     (let ((command (bst-read :eof-ok t)))
       (when (eql command '*EOF*)
	 (return))
       (let ((bst-command (gethash (string command) *bst-commands*)))
	 (unless bst-command
	   (error "~A is an illegal style-file command" command))
	 (apply (bst-command-function bst-command)
		(mapcar (lambda (argname)
			  (declare (ignore argname))
			  (bst-read :eof-ok nil))
			(bst-command-args bst-command))))))))

(define-bst-command "ENTRY" (fields int-entry-vars str-entry-vars)
  (when *entry-seen-p*
    (error "Illegal, another entry command"))
  (setq *entry-seen-p* t)
  (dolist (field fields)
    (check-for-already-defined-function field)
    (register-bst-entry field 'field '(string missing) nil *bst-functions*))
  (dolist (entry int-entry-vars)
    (check-for-already-defined-function entry)
    (register-bst-entry entry 'int-entry-var '(integer) 0 *bst-functions*))
  (dolist (entry str-entry-vars)
    (check-for-already-defined-function entry)
    (register-bst-entry entry 'str-entry-var '(string) "" *bst-functions*)))

(defun singleton-list-p (arg)
  "Non-nil if ARG is a list consisting of one symbol."
  (and (consp arg)
       (symbolp (car arg))
       (null (cdr arg))))

(define-bst-command "EXECUTE" (function-list)
  (unless *read-seen-p*
    (error "Illegal, execute command before read command"))
  (unless (singleton-list-p function-list)
    (error "Illegal argument ~A to execute command"
	   function-list))
  (let* ((name (car function-list))
	 (function (get-bst-function-of-type name '(built-in wiz-defined compiled-wiz-defined))))
    (if *bst-compiling*
	(push (bst-compile-thunkcall name) *main-lisp-body*)
      (bst-execute function))))

(define-bst-command "FUNCTION" (function-list function-definition)
  (unless (singleton-list-p function-list)
    (error "Illegal argument ~A to function command"
	   function-list))
  (let* ((bst-name (car function-list)))
    (unless (check-for-already-defined-function bst-name)
      (if *bst-compiling*
	  (compile-bst-function bst-name function-definition *lisp-stream*)
	(setf (gethash (string bst-name) *bst-functions*)
	      (make-bst-function :name (string bst-name)
				 :type 'wiz-defined
				 :body function-definition))))))

(define-bst-command "INTEGERS" (name-list)
  (unless (listp name-list)
    (error "Illegal argument ~A to integers command"
	   name-list))
  (dolist (bst-name name-list)
    (check-for-already-defined-function bst-name)
    (let ((lisp-name (bst-name-to-lisp-name bst-name)))
      (register-bst-global-var bst-name lisp-name 'int-global-var '(integer) 0 *bst-functions*)
      (when (and *bst-compiling*
		 (not (member bst-name *lexicals* :test 'string-equal)))
	(lisp-write `(defvar ,lisp-name 0))))))

(define-bst-command "ITERATE" (function-list)
  (unless *read-seen-p*
    (error "Illegal, iterate command before read command"))
  (unless (singleton-list-p function-list)
    (error "Illegal argument ~A to iterate command"
	   function-list))
  (let* ((name (car function-list))
	 (function (get-bst-function-of-type name '(built-in wiz-defined compiled-wiz-defined))))
    (if *bst-compiling*
	(push `(dolist (*bib-entry* bib-entries)
		 ,(bst-compile-thunkcall name))
	      *main-lisp-body*)
      (dolist (*bib-entry* *bib-entries*)
	(bst-execute function)))))

(define-bst-command "MACRO" (function-list function-definition)
  (when *read-seen-p*
    (error "Illegal, macro command after read command"))
  (unless (singleton-list-p function-list)
    (error "Illegal argument ~A to macro command"
	   function-list))
  (unless (and (consp function-definition)
	       (stringp (car function-definition))
	       (null (cdr function-definition)))
    (error "Illegal argument ~A to macro command"
	   function-definition))
  (let ((name (car function-list))
	(definition (car function-definition)))
    (check-for-already-defined-function name)
    (setq name (string name))
    (make-bst-function :name name
		       :lisp-name (lambda () (gethash name *bib-macros*))
		       :lisp-form-maker (lambda ()
					  `(gethash name *bib-macros*))
		       :type 'macro
		       :argument-types '()
		       :result-types '((string)))
    (setf (gethash name *bib-macros*) definition)))

(define-bst-command "READ" ()
  (when *read-seen-p*
    (error "Illegal, another read command"))
  (unless *entry-seen-p*
    (error "Illegal, read command before entry command"))
  (setq *read-seen-p* t)
  (if *bst-compiling*
      (push `(setq bib-entries (read-all-bib-files-and-compute-bib-entries)) *main-lisp-body*)
      (setq *bib-entries* (read-all-bib-files-and-compute-bib-entries))))

(define-bst-command "REVERSE" (function-list)
  (unless *read-seen-p*
    (error "Illegal, reverse command before read command"))
  (unless (singleton-list-p function-list)
    (error "Illegal argument ~A to execute command"
	   function-list))
  (let* ((name (car function-list))
	 (function (get-bst-function-of-type name '(built-in wiz-defined compiled-wiz-defined))))
	
    (if *bst-compiling*
	(push `(dolist (*bib-entry* (reverse bib-entries))
		,(bst-compile-thunkcall name))
	      *main-lisp-body*)
	(dolist (*bib-entry* (reverse *bib-entries*))
	  (bst-execute function)))))

(define-bst-command "SORT" ()
  (unless *read-seen-p*
    (error "Illegal, sort command before read command"))
  (if *bst-compiling*
      (push `(setq bib-entries
	      (stable-sort bib-entries 'string<=
	       :key (lambda (entry) (gethash "SORT.KEY$" entry ""))))
	    *main-lisp-body*)
      (setq *bib-entries*
	    (stable-sort *bib-entries* 'string<=
			 :key (lambda (entry) (gethash "SORT.KEY$" entry ""))))))

(define-bst-command "STRINGS" (name-list)
  (unless (listp name-list)
    (error "Illegal argument ~A to strings command"
	   name-list))
  (dolist (bst-name name-list)
    (check-for-already-defined-function bst-name)
    (let ((lisp-name (bst-name-to-lisp-name bst-name)))
      (register-bst-global-var bst-name lisp-name 'str-global-var '(string) "" *bst-functions*)
      (when (and *bst-compiling*
		 (not (member bst-name *lexicals* :test 'string-equal)))
	(lisp-write `(defvar ,lisp-name ""))))))


