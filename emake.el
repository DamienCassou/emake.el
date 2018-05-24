;;; emake.el --- simple, transparent functionality for automated Elisp testing  -*- lexical-binding: t; -*-

;; Copyright (C) 2018  Sean Allred

;; Author: Sean Allred <code@seanallred.com>
;; Keywords: tools, lisp
;; Homepage: https://github.com/vermiculus/emake.el
;; Package-Version: 0.1

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Based on http://edkolev.github.io/posts/2017-09-10-travis-for-emacs-packages.html
;;
;; Emacs-Make is driven by environment variables to know what to do.
;; Before invoking `emake', ensure the following variables are set
;; appropriately:
;;
;;     PACKAGE_FILE     := the root file of your package
;;     PACKAGE_TESTS    := the root file to load your tests
;;     PACKAGE_LISP     := space-delimited list of Lisp files in this
;;                         package
;;     PACKAGE_ARCHIVES := space-delimited list of named ELPA archives;
;;                         see also `emake-package-archive-master-alist'
;;
;; There are certainly scenarios where a testing suite would want to
;; use special packages in its own right, but not require them for its
;; users.  For this case, a few more variables exist:
;;
;;     PACKAGE_TEST_DEPS     := space-delimited list of packages needed
;;                              by the test suite
;;     PACKAGE_TEST_ARCHIVES := like PACKAGE_ARCHIVES, but used for
;;                              installing PACKAGE_TEST_DEPS.
;;
;; To debug Emacs-Make, set the environment variable EMACS_MAKE_DEBUG_MODE.
;;
;; See the file README.org in this directory for more information and
;; minimal examples.

;;; Code:

(setq debug-on-error (string= "1" (getenv "EMACS_MAKE_DEBUG_MODE")))

(require 'package)
(require 'subr-x)
(require 'cl-lib)

(defun emake--message (format &rest args)
  "Print a message to standard out.
Argument FORMAT is a format string.  Optional argument ARGS is a
list of arguments for that format string."
  (apply #'message (concat "emake: " format) args))

(defvar emake-package-file
  (getenv "PACKAGE_FILE")
  "The Elisp file with package headers.")

(defvar emake-package-tests-file
  (getenv "PACKAGE_TESTS")
  "The Elisp file with test definitions.")

(defvar emake-package-desc
  (with-temp-buffer
    (insert-file-contents-literally emake-package-file)
    (package-buffer-info)))

(defvar emake-project-root
  (locate-dominating-file (or (file-name-directory emake-package-file)
                              default-directory)
                          emake-package-file)
  "The folder `emake-package-file' is in.")

(defun emake--clean-list (env)
  (when-let ((deps (getenv env)))
    (mapcar #'downcase (split-string deps nil 'omit-nulls))))

(defvar emake-package-archive-master-alist
  '(("gnu"          . "http://elpa.gnu.org/packages/")
    ("melpa"        . "http://melpa.org/packages/")
    ("melpa-stable" . "http://stable.melpa.org/packages/")
    ("org"          . "http://orgmode.org/elpa/"))
  "Archive definition alist.
Key is the string name of the archive.
Value is the URL at which the archive is hosted.")

(defvar emake-test-runner-master-alist
  '(("ert" . (progn (require 'ert) 'ert-run-tests-batch-and-exit))
    ("buttercup" . (progn (require 'buttercup) 'buttercup-run-discover)))
  "Test-runner definition alist.
Key is the string name of the test-runner.  Value is a form that,
when evaluated, produces a defined function that will run all
defined tests and exit Emacs with code 0 if and only if all tests
pass.")

(defmacro emake-task (description &rest body)
  "Run BODY wrapped by DESCRIPTION messages."
  (declare (indent 1) (debug t))
  (let ((Sdescription (cl-gensym)))
    `(let ((,Sdescription (concat ,description "...")))
       (prog2
           (emake--message ,Sdescription)
           (progn ,@body)
         (emake--message (concat ,Sdescription "done"))))))

(defmacro emake-with-elpa (&rest body)
  "Run BODY after setting up ELPA context."
  (declare (debug t))
  (emake--genform-with-elpa ".elpa" body "PACKAGE_ARCHIVES"))

(defmacro emake-with-elpa-test (&rest body)
  "Run BODY after setting up ELPA context."
  (declare (debug t))
  (emake--genform-with-elpa ".elpa.test" body "PACKAGE_TEST_ARCHIVES"))

(defun emake--genform-with-elpa (dir body archives-env)
  (let ((Sarchives (cl-gensym)))
    `(let* ((,Sarchives (emake--clean-list ,archives-env))
            (package-user-dir (expand-file-name ,dir emake-project-root))
            (package-archives (seq-filter (lambda (pair)
                                            (member (car pair) ,Sarchives))
                                          emake-package-archive-master-alist)))
       (emake-task "initializing package.el"
         (package-initialize))
       ,@body)))

(defun emake (target)
  "Run `emake-my-TARGET' if bound, else `emake-TARGET'."
  (let ((fun (intern (format "emake-my-%s" target))))
    (unless (fboundp fun)
      (setq fun (intern (format "emake-%s" target))))
    (unless (fboundp fun)
      (error "%S target not found" target))
    (emake--message (if command-line-args-left
                        "Running target %S with function `%S' with arguments %S"
                      "Running target %S with function `%S'")
                    target fun command-line-args-left)
    (apply fun (prog1 command-line-args-left
                 (setq command-line-args-left nil)))))

(defun emake-test (&optional test-runner)
  "Run all tests in \"PACKAGE-NAME-test.el\".
Optional argument TEST-RUNNER is a test-runner name in
`emake-test-runner-master-alist' or the name of a function that
runs the tests."
  (setq test-runner (or test-runner "ert"))
  (when-let ((test-dependencies (emake--clean-list "PACKAGE_TEST_DEPS")))
    (emake-with-elpa-test
     (emake-task (format "installing test suite dependencies into %s" package-user-dir)
       (package-refresh-contents)
       (emake--install (mapcar #'intern test-dependencies)))))
  (let ((entry (assoc-string test-runner emake-test-runner-master-alist)))
    (cond
     (entry
      (setq test-runner (eval (cdr entry))))
     ((fboundp (intern test-runner))
      (setq test-runner (intern test-runner)))
     (t
      (error "%S test-runner not defined" test-runner))))
  (emake--message "Detected test-runner as `%S'" test-runner)

  (unless (fboundp test-runner)
    (error "Test-runner not defined!"))

  (let ((default-directory emake-project-root))
    (emake-with-elpa
     (add-to-list 'load-path emake-project-root)
     (when (file-readable-p emake-package-tests-file)
       (emake-task (format "loading test definitions in %s" emake-package-tests-file)
         ;; add the package being tested to `load-path' so it can be required
         (add-to-list 'load-path (file-name-directory emake-package-tests-file))

         ;; load the file with tests
         (load emake-package-tests-file)))

     ;; run the tests and exit with an appropriate status
     (funcall test-runner))))

(defun emake-install ()
  "Install dependencies.
Required packages include those that `emake-package-file' lists as
dependencies."
  (emake-with-elpa
   (emake-task (format "installing in %s" package-user-dir)
     (package-refresh-contents)

     ;; install dependencies
     (emake--install
      (thread-last (package-desc-reqs emake-package-desc)
        (mapcar #'car)
        (delq 'emacs))))))

(defun emake--install (packages)
  (dolist (package packages)
    (unless (package-installed-p package)
      (ignore-errors
        (package-install package)))))

(defmacro emake-with-options (args options &rest body)
  "With ARGS, determine and bind OPTIONS while executing BODY.
OPTIONS is a list of (CLI-OPT BINDING [TRUE-VALUE]) lists.  If
CLI-OPT is present in ARGS, then BINDING will be bound to
TRUE-VALUE during execution of BODY."
  (declare (indent 2))
  (let (bindings (Sargs (cl-gensym)))
    (dolist (option options)
      (unless (member (length option) '(2 3))
        (error "Wrong number of arguments in spec %S" option))
      (let ((opt (car option))
            (var (cadr option))
            (val (or (= 2 (length option)) ; if there is no default value, use t
                     (caddr option))))
        (unless (stringp opt)
          (error "Option must be a string literal: %S" opt))
        (unless (symbolp var)
          (error "Binding must be a symbol literal: %S" var))
        (push (list var `(and (member ,(concat "~" opt) ,Sargs) ,val))
              bindings)))
    `(let ((,Sargs ,args))
       (let ,(nreverse bindings)
         ,@body))))

(defun emake-compile (&rest opts)
  "Compile all files in PACKAGE_LISP."
  (require 'bytecomp)
  (emake-with-options opts
      (("error-on-warn" byte-compile-error-on-warn))
    (let (compile-buffer)
      (emake--message "error-on-warn => %S" byte-compile-error-on-warn)
      (emake-with-elpa
       (add-to-list 'load-path emake-project-root)
       (dolist (f (emake--clean-list "PACKAGE_LISP"))
         (emake-task (format "compiling %s" f)
           (byte-compile-file f)
           (when (and byte-compile-error-on-warn
                      (setq compile-buffer (get-buffer byte-compile-log-buffer)))
             ;; double-check; e.g. (let (hi)) won't error otherwise
             (with-current-buffer compile-buffer
               (when (string-match "^.*:Warning: \\(.*\\)$" (buffer-string))
                 (error (match-string-no-properties 1 (buffer-string))))))))))))

(provide 'emake)
;;; emake.el ends here
