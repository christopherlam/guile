;;;; buffered-input.scm --- construct a port from a buffered input reader
;;;;
;;;; 	Copyright (C) 2001 Free Software Foundation, Inc.
;;;; 
;;;; This program is free software; you can redistribute it and/or modify
;;;; it under the terms of the GNU General Public License as published by
;;;; the Free Software Foundation; either version 2, or (at your option)
;;;; any later version.
;;;; 
;;;; This program is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;;; GNU General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU General Public License
;;;; along with this software; see the file COPYING.  If not, write to
;;;; the Free Software Foundation, Inc., 59 Temple Place, Suite 330,
;;;; Boston, MA 02111-1307 USA

(define-module (ice-9 buffered-input)
  #:export (make-line-buffered-input-port
            set-buffered-input-continuation?!))

;; @code{buffered-input-continuation?} is a property of the ports
;; created by @code{make-line-buffered-input-port} that stores the
;; read continuation flag for each such port.
(define buffered-input-continuation? (make-object-property))

(define (set-buffered-input-continuation?! port val)
  "Set the read continuation flag for @var{port} to @var{val}.

See @code{make-line-buffered-input-port} for the meaning and use of
this flag."
  (set! (buffered-input-continuation? port) val))

(define (make-line-buffered-input-port reader)
  "Construct a line-buffered input port from the specified @var{reader}.
@var{reader} should be a procedure of one argument that somehow reads
a line of input and returns it as a string @emph{without} the
terminating newline character.

The port created by @code{make-line-buffered-input-port} automatically
adds a newline character after each string returned by @var{reader};
this makes these ports useful for reading strings that extend across
more than one input line.

@var{reader} should take a boolean @var{continuation?} argument.
@var{continuation?} indicates whether @var{reader} is being called to
start a logically new read operation (in which case
@var{continuation?} is @code{#f}) or to continue a read operation for
which some input has already been read (in which case
@var{continuation?} is @code{#t}).  Some @var{reader} implementations
use the @var{continuation?} argument to determine what prompt to
display to the user.

The new/continuation distinction is largely an application-level
concept, and @code{set-buffered-input-continuation?!} allows an
application some control over when a read operation is considered to
be new.  But note that if there is data already buffered in the port
when a new read operation starts, this data will be read before the
first call to @var{reader}, and so @var{reader} will be called with
@var{continuation?} set to @code{#t}."
  (let ((read-string "")
	(string-index -1))
    (letrec ((get-character
	      (lambda ()
		(cond 
		 ((eof-object? read-string)
		  read-string)
		 ((>= string-index (string-length read-string))
		  (set! string-index -1)
                  #\nl)
		 ((= string-index -1)
		  (set! read-string (reader (buffered-input-continuation? port)))
                  (set! string-index 0)
                  (if (not (eof-object? read-string))
                      (get-character)
                      read-string))
		 (else
		  (let ((res (string-ref read-string string-index)))
		    (set! string-index (+ 1 string-index))
                    (set! (buffered-input-continuation? port) #t)
		    res)))))
             (port #f))
      (set! port (make-soft-port (vector #f #f #f get-character #f) "r"))
      (set! (buffered-input-continuation? port) #f)
      port)))

;;; buffered-input.scm ends here
