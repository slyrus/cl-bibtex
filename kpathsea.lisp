;;; An interface to Kpathsea (TeX's file search library)
;;; Copr. 2002 Matthias Koeppe <mkoeppe@mail.math.uni-magdeburg.de>
;;; This is free software, licensed under GNU GPL (see file COPYING)

(in-package :kpathsea)

(defun find-file (name)
  #+cmu
  (let ((process
	 (extensions:run-program "kpsewhich" (list (namestring name))
				 :output :stream)))
    (prog1
	(parse-namestring 
	 (read-line (extensions:process-output process) nil nil))
      (extensions:process-close process)))
  #-cmu
  (error "FIND-FILE is not implemented"))


#|
(find-file "amsalpha.bst")
|#
