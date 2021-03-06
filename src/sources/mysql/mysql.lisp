;;;
;;; Tools to handle MySQL data fetching
;;;

(in-package :pgloader.mysql)

(defclass copy-mysql (db-copy)
  ((encoding :accessor encoding         ; allows forcing encoding
             :initarg :encoding
             :initform nil)
   (range-list :accessor range-list
               :initarg :range-list
               :initform nil))
  (:documentation "pgloader MySQL Data Source"))

(defmethod initialize-instance :after ((source copy-mysql) &key)
  "Add a default value for transforms in case it's not been provided."
  (let ((transforms (and (slot-boundp source 'transforms)
                         (slot-value  source 'transforms))))
    (when (and (slot-boundp source 'fields) (slot-value source 'fields))
      ;; cast typically happens in copy-database in the schema structure,
      ;; and the result is then copied into the copy-mysql instance.
      (unless (and (slot-boundp source 'columns) (slot-value source 'columns))
        (setf (slot-value source 'columns)
              (mapcar #'cast (slot-value source 'fields))))

      (unless transforms
        (setf (slot-value source 'transforms)
              (mapcar #'column-transform (slot-value source 'columns)))))))


;;;
;;; Implement the specific methods
;;;
(defmethod concurrency-support ((mysql copy-mysql) concurrency)
  "Splits the read work thanks WHERE clauses when possible and relevant,
   return nil if we decide to read all in a single thread, and a list of as
   many copy-mysql instances as CONCURRENCY otherwise. Each copy-mysql
   instance in the returned list embeds specifications about how to read
   only its partition of the source data."
  (unless (= 1 concurrency)
    (let* ((indexes (table-index-list (target mysql)))
           (pkey    (first (remove-if-not #'index-primary indexes)))
           (pcol    (when pkey (first (index-columns pkey))))
           (coldef  (when pcol
                      (find pcol
                            (table-column-list (target mysql))
                            :key #'column-name
                            :test #'string=)))
           (ptype   (when (and coldef (stringp (column-type-name coldef)))
                      (column-type-name coldef))))
      (when (member ptype (list "integer" "bigint" "serial" "bigserial")
                    :test #'string=)
        ;; the table has a primary key over a integer data type we are able
        ;; to generate WHERE clause and range index scans.
        (with-connection (*connection* (source-db mysql))
          (let* ((col pcol)
                 (sql (format nil "select min(`~a`), max(`~a`) from `~a`"
                              col col (table-source-name (source mysql)))))
            (destructuring-bind (min max)
                (let ((result (first (mysql-query sql))))
                  ;; result is (min max), or (nil nil) if table is empty
                  (if (or (null (first result))
                          (null (second result)))
                      result
                      (mapcar #'parse-integer result)))
              ;; generate a list of ranges from min to max
              (when (and min max)
                (let ((range-list (split-range min max *rows-per-range*)))
                  (unless (< (length range-list) concurrency)
                    ;; affect those ranges to each reader, we have CONCURRENCY
                    ;; of them
                    (let ((partitions (distribute range-list concurrency)))
                      (loop :for part :in partitions :collect
                         (make-instance 'copy-mysql
                                        :source-db  (clone-connection
                                                     (source-db mysql))
                                        :target-db  (target-db mysql)
                                        :source     (source mysql)
                                        :target     (target mysql)
                                        :fields     (fields mysql)
                                        :columns    (columns mysql)
                                        :transforms (transforms mysql)
                                        :encoding   (encoding mysql)
                                        :range-list (cons col part))))))))))))))

(defmacro with-encoding-handler (&body forms)
  `(handler-bind
       ;; avoid trying to fetch the character at end-of-input position...
       ((babel-encodings:end-of-input-in-character
         #'(lambda (c)
             (update-stats :data (target mysql) :errs 1)
             (log-message :error "~a" c)
             (invoke-restart 'qmynd-impl::use-nil)))
        (babel-encodings:character-decoding-error
         #'(lambda (c)
             (update-stats :data (target mysql) :errs 1)
             (let ((encoding (babel-encodings:character-coding-error-encoding c))
                   (position (babel-encodings:character-coding-error-position c))
                   (character
                    (aref (babel-encodings:character-coding-error-buffer c)
                          (babel-encodings:character-coding-error-position c))))
               (log-message :error
                            "~a: Illegal ~a character starting at position ~a: ~a."
                            table-name encoding position character))
             (invoke-restart 'qmynd-impl::use-nil))))
     (progn ,@forms)))

(defmethod map-rows ((mysql copy-mysql) &key process-row-fn)
  "Extract MySQL data and call PROCESS-ROW-FN function with a single
   argument (a list of column values) for each row."
  (let ((table-name (table-source-name (source mysql)))
        (qmynd:*mysql-encoding*
         (when (encoding mysql)
           #+sbcl (encoding mysql)
           #+ccl  (ccl:external-format-character-encoding (encoding mysql)))))

    (with-connection (*connection* (source-db mysql))
      (when qmynd:*mysql-encoding*
        (log-message :notice "Force encoding to ~a for ~a"
                     qmynd:*mysql-encoding* table-name))
      (let* ((cols (get-column-list (db-name (source-db mysql)) table-name))
             (sql  (format nil "SELECT ~{~a~^, ~} FROM `~a`" cols table-name)))

        (if (range-list mysql)
            ;; read a range at a time, in a loop
            (destructuring-bind (colname . ranges) (range-list mysql)
              (loop :for (min max) :in ranges :do
                 (let ((sql (format nil "~a WHERE `~a` >= ~a AND `~a` < ~a"
                                    sql colname min colname max)))
                   (with-encoding-handler
                     (mysql-query sql
                                  :row-fn process-row-fn
                                  :result-type 'vector)))))

            ;; read it all, no WHERE clause
            (with-encoding-handler
              (mysql-query sql
                           :row-fn process-row-fn
                           :result-type 'vector)))))))



(defmethod copy-column-list ((mysql copy-mysql))
  "We are sending the data in the MySQL columns ordering here."
  (mapcar #'apply-identifier-case (mapcar #'mysql-column-name (fields mysql))))


(defmethod fetch-metadata ((mysql copy-mysql)
                           (catalog catalog)
                           &key
                             materialize-views
                             only-tables
                             (create-indexes   t)
                             (foreign-keys     t)
                             including
                             excluding)
  "MySQL introspection to prepare the migration."
  (let ((schema        (add-schema catalog (catalog-name catalog)))
        (view-names    (unless (eq :all materialize-views)
                         (mapcar #'car materialize-views))))
    (with-stats-collection ("fetch meta data"
                            :use-result-as-rows t
                            :use-result-as-read t
                            :section :pre)
        (with-connection (*connection* (source-db mysql))
          ;; If asked to MATERIALIZE VIEWS, now is the time to create them in
          ;; MySQL, when given definitions rather than existing view names.
          (when (and materialize-views (not (eq :all materialize-views)))
            (create-my-views materialize-views))

          ;; fetch table and columns metadata, covering table and column comments
          (list-all-columns schema
                            :only-tables only-tables
                            :including including
                            :excluding excluding)

          ;; fetch view (and their columns) metadata, covering comments too
          (cond (view-names (list-all-columns schema
                                              :only-tables view-names
                                              :table-type :view))

                ((eq :all materialize-views)
                 (list-all-columns schema :table-type :view)))

          (when foreign-keys
            (list-all-fkeys schema
                            :only-tables only-tables
                            :including including
                            :excluding excluding))

          (when create-indexes
            (list-all-indexes schema
                              :only-tables only-tables
                              :including including
                              :excluding excluding))

          ;; return how many objects we're going to deal with in total
          ;; for stats collection
          (+ (count-tables catalog)
             (count-views catalog)
             (count-indexes catalog)
             (count-fkeys catalog))))

    catalog))

(defmethod cleanup ((mysql copy-mysql) (catalog catalog) &key materialize-views)
  "When there is a PostgreSQL error at prepare-pgsql-database step, we might
   need to clean-up any view created in the MySQL connection for the
   migration purpose."
  (when materialize-views
    (with-connection (*connection* (source-db mysql))
      (drop-my-views materialize-views))))

(defvar *decoding-as* nil
  "Special per-table encoding/decoding overloading rules for MySQL.")

(defun apply-decoding-as-filters (table-name filters)
  "Return a generialized boolean which is non-nil only if TABLE-NAME matches
   one of the FILTERS."
  (flet ((apply-filter (filter)
           ;; we close over table-name here.
           (typecase filter
             (string (string-equal filter table-name))
             (list   (destructuring-bind (type val) filter
                       (ecase type
                         (:regex (cl-ppcre:scan val table-name))))))))
    (some #'apply-filter filters)))

(defmethod instanciate-table-copy-object ((copy copy-mysql) (table table))
  "Create an new instance for copying TABLE data."
  (let ((new-instance (change-class (call-next-method copy table) 'copy-mysql)))
    (setf (encoding new-instance)
          ;; force the data encoding when asked to
          (when *decoding-as*
            (loop :for (encoding . filters) :in *decoding-as*
               :when (apply-decoding-as-filters (table-name table) filters)
               :return encoding)))
    new-instance))

