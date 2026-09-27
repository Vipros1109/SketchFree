;;; ==========================================================================
;;;  SketchLine.lsp  v6  -  converts lines, polylines, splines, arcs,
;;;                         circles, ellipses and hatches into
;;;                         "hand-sketched" lines
;;; --------------------------------------------------------------------------
;;;  Commands:
;;;    SKETCHLINE  - select objects and convert them
;;;    SKETCHTEXT  - select TEXT / MTEXT and give it a hand-lettered look
;;;    SKETCHSET   - style preset [Fine/Medium/Rough/Loose/Custom]
;;;
;;;  v2: endpoints pinned, no bow, wobble in % of line length
;;;  v3: HATCH support (pattern hatches exploded into sketched lines)
;;;  v4: variability, micro jitter, end freedom, "Loose" preset
;;;  v5: SPLINE support - the curve is sampled along its length and the
;;;      wobble is applied perpendicular to the curve at every point.
;;;      The same method also handles ARC, CIRCLE and ELLIPSE.
;;;      Closed curves: overshoot continues along the curve past the seam,
;;;      like a hand-drawn circle.
;;;
;;;  v6: SKETCHTEXT - hand-lettered look for TEXT and MTEXT. Every
;;;      character becomes its own TEXT object with a small random baseline
;;;      shift, rotation, height and spacing, plus a slow wave of the whole
;;;      text line (writing without a ruler). MTEXT is exploded to TEXT first.
;;;
;;;  Supported by SKETCHLINE: LINE, LWPOLYLINE (straight segments), SPLINE,
;;;             ARC, CIRCLE, ELLIPSE, HATCH (pattern hatches)
;;;  Supported by SKETCHTEXT: TEXT, MTEXT
;;;  Curves are expected to lie in a plane parallel to WCS XY (2D drafting).
;;; ==========================================================================

(vl-load-com)

;;; ---------- presets (values in % of length; var = 0..1) -------------------
;;;                        drift tremor jitter endfree overshoot variab.
(defun sk:preset (name)
  (cond
    ((= name "Fine")   (sk:setp 0.25 0.08 0.00 0.0 0.0 0.3)
                       (sk:setx 2.0 1.5 3.0 3.0 3.0))
    ((= name "Medium") (sk:setp 0.60 0.15 0.03 0.0 0.0 0.5)
                       (sk:setx 3.5 3.0 5.0 5.0 5.0))
    ((= name "Rough")  (sk:setp 1.20 0.30 0.08 0.5 1.5 0.6)
                       (sk:setx 5.0 4.0 7.0 6.0 7.0))
    ((= name "Loose")  (sk:setp 1.00 0.35 0.12 1.0 1.0 0.9)
                       (sk:setx 6.0 5.0 8.0 8.0 8.0))
  )
  (setq *sk:style* name)
)
(defun sk:setp (r tr j e o v)
  (setq *sk:rough* r *sk:trem* tr *sk:jit* j *sk:endf* e *sk:ovr* o *sk:var* v)
)
;;;  text: baseline % of height, rotation deg, height %, spacing % of height,
;;;        slow baseline wave % of height
(defun sk:setx (bl ro hs sp dr)
  (setq *sk:tbl* bl *sk:trot* ro *sk:ths* hs *sk:tsp* sp *sk:tdr* dr)
)

(defun sk:init ()
  (if (or (null *sk:style*) (null *sk:jit*)) (sk:preset "Fine"))
  (if (null *sk:tbl*) (sk:setx 2.0 1.5 3.0 3.0 3.0))
  (if (null *sk:cap*) (setq *sk:cap* 0.0))
  (if (null *sk:str*) (setq *sk:str* 1))
  (if (null *sk:del*) (setq *sk:del* "Yes"))
  (if (null *sk:seed*)
    (setq *sk:seed*
      (if (getvar "MILLISECS")
        (float (1+ (rem (getvar "MILLISECS") 2147483646)))
        (float (1+ (fix (* 1e7 (rem (getvar "DATE") 1.0)))))
      )
    )
  )
)

;;; ---------- pseudo-random generator (Park-Miller) -------------------------
(defun sk:rand ()
  (setq *sk:seed* (rem (* *sk:seed* 16807.0) 2147483647.0))
  (/ *sk:seed* 2147483647.0)
)
(defun sk:rnd (a b) (+ a (* (- b a) (sk:rand))))

;;; ---------- smooth 1D value noise -----------------------------------------
(defun sk:noise-make (len wl / lst)
  (repeat (+ 3 (fix (/ len wl)))
    (setq lst (cons (sk:rnd -1.0 1.0) lst))
  )
  lst
)

(defun sk:noise (knots d wl / tt i f v0 v1)
  (setq tt (/ d wl)
        i  (fix tt)
        f  (- tt i)
        f  (/ (- 1.0 (cos (* pi f))) 2.0)
        v0 (nth i knots)
        v1 (nth (1+ i) knots)
  )
  (if (null v0) (setq v0 0.0))
  (if (null v1) (setq v1 v0))
  (+ v0 (* (- v1 v0) f))
)

;;; ---------- envelope: 0 at the endpoints, 1 in the middle ----------------
(defun sk:env (s / e x)
  (setq e 0.08
        x (min 1.0 (/ s e) (/ (- 1.0 s) e)))
  (if (<= x 0.0)
    0.0
    (* x x (- 3.0 (* 2.0 x))))
)

;;; ---------- random stroke parameters for a path of length len -------------
;;;  returns (a1 a2 a3 e1 e2 wl1 wl2 os1 os2)
(defun sk:params (len hmode / f1 f2 a1 a2 a3 e1 e2 ov)
  (setq f1 (max 0.0 (+ 1.0 (* *sk:var* (sk:rnd -1.0 1.0))))
        f2 (max 0.0 (+ 1.0 (* *sk:var* (sk:rnd -1.0 1.0))))
        a1 (* len (/ *sk:rough* 100.0) f1)
        a2 (* len (/ *sk:trem* 100.0) f2)
        a3 (* len (/ *sk:jit* 100.0))
        e1 (* len (/ *sk:endf* 100.0) (sk:rnd -1.0 1.0))
        e2 (* len (/ *sk:endf* 100.0) (sk:rnd -1.0 1.0))
        ov (if hmode 0.0 (* len (/ *sk:ovr* 100.0)))
  )
  (if (> *sk:cap* 0.0)
    (setq a1 (min a1 *sk:cap*)
          a2 (min a2 (* 0.5 *sk:cap*))
          a3 (min a3 (* 0.25 *sk:cap*)))
  )
  (list a1 a2 a3 e1 e2
        (/ len (sk:rnd 1.5 4.5))
        (/ len (if hmode (sk:rnd 8.0 16.0) (sk:rnd 25.0 55.0)))
        (* ov (sk:rand))
        (* ov (sk:rand)))
)

;;; ---------- lateral offset at position d of a stroke ---------------------
(defun sk:lat (P kn1 kn2 d s / sc)
  (setq sc (max 0.0 (min 1.0 s)))
  (+ (* (sk:env s)
        (+ (* (nth 0 P) (sk:noise kn1 d (nth 5 P)))
           (* (nth 1 P) (sk:noise kn2 d (nth 6 P)))
           (* (nth 2 P) (sk:rnd -1.0 1.0))))
     (* (nth 3 P) (- 1.0 sc))
     (* (nth 4 P) sc))
)

;;; ---------- one sketched stroke along a straight segment -----------------
(defun sk:stroke (p1 p2 hmode / len ux uy nx ny P os1 L kn1 kn2 n k d along lat pts)
  (setq len (distance (list (car p1) (cadr p1)) (list (car p2) (cadr p2))))
  (if (> len 1e-8)
    (progn
      (setq ux  (/ (- (car p2) (car p1)) len)
            uy  (/ (- (cadr p2) (cadr p1)) len)
            nx  (- uy)
            ny  ux
            P   (sk:params len hmode)
            os1 (nth 7 P)
            L   (+ len os1 (nth 8 P))
            kn1 (sk:noise-make L (nth 5 P))
            kn2 (sk:noise-make L (nth 6 P))
            n   (if hmode 36 (max 20 (min 400 (fix (/ L (/ (nth 6 P) 3.0))))))
            k   0
      )
      (while (<= k n)
        (setq d     (* L (/ (float k) n))
              along (- d os1)
              lat   (sk:lat P kn1 kn2 d (/ along len))
              pts   (cons (list (+ (car p1) (* ux along) (* nx lat))
                                (+ (cadr p1) (* uy along) (* ny lat)))
                          pts)
              k     (1+ k)
        )
      )
      (reverse pts)
    )
  )
)

;;; ---------- point + unit normal on a curve at distance d -----------------
;;;  returns (x y nx ny); handles d outside [0,len] (extension or wrap)
(defun sk:cpt (obj d len closed / par p dv m tx ty ext)
  (setq ext 0.0)
  (if closed
    (setq d (rem (+ d len len) len))
  )
  (cond
    ((< d 0.0)
     (setq par (vlax-curve-getStartParam obj) ext d))
    ((>= d len)
     (setq par (vlax-curve-getEndParam obj) ext (- d len)))
    (T
     (setq par (vlax-curve-getParamAtDist obj d)))
  )
  (if (null par) (setq par (vlax-curve-getEndParam obj)))
  (setq p  (vlax-curve-getPointAtParam obj par)
        dv (vlax-curve-getFirstDeriv obj par)
        m  (sqrt (+ (* (car dv) (car dv)) (* (cadr dv) (cadr dv))))
  )
  (if (> m 1e-12)
    (setq tx (/ (car dv) m) ty (/ (cadr dv) m) *sk:lastt* (list tx ty))
    (setq tx (car *sk:lastt*) ty (cadr *sk:lastt*))
  )
  (list (+ (car p) (* tx ext))
        (+ (cadr p) (* ty ext))
        (- ty)
        tx)
)

;;; ---------- one sketched stroke along a curve (SPLINE/ARC/CIRCLE/ELLIPSE) --
(defun sk:cstroke (obj / len closed P os1 L kn1 kn2 n k d along lat r pts)
  (setq len    (vlax-curve-getDistAtParam obj (vlax-curve-getEndParam obj))
        closed (vlax-curve-isClosed obj)
        *sk:lastt* '(1.0 0.0))
  (if (and len (> len 1e-8))
    (progn
      (setq P   (sk:params len nil)
            os1 (nth 7 P)
            L   (+ len os1 (nth 8 P))
            kn1 (sk:noise-make L (nth 5 P))
            kn2 (sk:noise-make L (nth 6 P))
            n   (max 40 (min 800 (fix (/ L (/ (nth 6 P) 3.0)))))
            k   0
      )
      (while (<= k n)
        (setq d     (* L (/ (float k) n))
              along (- d os1)
              lat   (sk:lat P kn1 kn2 d (/ along len))
              r     (sk:cpt obj along len closed)
              pts   (cons (list (+ (nth 0 r) (* (nth 2 r) lat))
                                (+ (nth 1 r) (* (nth 3 r) lat)))
                          pts)
              k     (1+ k)
        )
      )
      (reverse pts)
    )
  )
)

;;; ---------- create LWPOLYLINE ---------------------------------------------
(defun sk:make (pts z props)
  (if (> (length pts) 1)
    (entmakex
      (append
        (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity"))
        props
        (list '(100 . "AcDbPolyline")
              (cons 90 (length pts))
              '(70 . 0)
              (cons 38 z))
        (mapcar '(lambda (p) (cons 10 p)) pts)
      )
    )
  )
)

(defun sk:props (ed codes)
  (vl-remove nil (mapcar '(lambda (c) (assoc c ed)) codes))
)

;;; ---------- segments of a LINE / LWPOLYLINE -------------------------------
(defun sk:segments (ed / typ vts segs)
  (setq typ (cdr (assoc 0 ed)))
  (cond
    ((= typ "LINE")
     (list (list (cdr (assoc 10 ed)) (cdr (assoc 11 ed))))
    )
    ((= typ "LWPOLYLINE")
     (foreach g ed (if (= (car g) 10) (setq vts (cons (cdr g) vts))))
     (setq vts (reverse vts))
     (if (= 1 (logand 1 (cdr (assoc 70 ed))))
       (setq vts (append vts (list (car vts))))
     )
     (while (cdr vts)
       (setq segs (cons (list (car vts) (cadr vts)) segs)
             vts  (cdr vts))
     )
     (reverse segs)
    )
  )
)

;;; ---------- convert one LINE / LWPOLYLINE entity --------------------------
(defun sk:convert (ed hmode strokes / typ z props)
  (setq typ (cdr (assoc 0 ed))
        z   (if (= typ "LINE")
              (caddr (cdr (assoc 10 ed)))
              (cond ((cdr (assoc 38 ed))) (0.0)))
        props (sk:props ed (if (= typ "LWPOLYLINE")
                             '(410 8 6 62 420 370 48 210)
                             '(410 8 6 62 420 370 48)))
  )
  (foreach seg (sk:segments ed)
    (repeat strokes
      (sk:make (sk:stroke (car seg) (cadr seg) hmode) z props)
    )
  )
)

;;; ---------- convert one curve entity (SPLINE/ARC/CIRCLE/ELLIPSE) ----------
(defun sk:convcurve (en strokes / obj z props)
  (setq obj   (vlax-ename->vla-object en)
        z     (caddr (vlax-curve-getStartPoint obj))
        props (sk:props (entget en) '(410 8 6 62 420 370 48)))
  (repeat strokes
    (sk:make (sk:cstroke obj) z props)
  )
)

;;; ---------- convert one HATCH: explode a copy, sketch its lines -----------
(defun sk:hatch (en / ed mark cpy e ed2 lst cnt)
  (setq ed (entget en))
  (if (or (= (strcase (cdr (assoc 2 ed))) "SOLID")
          (= 1 (cdr (assoc 450 ed))))
    nil
    (progn
      (setq mark (entlast)
            cpy  (vla-copy (vlax-ename->vla-object en)))
      (command "_.EXPLODE" (vlax-vla-object->ename cpy))
      (setq e mark)
      (while (setq e (entnext e))
        (if (entget e) (setq lst (cons e lst)))
      )
      (setq cnt 0)
      (foreach x lst
        (setq ed2 (entget x))
        (if (member (cdr (assoc 0 ed2)) '("LINE" "LWPOLYLINE"))
          (progn
            (sk:convert ed2 T 1)
            (setq cnt (1+ cnt))
          )
        )
        (entdel x)
      )
      cnt
    )
  )
)

;;; ---------- main command --------------------------------------------------
(defun c:SKETCHLINE (/ *error* doc ss i lst typ oldecho nObj nHl nSkip r)
  (setq doc     (vla-get-ActiveDocument (vlax-get-acad-object))
        oldecho (getvar "CMDECHO"))
  (defun *error* (msg)
    (setvar "CMDECHO" oldecho)
    (vla-EndUndoMark doc)
    (if (not (wcmatch (strcase msg) "*CANCEL*,*QUIT*,*EXIT*"))
      (princ (strcat "\nError: " msg))
    )
    (princ)
  )
  (sk:init)
  (princ (strcat "\nSketch style: " *sk:style*
                 "  (drift " (rtos *sk:rough* 2 2)
                 "%, tremor " (rtos *sk:trem* 2 2)
                 "%, jitter " (rtos *sk:jit* 2 2)
                 "%, end freedom " (rtos *sk:endf* 2 2)
                 "%, overshoot " (rtos *sk:ovr* 2 2)
                 "%, variability " (rtos *sk:var* 2 2)
                 ", strokes " (itoa *sk:str*) ")  - change with SKETCHSET"))
  (if (setq ss (ssget "_:L" '((0 . "LINE,LWPOLYLINE,SPLINE,ARC,CIRCLE,ELLIPSE,HATCH"))))
    (progn
      (vla-StartUndoMark doc)
      (setvar "CMDECHO" 0)
      (setq i 0 nObj 0 nHl 0 nSkip 0)
      (repeat (sslength ss)
        (setq lst (cons (ssname ss i) lst) i (1+ i))
      )
      (foreach x (reverse lst)
        (setq typ (cdr (assoc 0 (entget x))))
        (cond
          ((= typ "HATCH")
           (if (setq r (sk:hatch x))
             (progn
               (setq nHl (+ nHl r) nObj (1+ nObj))
               (if (= *sk:del* "Yes") (entdel x))
             )
             (setq nSkip (1+ nSkip))
           )
          )
          ((member typ '("SPLINE" "ARC" "CIRCLE" "ELLIPSE"))
           (sk:convcurve x *sk:str*)
           (setq nObj (1+ nObj))
           (if (= *sk:del* "Yes") (entdel x))
          )
          (T
           (sk:convert (entget x) nil *sk:str*)
           (setq nObj (1+ nObj))
           (if (= *sk:del* "Yes") (entdel x))
          )
        )
      )
      (setvar "CMDECHO" oldecho)
      (vla-EndUndoMark doc)
      (princ (strcat "\n" (itoa nObj) " object(s) converted"
                     (if (> nHl 0) (strcat ", " (itoa nHl) " hatch line(s)") "")
                     (if (> nSkip 0) (strcat ", " (itoa nSkip) " solid/gradient hatch(es) skipped") "")
                     "."))
    )
  )
  (princ)
)

;;; ==========================================================================
;;;  SKETCHTEXT
;;; ==========================================================================

;;; ---------- split a TEXT string into printable characters ----------------
;;;  keeps %%d %%c %%p %%% %%nnn and \U+xxxx as single characters,
;;;  drops the %%u / %%o underline and overline toggles
(defun sk:tokens (s / i n c nx lst)
  (setq i 1 n (strlen s))
  (while (<= i n)
    (setq c (substr s i 1))
    (cond
      ((and (= (substr s i 2) "%%") (<= (+ i 2) n))
       (setq nx (strcase (substr s (+ i 2) 1)))
       (cond
         ((member nx '("D" "C" "P" "%"))
          (setq lst (cons (substr s i 3) lst) i (+ i 3)))
         ((member nx '("U" "O"))
          (setq i (+ i 3)))
         ((wcmatch (substr s (+ i 2) 3) "###")
          (setq lst (cons (substr s i 5) lst) i (+ i 5)))
         (T (setq lst (cons c lst) i (1+ i)))
       )
      )
      ((and (= c "\\") (= (strcase (substr s (1+ i) 2)) "U+"))
       (setq lst (cons (substr s i 7) lst) i (+ i 7)))
      (T (setq lst (cons c lst) i (1+ i)))
    )
  )
  (reverse lst)
)

;;; ---------- advance width of a string (upper-right X of its textbox) -----
(defun sk:tw (tb s)
  (if (= s "")
    0.0
    (car (cadr (textbox (cons (cons 1 s) tb))))
  )
)

;;; ---------- one TEXT entity -> one TEXT per character --------------------
;;;  returns number of characters created
(defun sk:text1 (ed / s h ang p0 wf obl sty gen props toks tb wM total wl kn
                      prefix x dx dy hs dr cs sn pt cnt)
  (setq s     (cdr (assoc 1 ed))
        h     (cdr (assoc 40 ed))
        ang   (cond ((cdr (assoc 50 ed))) (0.0))
        p0    (cdr (assoc 10 ed))            ; left end of the baseline
        wf    (cond ((cdr (assoc 41 ed))) (1.0))
        obl   (cond ((cdr (assoc 51 ed))) (0.0))
        sty   (cdr (assoc 7 ed))
        gen   (cond ((cdr (assoc 71 ed))) (0))
        props (sk:props ed '(410 8 6 62 420 370 48 210))
        toks  (sk:tokens s)
        tb    (list (cons 40 h) (cons 41 wf) (cons 51 obl) (cons 7 sty)
                    (cons 71 gen) '(50 . 0.0))
        wM    (sk:tw tb "M")
        total (max h (- (sk:tw tb (strcat (apply 'strcat toks) "M")) wM))
        wl    (* h (sk:rnd 5.0 10.0))
        kn    (sk:noise-make (+ total h) wl)
        cs    (cos ang)
        sn    (sin ang)
        prefix ""
        cnt   0
  )
  (foreach tok toks
    (setq x (if (= prefix "") 0.0 (- (sk:tw tb (strcat prefix "M")) wM)))
    (if (/= tok " ")
      (progn
        (setq dx (* h (/ *sk:tsp* 100.0) (sk:rnd -1.0 1.0))
              dy (+ (* h (/ *sk:tbl* 100.0) (sk:rnd -1.0 1.0))
                    (* h (/ *sk:tdr* 100.0) (sk:noise kn (max 0.0 x) wl)))
              hs (* h (+ 1.0 (* (/ *sk:ths* 100.0) (sk:rnd -1.0 1.0))))
              dr (* (/ pi 180.0) *sk:trot* (sk:rnd -1.0 1.0))
              x  (+ x dx)
              pt (list (+ (car p0) (- (* x cs) (* dy sn)))
                       (+ (cadr p0) (+ (* x sn) (* dy cs)))
                       (cond ((caddr p0)) (0.0)))
        )
        (if (entmakex
              (append
                (list '(0 . "TEXT"))
                props
                (list (cons 10 pt)
                      (cons 40 hs)
                      (cons 1 tok)
                      (cons 50 (+ ang dr))
                      (cons 41 wf)
                      (cons 51 obl)
                      (cons 7 sty)
                      (cons 71 gen)
                      '(72 . 0)
                      '(73 . 0))))
          (setq cnt (1+ cnt))
        )
      )
    )
    (setq prefix (strcat prefix tok))
  )
  cnt
)

;;; ---------- MTEXT: explode a copy to TEXT, process, remove pieces --------
(defun sk:mtext (en / mark cpy e lst cnt ed)
  (setq mark (entlast)
        cpy  (vla-copy (vlax-ename->vla-object en))
        cnt  0)
  (command "_.EXPLODE" (vlax-vla-object->ename cpy))
  (setq e mark)
  (while (setq e (entnext e))
    (if (entget e) (setq lst (cons e lst)))
  )
  (foreach x lst
    (setq ed (entget x))
    (if (= (cdr (assoc 0 ed)) "TEXT")
      (setq cnt (+ cnt (sk:text1 ed)))
    )
    (entdel x)
  )
  cnt
)

;;; ---------- SKETCHTEXT command --------------------------------------------
(defun c:SKETCHTEXT (/ *error* doc ss i lst ed oldecho nObj nCh)
  (setq doc     (vla-get-ActiveDocument (vlax-get-acad-object))
        oldecho (getvar "CMDECHO"))
  (defun *error* (msg)
    (setvar "CMDECHO" oldecho)
    (vla-EndUndoMark doc)
    (if (not (wcmatch (strcase msg) "*CANCEL*,*QUIT*,*EXIT*"))
      (princ (strcat "\nError: " msg))
    )
    (princ)
  )
  (sk:init)
  (princ (strcat "\nText style: " *sk:style*
                 "  (baseline " (rtos *sk:tbl* 2 1)
                 "%, rotation " (rtos *sk:trot* 2 1)
                 " deg, height " (rtos *sk:ths* 2 1)
                 "%, spacing " (rtos *sk:tsp* 2 1)
                 "%, wave " (rtos *sk:tdr* 2 1)
                 "% of text height)  - change with SKETCHSET"))
  (if (setq ss (ssget "_:L" '((0 . "TEXT,MTEXT"))))
    (progn
      (vla-StartUndoMark doc)
      (setvar "CMDECHO" 0)
      (setq i 0 nObj 0 nCh 0)
      (repeat (sslength ss)
        (setq lst (cons (ssname ss i) lst) i (1+ i))
      )
      (foreach x (reverse lst)
        (setq ed (entget x))
        (setq nCh (+ nCh
                     (if (= (cdr (assoc 0 ed)) "MTEXT")
                       (sk:mtext x)
                       (sk:text1 ed)))
              nObj (1+ nObj))
        (if (= *sk:del* "Yes") (entdel x))
      )
      (setvar "CMDECHO" oldecho)
      (vla-EndUndoMark doc)
      (princ (strcat "\n" (itoa nObj) " text object(s) converted into "
                     (itoa nCh) " character(s)."))
    )
  )
  (princ)
)

;;; ---------- settings command ----------------------------------------------
(defun sk:askreal (msg cur / v)
  (initget 4)
  (if (setq v (getreal (strcat msg " <" (rtos cur 2 2) ">: "))) v cur)
)

(defun c:SKETCHSET (/ v)
  (sk:init)
  (initget "Fine Medium Rough Loose Custom")
  (setq v (getkword (strcat "\nStyle [Fine/Medium/Rough/Loose/Custom] <" *sk:style* ">: ")))
  (if v
    (if (= v "Custom")
      (progn
        (setq *sk:style* "Custom"
              *sk:rough* (sk:askreal "\nSlow drift, % of length" *sk:rough*)
              *sk:trem*  (sk:askreal "\nTremor, % of length" *sk:trem*)
              *sk:jit*   (sk:askreal "\nMicro jitter, % of length" *sk:jit*)
              *sk:endf*  (sk:askreal "\nEnd freedom (sideways), % of length" *sk:endf*)
              *sk:ovr*   (sk:askreal "\nEnd overshoot, % of length" *sk:ovr*)
              *sk:var*   (min 1.0 (sk:askreal "\nVariability between lines, 0-1" *sk:var*))
              *sk:tbl*   (sk:askreal "\nText: baseline shift, % of text height" *sk:tbl*)
              *sk:trot*  (sk:askreal "\nText: letter rotation, degrees" *sk:trot*)
              *sk:ths*   (sk:askreal "\nText: letter height variation, %" *sk:ths*)
              *sk:tsp*   (sk:askreal "\nText: spacing variation, % of text height" *sk:tsp*)
              *sk:tdr*   (sk:askreal "\nText: baseline wave, % of text height" *sk:tdr*)
        )
        (initget 4)
        (if (setq v (getdist (strcat "\nAbsolute max wobble, 0 = no limit <" (rtos *sk:cap* 2 3) ">: ")))
          (setq *sk:cap* v))
      )
      (sk:preset v)
    )
  )
  (initget 6)
  (if (setq v (getint (strcat "\nStrokes per segment (not hatches) <" (itoa *sk:str*) ">: ")))
    (setq *sk:str* v))
  (initget "Yes No")
  (if (setq v (getkword (strcat "\nDelete original objects? [Yes/No] <" *sk:del* ">: ")))
    (setq *sk:del* v))
  (princ)
)

(princ "\nSketchLine v6 loaded. Commands: SKETCHLINE, SKETCHTEXT, SKETCHSET")
(princ)
