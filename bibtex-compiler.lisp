;;; A BibTeX re-implementation in Common Lisp - the BST->CL compiler
;;; Copr. 2001, 2002 Matthias Koeppe <mkoeppe@mail.math.uni-magdeburg.de>
;;; This is free software, licensed under GNU GPL (see file COPYING)

;; TODO:
;; * macros
;; * most variables are in fact lexical variables (some, in fact, only
;;   store arguments for later use).  Keep track whether a variable is
;;   accessed before it is assigned in any function; if not, we can make
;;   it lexical in *all* functions.  This requires a second compiler pass.
;; * maybe name formal arguments "STRING1", "INT1", ..., depending on type?
;; * maybe replace dots with dashes in function names
;; * maybe put stars around special variables names
;; * don't name the temporary variables occuring in while$ "ARGnn"
;; * propagate types when they get more specific:
;;   { $duplicate + } is of type (INTEGER) -> (INTEGER), not T -> (INTEGER)
;; * be more strict when checking the type of a popped form
;; * If call.type$ occurs only once (in an ITERATE command),
;;   use CASE instead of ASSOC/FUNCALL?
;; * Try to compile the whole custom-bib system (merlin.mbs)?

(in-package bibtex-compiler)

(defvar *bst-compiling* nil
  "Non-nil if we are compiling a Common Lisp program from the BST
program, rather than interpreting the BST program.")

(defvar *lisp-stream* nil
  "A stream where we write the Common Lisp program equivalent to the
BST program.")

(defvar *main-lisp-body* ()
  "A list collecting the forms corresponding to EXECUTE, ITERATE,
READ, REVERSE, and SORT commands in reverse order.")

(defun lisp-write (arg)
  (let ((*print-case* :downcase))
    (pprint arg *lisp-stream*))
  (terpri *lisp-stream*))

;; The type system.  NIL means no value fits, T means all values fit.
;; A list of symbols means values of all listed types fit.

(defun type-intersection (a b)
  (cond
    ((eql a t) b)
    ((eql b t) a)
    (t (intersection a b))))

(defun type-union (a b)
  (cond
    ((eql a t) t)
    ((eql b t) t)
    (t (union a b))))

(defun type<= (a b)
  (cond
    ((eql b t) t)
    ((eql a t) nil)	         ; this assumes that a list of type
					; symbols is never complete
    (t (every (lambda (x) (member x b)) a))))

(defun type= (a b)
  (and (type<= a b)
       (type<= b a)))

(defun null-type (a)
  (null a))

;;; Capturing the computation in effect

(defstruct variable
  "A typed Lisp variable"
  name
  type)

(defstruct binding
  "A multiple-value binding frame"
  variables
  mvform)

(defstruct mvform
  "A multiple-values-delivering form on the stack"
  form					; a Lisp form OR
  literal				; a BST symbol or function body
  types
  (side-effects null-side-effects))

(defvar *form-bindings* ()
  "A list of BINDINGs that keeps track of all forms that cannot be
collected functionally because they are side-effecting or their values
are needed more than one time.")

(defvar *borrowed-variables* ()
  "The list of VARIABLEs borrowed from the stack.")

(defvar *form-stack* ()
  "The list of MVFORMs delivering the values on the stack.")  

(defvar *lexicals* ()
  "A hack until detection of lexicals works.")

(defvar *lexical-variables* ()
  "An alist mapping strings designating BST variables to Lisp VARIABLEs.")  

(defun map2 (procedure &rest lists)
  "Return two lists that are collecting the two values of PROCEDURE,
applied to the parallel elements in LISTS."
  (do ((result1 ())
       (result2 ())
       (lists lists (mapcar #'cdr lists)))
      ((some #'null lists)
       (values (nreverse result1) (nreverse result2)))
    (multiple-value-bind (r1 r2)
	(apply procedure (mapcar #'car lists))
      (setq result1 (cons r1 result1)
	    result2 (cons r2 result2)))))

;;(map2 #'round '(5 6 7) '(2 2 2))

(define-condition bst-compiler-error ()
  ((message :initarg :message :reader bst-compiler-error-message)))

(defvar *currently-compiled-function* nil
  "Only used for reporting errors.")

(defvar *currently-compiled-body* nil
  "Only used for reporting errors.")

(defvar *currently-compiled-body-rest* nil
  "Only used for reporting errors.")

(defun currently-compiled-body-with-markup ()
  (do ((body *currently-compiled-body* (cdr body))
       (front ()))
      ((or (null body)
	   (eq body *currently-compiled-body-rest*))
       (nconc (nreverse front) (cons '====> body)))
    (setq front (cons (car body) front))))
    

(defun bst-compile-error (format-string &rest args)
  (error (make-condition 'bst-compiler-error
			 :message
			 (concatenate 'string
				      (format nil " In BST body ~S:~%  "
					      (currently-compiled-body-with-markup))
				      (apply 'format nil format-string args)))))

;;; Side effects

(defun any-side-effects-p (side-effects)
  (or (side-effects-side-effects-p side-effects)
      (not (null (side-effects-assigned-variables side-effects)))))

(defun max-side-effects (&rest effectss)
  "Compute the maximum of the side-effects EFFECTSS."
  (make-instance 'side-effects
		 :side-effects-p (some #'side-effects-side-effects-p effectss)
		 :used-variables (apply #'set-union (mapcar #'side-effects-used-variables effectss))
		 :assigned-variables (apply #'set-union (mapcar #'side-effects-assigned-variables effectss))
		 :unconditionally-assigned-variables
		 (apply #'set-union (mapcar #'side-effects-unconditionally-assigned-variables effectss))))   

(defun remove-variables-from-side-effects (variables side-effects)
  "VARIABLES is a list of strings or symbols to be removed from any
mention in SIDE-EFFECTS.  Return the resulting side effects."
  (make-instance 'side-effects
		 :side-effects-p (side-effects-side-effects-p side-effects)
		 :assigned-variables
		 (set-difference (side-effects-assigned-variables side-effects)
				 variables
				 :test 'equalp)
		 :unconditionally-assigned-variables
		 (set-difference (side-effects-unconditionally-assigned-variables side-effects)
				 variables
				 :test 'equalp)
		 :used-variables
		 (set-difference (side-effects-used-variables side-effects)
				 variables
				 :test 'equalp)))

(defvar *bst-gentemp-counter* 0)

(defun bst-gentemp (prefix)
  (intern (format nil "~A~A" prefix (incf *bst-gentemp-counter*))))  

(defun make-binding-and-push-variables (mvform)
  "Make a binding for all values delivered by MVFORM and push the
bound variables onto *FORM-STACK*."
  (multiple-value-bind (variables mvforms)
      (map2 (lambda (type)
	      (let ((symbol (bst-gentemp "T")))
		(values (make-variable :name symbol :type type)
			(make-mvform :form symbol :types (list type)))))
	    (mvform-types mvform))
    ;;(format t "variables: ~A~%mvforms: ~A~%" variables mvforms)
    (push (make-binding :variables variables
			:mvform mvform)
	  *form-bindings*)
    (setq *form-stack* (nconc (nreverse mvforms)
			      *form-stack*))))

(defun pop-form (type &key (need-variable nil) (when-empty :borrow)
		 (assigned-variables ()))
  "Pop a Lisp form delivering a single value of given TYPE from
*FORM-STACK*.  If the stack is empty, borrow a variable instead if
:WHEN-EMPTY is :BORROW, or return nil if :WHEN-EMPTY is nil.  If
:NEED-VARIABLE is nil, POP-FORM may return a side-effecting
single-value form \(which should only be called once, in order).  If
:NEED-VARIABLE is :IF-SIDE-EFFECTS, POP-FORM will introduce a variable
for side-effecting forms.  Otherwise, POP-FORM will introduce a
variable for all non-atom forms.  A variable will also be introduced
if the form uses one of the variables in the list :ASSIGNED-VARIABLES.
Return three values: the Lisp form,
the actual type of the delivered value, and SIDE-EFFECTS."
  (loop (when (null *form-stack*)
	  (ecase when-empty
	    ((nil) (return-from pop-form nil))
	    (:borrow 
	     ;; Borrow a variable
	     (let ((arg-symbol (bst-gentemp "ARG")))
	       (push (make-variable :name arg-symbol :type type)
		     *borrowed-variables*)
	       (return-from pop-form (values arg-symbol type null-side-effects))))))
	(let ((top-mvform (pop *form-stack*)))
	  (labels ((return-the-form ()
		     (let* ((available-type (car (mvform-types top-mvform)))
			    (effective-type (type-intersection type available-type))
			    (lisp-form (mvform-form top-mvform))
			    (side-effects (mvform-side-effects top-mvform)))
   ;; The handling of the special case boolean/integer is only a hack.
		       ;; The type system should be improved instead.
		       (cond
			 ((and (type= available-type '(integer))
			       (type= type '(boolean)))
			  (return-from pop-form
			    (values `(> ,lisp-form 0) '(boolean) side-effects)))
			 ((and (type= available-type '(boolean))
			       (type= type '(integer)))
			  (return-from pop-form
			    (values `(if ,lisp-form 1 0) '(boolean) side-effects)))
			 ((null-type effective-type)
			  (bst-compile-error "Type mismatch: expecting ~A, got ~A."
					     type available-type))
			 (t
			  (return-from pop-form
			    (values lisp-form effective-type side-effects)))))))
	    (cond
	      ((not (null (intersection assigned-variables
					(side-effects-used-variables
					 (mvform-side-effects top-mvform))
					:test 'equalp)))
	       ;; Must make a binding because a used variable is
	       ;; affected by an assignment.
	       (make-binding-and-push-variables top-mvform))
	      ((mvform-literal top-mvform)
	       (bst-compile-error "Expecting a form on the stack, got a literal ~S."
				  (mvform-literal top-mvform)))
	      ((not (consp (mvform-form top-mvform))) ; Variable, string, or number, delivering one value
	       (return-the-form))
	      ((and (eql need-variable :if-side-effects)
		    (not (any-side-effects-p (mvform-side-effects top-mvform)))
		    ;;;(= (length (mvform-types top-mvform)) 1)
		    )
	       (return-the-form))
	      ((and (not need-variable)
		    (= (length (mvform-types top-mvform)) 1))
	       (return-the-form))
	      (t
	      ;; Zero or more than two values, so make a binding frame
	       ;; and push single-value forms referring to the bound
	       ;; variables.  Then continue.
	       (make-binding-and-push-variables top-mvform)))))))

(defun pop-single-value-form (&rest args)
  "Like pop-form, but package the return values in a MVFORM object."
  (multiple-value-bind (form type side-effects)
      (apply 'pop-form args)
    (if form
	(make-mvform :form form :types (list type)
		     :side-effects side-effects)
	nil)))

(defun push-form (mvform)
  "Push MVFORM onto *FORM-STACK*."
  ;; We first check if the last form has a side-effect.  If so, we
  ;; must turn it into a binding, or the order of side-effects will be
  ;; wrong.
  (when (and (not (null *form-stack*))
	     (any-side-effects-p (mvform-side-effects (car *form-stack*))))
    (let ((se-form (pop *form-stack*)))
      (make-binding-and-push-variables se-form)))
  ;; At this point everything on the stack is purely functional, so we
  ;; don't have to care about the order.
  (let ((ass-vars (side-effects-assigned-variables (mvform-side-effects mvform))))
    (when ass-vars
      ;; If the form to be pushed makes an assignment, it can render
      ;; even purely functional forms wrong if the order isn't fine.
      ;; Hence, convert every form on the value stack that uses the
      ;; assigned-to variables to bindings before proceeding.
      (loop for form = (pop-single-value-form t :need-variable nil
					      :assigned-variables ass-vars :when-empty nil)
	    while form
	    collect form into clean-form-stack
	    finally (setq *form-stack* clean-form-stack)))
    (push mvform *form-stack*)))

(defun push-mvform (&rest args)
  (push-form (apply 'make-mvform args)))

(defun pop-literal ()
  "Pop a literal from *FORM-STACK*."
  (when (null *form-stack*)
    (bst-compile-error "Empty form/literal stack"))
  (let ((mvform (pop *form-stack*)))
    (unless (mvform-literal mvform)
      (bst-compile-error "Expecting a literal on the stack, found a form ~S"
			 mvform))
    (mvform-literal mvform)))

;;; Packaging the computed data

(defun set-union (&rest lists)
  (reduce (lambda (a b)
	    (union a b :test 'equalp))
	  lists
	  :initial-value ()))

(defun package-as-body ()
  "Build a Lisp body corresponding to the computation captured in
*FORM-BINDINGS* and *FORM-STACK*.  The Lisp body contains free
variables corresponding to *BORROWED-VARIABLES*.  Return five values:
BODY, ARGUMENT-TYPES, RESULT-TYPES, SIDE-EFFECTS, and
FREE-VARIABLES."
  (let ((*form-stack* *form-stack*)
	(*form-bindings* *form-bindings*)
	(result-mvforms ()))
    (loop as mvform = (pop-single-value-form t :need-variable nil :when-empty nil) ; modifies the place *form-stack*
	  while mvform
	  do (push mvform result-mvforms))
    (let ((body (case (length result-mvforms)
		  (0 ())
		  (1 (list (mvform-form (car result-mvforms))))
		  (t (list `(values ,@(mapcar #'mvform-form result-mvforms))))))
	  (side-effects (apply #'max-side-effects (mapcar #'mvform-side-effects result-mvforms)))
	  (let-bindings ()))
      (labels ((make-let* ()
		 (when (not (null let-bindings))
		   (cond
		     ((and (= (length body) 1) (consp (car body)) (eql (caar body) 'do))
	     ;; body is a single DO form, so we put our bindings there
		      (destructuring-bind (do do-bindings &rest do-body)
			  (car body)
			(declare (ignore do))
			(setq body (list `(do* ,(nconc let-bindings do-bindings)
					   ,@do-body))
			      let-bindings ())))
		     (t 
		      (case (length let-bindings)
			(0 nil)
			(1 (setq body (list `(let ,let-bindings
					      ,@body))
				 let-bindings ()))
			(t (setq body (list `(let* ,let-bindings
					      ,@body))
				 let-bindings ()))))))))
	(dolist (binding *form-bindings*)
	  ;; don't keep track of references and assignments to lexical
	  ;; variables outside their scope:
	  (setq side-effects
		(remove-variables-from-side-effects
		 (mapcar #'variable-name (binding-variables binding))
		 (max-side-effects side-effects (mvform-side-effects (binding-mvform binding)))))
	  (case (length (binding-variables binding))
	    (0 (make-let*)
	       (setq body (cons (mvform-form (binding-mvform binding))
				body)))
	    (1 (let ((form (mvform-form (binding-mvform binding))))
		 (push (if (equal '(values) form)
			   ;; Lexical binding without useful values
			   (variable-name (car (binding-variables binding)))
			   ;; Lexical binding with useful values
			   `(,(variable-name (car (binding-variables binding)))
			     ,(mvform-form (binding-mvform binding))))
		       let-bindings)))
	    (t (make-let*)
	       (setq body
		     (list `(multiple-value-bind
			     ,(mapcar #'variable-name (binding-variables binding))
			     ,(mvform-form (binding-mvform binding))
			     ,@body))))))
	(make-let*)
	(values body
		(mapcar #'variable-type *borrowed-variables*)
		(mapcan #'mvform-types result-mvforms)
		side-effects
		(mapcar #'variable-name *borrowed-variables*))))))

(defun package-as-form ()
  "Build a Lisp form corresponding to the computation captured in
*FORM-BINDINGS* and *FORM-STACK*.  The Lisp form contains free
variables corresponding to *BORROWED-VARIABLES*.  Return four values:
LISP-FORM, ARGUMENT-TYPES, RESULT-TYPES, SIDE-EFFECTS."
  (multiple-value-bind (body argument-types result-types
			     side-effects free-variables)
      (package-as-body)
    (values (case (length body)
	      (0 `(values))
	      (1 (car body))
	      (t `(progn ,@body)))
	    argument-types result-types side-effects
	    free-variables)))
 
(defun package-as-procedure (name)
  "Build a DEFUN NAME form from *FORM-BINDINGS*, *BORROWED-VARIABLES*
and *FORM-STACK*.  If NAME is nil, build a LAMBDA form instead.
Return four values: DEFUN-OR-LAMBDA-FORM, ARGUMENT-TYPES,
RESULT-TYPES, SIDE-EFFECTS."
  (multiple-value-bind (body argument-types result-types
			     side-effects free-variables)
      (package-as-body)
    (values `(,@(if name `(defun ,name) `(lambda))
	      ,free-variables
	      ,@body)
	    argument-types result-types
	    (remove-variables-from-side-effects free-variables side-effects))))

(defun show-state ()
  (format t "~&;; *form-bindings*: ~S~%;; *form-stack*: ~S~%;; *borrowed-variables*: ~S~%;; procedure: ~:W~%"
	  *form-bindings*
	  *form-stack*
	  *borrowed-variables*
	  (package-as-procedure nil)))

;;; BST "special forms"

(defvar *bst-special-forms* (make-hash-table :test 'equalp)
  "A hashtable, mapping BST function symbols to thunks that implement
special forms by directly manipulating the current compiler data.")

(defmacro define-bst-special-form (bst-name &body body)
  `(setf (gethash ,bst-name *bst-special-forms*)
	 (lambda ()
	   ,@body)))

(define-bst-special-form "duplicate$"
    (let ((mvform (pop-single-value-form t :need-variable t)))
      (push-form mvform)
      (push-form mvform)))

(define-bst-special-form "swap$"
    (let* ((mvform-1 (pop-single-value-form t :need-variable :if-side-effects))
	   (mvform-2 (pop-single-value-form t :need-variable :if-side-effects)))
      (push-form mvform-1)
      (push-form mvform-2)))

(define-bst-special-form "="
    (multiple-value-bind (form-1 type-1 side-effects-1)
	(pop-form t :need-variable nil)
      (multiple-value-bind (form-2 type-2 side-effects-2)
	  (pop-form type-1 :need-variable nil)
	(let ((form (cond
		      ((type= type-2 '(boolean))
		       `(eql ,form-1 ,form-2))
		      ((type= type-2 '(integer))
		       `(= ,form-1 ,form-2))
		      ((type= type-2 '(string))
		       `(string= ,form-1 ,form-2))
		      (t
		       `(equal ,form-1 ,form-2)))))
	  (push-mvform :form form
		       :types (list '(boolean))
		       :side-effects
		       (max-side-effects side-effects-1
					 side-effects-2))))))

(define-bst-special-form ":="
    (let ((var (pop-literal)))
      ;;(format t "var: ~S value: ~S~%" var value-form)
      (let* ((fun (get-bst-function var))
	     (name (bst-function-name fun))
	     assoc)
	(labels ((compute-side-effects (assigned-thing value-mvform)
		   (max-side-effects
		    (mvform-side-effects value-mvform)
		    (make-instance 'side-effects
				   :assigned-variables (list assigned-thing)
				   :unconditionally-assigned-variables (list assigned-thing)))))
	  (cond
	    ((setq assoc (assoc name *lexical-variables* :test 'string-equal))
	     (let ((var-name (variable-name (cdr assoc)))
		   (value-mvform (pop-single-value-form t :need-variable nil)))
	       (push-mvform :form `(setq ,var-name
				    ,(mvform-form value-mvform))
			    :types ()
			    :side-effects (compute-side-effects var-name value-mvform))))
	    ((member (bst-function-name fun) *lexicals* :test 'string-equal)
	     (let ((var (make-variable :name (bst-name-to-lisp-name name)
				       :type (car (bst-function-result-types fun))))
		   (value-mvform (pop-single-value-form t :need-variable nil :when-empty nil)))
	       (if (not value-mvform)
		   ;; We have an assignment of a freshly popped formal
		   ;; argument to a lexical variable.  So simply use
		   ;; the lexical variable as the formal argument.
		   (push var *borrowed-variables*)
		   ;; Make a lexical binding.
		   (push (make-binding :variables (list var)
				       :mvform value-mvform) *form-bindings*))
	       (push (cons name var) *lexical-variables*)))
	    (t
	     (let* ((setter-form-maker (bst-function-setter-form-maker fun))
		    (value-mvform (pop-single-value-form t :need-variable nil))
		    (setter-form (funcall setter-form-maker (mvform-form value-mvform))))
	       (push-mvform
		:form setter-form :types ()
		:side-effects (compute-side-effects name value-mvform)))))))))

(defun get-bst-function (name)
  (let ((function (gethash (string name) *bst-functions*)))
    (unless function
      (bst-compile-error "~A is an unknown function" name))
    function))

(defun bst-compile-literal (literal stack &key (borrowing-allowed t))
  "Compile a BST function LITERAL, which is a symbol, designating a
BST function, or a list (a function body).  Return five values: a Lisp
FORM, ARGUMENT-TYPES, RESULT-TYPES, SIDE-EFFECTS-P, and FREE-VARIABLES."
  (let ((*form-stack* stack)
	(*borrowed-variables* ())
	(*form-bindings* ()))
    (etypecase literal
      (symbol (compile-funcall literal))
      (cons (compile-body literal)))
    (assert (or borrowing-allowed 
		(null *borrowed-variables*)))
    (package-as-form)))

(defvar *compiling-while-body* nil
  "True if compiling the body of a while$ function.")

(define-bst-special-form "if$"
    (let* ((else-literal (pop-literal))
	   (then-literal (pop-literal))
	   (val-mvform (pop-single-value-form '(boolean) :need-variable :if-side-effects)))
      ;; Side effects matter because our Lisp code beautifier reorders
      ;; the tested conditions to its liking.

      ;; First pass: compute the arity of both branches
      (multiple-value-bind (else-form else-arg-types else-res-types else-side-effects)
	  (let ((*lexicals* ())) ; don't introduce local lexical bindings
	    (bst-compile-literal else-literal ()))
;;(format t "~&;; else-form ~S is ~S --> ~S~%" else-literal else-arg-types else-res-types)
	(multiple-value-bind (then-form then-arg-types then-res-types then-side-effects)
	    (let ((*lexicals* ())) ; don't introduce local lexical bindings
	      (bst-compile-literal then-literal ()))
;;(format t "~&;; then-form ~S is ~S --> ~S~%" then-literal then-arg-types then-res-types)
	  ;; Introduce lexical binding for the union of all
	  ;; assigned-to variables in both branches.
	  (let ((assigned-variables
		 (set-union (side-effects-assigned-variables then-side-effects)
			    (side-effects-assigned-variables else-side-effects))))
	    (dolist (name assigned-variables)
	      (when (and (stringp name)
			 (member name *lexicals* :test 'string-equal)
			 (not (assoc name *lexical-variables*)))
		(let* ((fun (get-bst-function name))
		       (var (make-variable :name (bst-name-to-lisp-name name)
					   :type (car (bst-function-result-types fun)))))
		  (push (cons name var) *lexical-variables*)
		  (push (make-binding :variables (list var)
				      :mvform (make-mvform :form `(values) :types nil))
			*form-bindings*)))))
	  ;; Now we know the arity of both branches.  
	  (let ((arg-types ())
		(then-balance (- (length then-res-types) (length then-arg-types)))
		(else-balance (- (length else-res-types) (length else-arg-types)))
		(then-stack ())
		(else-stack ()))
	    (cond ((= then-balance else-balance)
		   ;; This is the regular case: We have the same
		   ;; net number of values pushed to the stack.
		   ;; We compute the arg types and fill up the
		   ;; shorter arg list.
		   (do ((then-arg-types (reverse then-arg-types) (cdr then-arg-types))
			(else-arg-types (reverse else-arg-types) (cdr else-arg-types)))
		       ((and (null then-arg-types) (null else-arg-types))
			(setq arg-types (nreverse arg-types)
			      then-stack (nreverse then-stack)
			      else-stack (nreverse else-stack)))
		     (let* ((type (type-intersection
				   (if then-arg-types (car then-arg-types) t)
				   (if else-arg-types (car else-arg-types) t)))
			    (form (pop-single-value-form type
							 :need-variable :if-side-effects)))
		       (push type arg-types)
		       (push form then-stack)
		       (push form else-stack))))
		  ((and *compiling-while-body*
			(> else-balance 0)
			(= (length then-res-types) (length else-res-types)))
		   ;; This is a special hack that allows us to compile
		   ;; the FORMAT.NAMES function.  This function has a
		   ;; WHILE$ that pushes exactly one value over all
		   ;; runs; this is accomplished by an IF$ whose THEN
		   ;; branch is STRING->STRING and whose ELSE branch
		   ;; is NIL->STRING.
		   ;; FIXME: This could be easily generalized on a better day.
		   (format *error-output*
			   "While compiling wizard-defined function `~S':~% Warning: Employing the producer/modifier while loop trick.~%"
			   *currently-compiled-function*)			   
		   (do ((then-arg-types (reverse then-arg-types) (cdr then-arg-types))
			(else-arg-types (reverse else-arg-types) (cdr else-arg-types)))
		       ((and (null then-arg-types) (null else-arg-types))
			(setq arg-types (nreverse arg-types)
			      then-stack (nreverse then-stack)
			      else-stack (nreverse else-stack)))
		     (let* ((type (type-intersection
				   (if then-arg-types (car then-arg-types) t)
				   (if else-arg-types (car else-arg-types) t)))
			    (form (pop-single-value-form type
							 :need-variable :if-side-effects)))
		       (push type arg-types)
		       (push form then-stack)
		       (unless (null else-arg-types)
			 (push form else-stack))))
		   ;;(format *error-output* "~&ARG-TYPES: ~S~%THEN-STACK: ~S~%ELSE-STACK: ~S~%"
		   ;; arg-types then-stack else-stack))
		   (setq *compiling-while-body* else-balance))
		  (t
		   (bst-compile-error "THEN function ~S ~%== ~S and ELSE function ~S ~%== ~S deliver ~
different net number of values: ~%~A -> ~A vs. ~A -> ~A"
				      then-literal then-form else-literal else-form
				      then-arg-types then-res-types
				      else-arg-types else-res-types)))
	    (multiple-value-bind (else-form else-arg-types
					    else-res-types else-side-effects)
		(bst-compile-literal else-literal else-stack :borrowing-allowed nil)
	      (declare (ignore else-arg-types))
	      (multiple-value-bind (then-form then-arg-types
					      then-res-types then-side-effects)
		  (bst-compile-literal then-literal then-stack :borrowing-allowed nil)
		(declare (ignore then-arg-types))
		(let* ((res-types (mapcar #'type-union then-res-types else-res-types))
		       (side-effects
			(max-side-effects (mvform-side-effects val-mvform)
					  then-side-effects else-side-effects)))
		  (setf (side-effects-unconditionally-assigned-variables side-effects)
			(union (side-effects-unconditionally-assigned-variables
				(mvform-side-effects val-mvform))
			       (intersection (side-effects-unconditionally-assigned-variables then-side-effects)
					     (side-effects-unconditionally-assigned-variables else-side-effects)
					     :test 'equalp)
			       :test 'equalp))
		  (push-mvform :form (build-if-form (mvform-form val-mvform) then-form else-form)
			       :types res-types
			       :side-effects side-effects)))))))))   

(define-bst-special-form "pop$"
    (pop-form t :need-variable :if-side-effects))

(define-bst-special-form "skip$"
    nil)

(defun bst-compile-literal-as-while-body (literal)
  "Compile a BST function LITERAL, which is a symbol, designating a
BST function, or a list (a function body).  Return five values: a Lisp
BODY, LOOP-VARS, LOOP-VAR-TYPES, INIT-TYPES and SIDE-EFFECTS."
  (let ((*form-stack* ())
	(*borrowed-variables* ())
	(*form-bindings* ())
	(*compiling-while-body* t))
    (etypecase literal
      (symbol (compile-funcall literal))
      (cons (compile-body literal)))
    (let* ((mvforms (mapcar (lambda (var)
			      (pop-single-value-form (variable-type var)))
			    (reverse *borrowed-variables*)))
	   (psetq-args (mapcan (lambda (var mvform)
				 (list (variable-name var)
				       (mvform-form mvform)))
			       (reverse *borrowed-variables*)
			       mvforms))
	   (assigned-variables
	    (mapcar #'variable-name *borrowed-variables*))
	   (side-effects
	    (apply #'max-side-effects
		   (make-instance 'side-effects :assigned-variables assigned-variables)
		   (mapcar #'mvform-side-effects mvforms))))			      
      (case (length *borrowed-variables*)
	(0 nil)
	(1 (push-mvform :form `(setq ,@psetq-args)
			:types () 
			:side-effects side-effects))
	(t (push-mvform :form `(psetq ,@psetq-args)
			:types ()
			:side-effects side-effects))))
    (multiple-value-bind (body arg-types res-types
			       side-effects free-variables)
	(package-as-body)
      (unless (null res-types)
	;; Since the while-body packager eats as many values as the
	;; function takes, so we only check whether there remain
	;; values...
	(bst-compile-error "BODY function ~S is not stack-balanced: ~S --> ~S"
			   literal arg-types res-types))
      (values body free-variables
	      arg-types
	      (if (numberp *compiling-while-body*)
		  ;; this many are uninitialized
		  (nbutlast arg-types *compiling-while-body*)
		  arg-types)
	      side-effects))))      

(define-bst-special-form "while$"
    (let* ((body-literal (pop-literal))
	   (pred-literal (pop-literal)))
      (multiple-value-bind (pred-form pred-arg-types
				      pred-res-types pred-side-effects)
	  (bst-compile-literal pred-literal ())
	(unless (null pred-arg-types)
	  (bst-compile-error "PREDICATE function ~S takes stack values: ~S"
			     pred-literal pred-arg-types))
	(unless (and (= (length pred-res-types) 1)
		     (type= (car pred-res-types) '(boolean)))
	  (bst-compile-error "PREDICATE function ~S does not deliver exactly one boolean stack value: ~S"
			     pred-literal pred-res-types))
	(multiple-value-bind (body loop-vars loop-var-types init-types
				   body-side-effects)
	    (bst-compile-literal-as-while-body body-literal)
	  ;; filter out locals from the list of variables assigned to
	  ;; in the body
	  (setq body-side-effects
		(remove-variables-from-side-effects loop-vars body-side-effects))
	  (let ((init-clauses
		 (loop for var in loop-vars
		       as types = init-types then (cdr types)
		       collect (if (null types)
				   var
				   `(,var
				     ,(pop-form (car types))))))
		(values-body
		 (case (length loop-var-types)
		   (0 ())
		   (1 (list (car loop-vars)))
		   (2 (list `(values ,@loop-vars)))))
		(side-effects
		 (max-side-effects pred-side-effects body-side-effects)))
	    ;; Only pred is guaranteed to execute, so:
	    (setf (side-effects-unconditionally-assigned-variables side-effects)
		  (side-effects-unconditionally-assigned-variables pred-side-effects))
	    (push-mvform :form `(do ,init-clauses
				 (,(build-not-form pred-form) ,@values-body)
				 ,@body)
			 :types loop-var-types
			 :side-effects side-effects)))))) 


;;;

(defun compile-funcall (function-name)
  (let (it)
    (cond
      ((setq it (gethash (string function-name) *bst-special-forms*))
       (funcall it))
      ((setq it (assoc (string function-name) *lexical-variables* :test 'string-equal))
       (let ((var-name (variable-name (cdr it))))
       (push-mvform :form var-name
		    :types (list (variable-type (cdr it)))
		    :side-effects
		    (make-instance 'side-effects
				   :used-variables (list var-name)))))
      (t
       (let* ((bst-function (get-bst-function function-name))
	      (arg-types (bst-function-argument-types bst-function))
	      (arg-mvforms (nreverse
			    (mapcar (lambda (type)
				      (pop-single-value-form type :need-variable nil))
				    (reverse arg-types)))))
	 (push-mvform
	  :form (if (bst-function-lisp-form-maker bst-function)
		    (apply (bst-function-lisp-form-maker bst-function)
			   (mapcar #'mvform-form arg-mvforms))
		    (cons (bst-function-lisp-name bst-function)
			  (mapcar #'mvform-form arg-mvforms)))
	  :types (bst-function-result-types bst-function)
	  :side-effects (apply #'max-side-effects
			       (bst-function-side-effects bst-function)
			       (mapcar #'mvform-side-effects arg-mvforms))))))))

(defun compile-body (body)
  (let ((*currently-compiled-body* body))
    (do ((rest body (cdr rest)))
	((null rest))
      (let ((form (car rest))
	    (*currently-compiled-body-rest* rest))
	(cond
	  ((numberp form)
	   (push-mvform :form form :types '((integer))))
	  ((stringp form)
	   (push-mvform :form form :types '((string))))
	  ((symbolp form)		;function call
	   (compile-funcall form))
	  ((and (consp form) (eql (car form) 'quote)) ; quoted function
	   (push-mvform :literal (cadr form) :types '((symbol))))
	  ((consp form)			; function body
	   (push-mvform :literal form :types '((body))))
	  (t (bst-compile-error "Illegal form in BST function body: ~S" form)))))))

(defun bst-compile-defun (name function-definition)
  "Compile a BST wizard-defined function of given NAME and
FUNCTION-DEFINITION.  If NAME is nil, build a lambda expression,
rather than a defun form.  Return four values: DEFUN-OR-LAMBDA-FORM,
ARGUMENT-TYPES, RESULT-TYPES, SIDE-EFFECTS."
  (let ((*borrowed-variables* ())
	(*form-bindings* ())
	(*form-stack* ())
	(*lexical-variables* ())
	(*bst-gentemp-counter* 0))
    (compile-body function-definition)
    (package-as-procedure name)))

(defun bst-compile-thunkcall (bst-name)
  "Build a Lisp form for calling the BST function named BST-NAME."
  (let ((*borrowed-variables* ())
	(*form-bindings* ())
	(*lexical-variables* ())
	(*form-stack* ()))
    (compile-body (list bst-name))
    (package-as-form)))	

(defun compile-bst-function (bst-name function-definition stream)
  (let ((*currently-compiled-function* bst-name)
	(lisp-name (bst-name-to-lisp-name bst-name)))
    (handler-case 
	(multiple-value-bind (defun-form argument-types
				 result-types side-effects)
	    (bst-compile-defun lisp-name function-definition)
	  (format stream
		  "~%~<;; ~@;~:S --> ~:S ~:[~;with side-effects ~]~:[~;~%with assignment to~:*~{ ~S~}~]~:[~;~%with possible assignment to~:*~{ ~S~}~]~:[~;~%with reference to~:*~{ ~S~}~]~:>"
		  (list argument-types result-types
			(side-effects-side-effects-p side-effects)
			(side-effects-unconditionally-assigned-variables side-effects)
			(set-difference (side-effects-assigned-variables side-effects)
					(side-effects-unconditionally-assigned-variables side-effects)
					:test 'equalp)			
			(side-effects-used-variables side-effects)))
	  (lisp-write defun-form)
	  (setf (gethash (string bst-name) *bst-functions*)
		(make-bst-function :name (string bst-name)
				   :lisp-name lisp-name
				   :type 'compiled-wiz-defined
				   :argument-types argument-types
				   :result-types result-types
				   :side-effects side-effects)))
      (bst-compiler-error (condition)
	(format *error-output*
		"While compiling wizard-defined function `~S':~%~A~%"
		bst-name (bst-compiler-error-message condition))))))

(defun compile-bst-fun (definition &key int-vars str-vars)
  "A debugging aid."
  (let ((*bib-macros* (make-hash-table))
	(*bst-compiling* t)
	(*bst-functions* (builtin-bst-functions)))
    (dolist (var int-vars)
      (register-bst-global-var var var 'int-global-var '(integer) 0 *bst-functions*))
    (dolist (var str-vars)
      (register-bst-global-var var var 'str-global-var '(string) "" *bst-functions*))
    (bst-compile-defun nil definition)))

#|

(compile-bst-fun '(1 duplicate$ + duplicate$ -))
(register-bst-primitive "side.effect" '((string)) '((string)) 'side-effect)
(register-bst-primitive "side.effect.2" '((string)) '((string)) 'side-effect-2)
(compile-bst-fun '("foo" side.effect "bar" side.effect.2))
(compile-bst-fun '((1 2 >) (5 + swap$ 7 + swap$) while$))
(compile-bst-fun '((1 2 >) (3 + swap$ "baz" * swap$) while$))
(compile-bst-fun '(1 1 (pop$ "et al" *) (pop$ "foo" *) if$))
(compile-bst-fun '(pop$ "et al" *))
(compile-bst-fun '("can't use both volume and number if series info is missing"
		   WARNING$ "in BibTeX entry type `" TYPE$ * "'" * TOP$))
(compile-bst-fun '("abc" top$))
(compile-bst-fun '(1 (1 'global.max$ |:=|) (newline$) if$) )

(with-input-from-string (*bst-stream* "{ booktitle empty$ { \"\" } { editor empty$ { booktitle } { booktitle add.space.if.necessary \"(\" * format.nonauthor.editors * \")\" * } if$ } if$ } ")
  (bst-read))
(compile-bst-fun '(crossref EMPTY$ ("")
 (crossref EMPTY$ (crossref)
  (crossref "A" "(" * 1 'global.max$ |:=| * ")" *)
  IF$)
 IF$))

(with-input-from-string (*bst-stream* "{ 's :=
  #1 'nameptr :=
  s num.names$ 'numnames :=
  numnames 'namesleft :=
    { namesleft #0 > }
    { \"Foo\" 't :=
      nameptr #1 >
	{ \"x\" * } 
	't
      if$
      nameptr #1 + 'nameptr :=
    }
  while$
} ")
  (let ((f (bst-read)))
    (compile-bst-fun f :int-vars '(numnames nameptr namesleft) :str-vars '(s t))))
  
		

|#

