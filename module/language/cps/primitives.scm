;;; Continuation-passing style (CPS) intermediate language (IL)

;; Copyright (C) 2013 Free Software Foundation, Inc.

;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

;;; Commentary:
;;;
;;; Information about named primitives, as they appear in $prim and $primcall.
;;;
;;; Code:

(define-module (language cps primitives)
  #:use-module (ice-9 match)
  #:use-module ((srfi srfi-1) #:select (fold))
  #:use-module (srfi srfi-26)
  #:use-module (language rtl)
  #:export (prim-rtl-instruction
            branching-primitive?
            prim-arity
            ))

(define *rtl-instruction-aliases*
  '((+ . add) (1+ . add1)
    (- . sub) (1- . sub1)
    (* . mul) (/ . div)
    (quotient . quo) (remainder . rem)
    (modulo . mod)
    (variable-ref . box-ref)
    (variable-set! . box-set!)
    (bytevector-u8-native-ref . bv-u8-ref)
    (bytevector-u16-native-ref . bv-u16-ref)
    (bytevector-u32-native-ref . bv-u32-ref)
    (bytevector-u64-native-ref . bv-u64-ref)
    (bytevector-s8-native-ref . bv-s8-ref)
    (bytevector-s16-native-ref . bv-s16-ref)
    (bytevector-s32-native-ref . bv-s32-ref)
    (bytevector-s64-native-ref . bv-s64-ref)
    (bytevector-f32-native-ref . bv-f32-ref)
    (bytevector-f64-native-ref . bv-f64-ref)
    (bytevector-u8-native-set! . bv-u8-set!)
    (bytevector-u16-native-set! . bv-u16-set!)
    (bytevector-u32-native-set! . bv-u32-set!)
    (bytevector-u64-native-set! . bv-u64-set!)
    (bytevector-s8-native-set! . bv-s8-set!)
    (bytevector-s16-native-set! . bv-s16-set!)
    (bytevector-s32-native-set! . bv-s32-set!)
    (bytevector-s64-native-set! . bv-s64-set!)
    (bytevector-f32-native-set! . bv-f32-set!)
    (bytevector-f64-native-set! . bv-f64-set!)))

(define *macro-instruction-arities*
  '((cache-current-module! . (0 . 2))
    (cached-toplevel-box . (1 . 3))
    (cached-module-box . (1 . 4))))

(define *branching-primcall-arities*
  '((null? . (1 . 1))
    (nil? . (1 . 1))
    (pair? . (1 . 1))
    (struct? . (1 . 1))
    (string? . (1 . 1))
    (vector? . (1 . 1))
    (symbol? . (1 . 1))
    (variable? . (1 . 1))
    (bitvector? . (1 . 1))
    (bytevector? . (1 . 1))
    (char? . (1 . 1))
    (eq? . (1 . 2))
    (eqv? . (1 . 2))
    (equal? . (1 . 2))
    (= . (1 . 2))
    (< . (1 . 2))
    (> . (1 . 2))
    (<= . (1 . 2))
    (>= . (1 . 2))))

(define (compute-prim-rtl-instructions)
  (let ((table (make-hash-table)))
    (for-each
     (match-lambda ((inst . _) (hashq-set! table inst inst)))
     (instruction-list))
    (for-each
     (match-lambda ((prim . inst) (hashq-set! table prim inst)))
     *rtl-instruction-aliases*)
    (for-each
     (match-lambda ((inst . arity) (hashq-set! table inst inst)))
     *macro-instruction-arities*)
    table))

(define *prim-rtl-instructions* (delay (compute-prim-rtl-instructions)))

;; prim -> rtl-instruction | #f
(define (prim-rtl-instruction name)
  (hashq-ref (force *prim-rtl-instructions*) name))

(define (branching-primitive? name)
  (and (assq name *branching-primcall-arities*) #t))

(define *prim-arities* (make-hash-table))

(define (prim-arity name)
  (or (hashq-ref *prim-arities* name)
      (let ((arity (cond
                    ((prim-rtl-instruction name) => rtl-instruction-arity)
                    ((assq name *branching-primcall-arities*) => cdr)
                    (else
                     (error "Primitive of unknown arity" name)))))
        (hashq-set! *prim-arities* name arity)
        arity)))
