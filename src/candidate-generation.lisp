(in-package #:self-improving-agent-harness)

(defparameter +configuration-candidate-dimensions+
  '(:model-id :prompt-template-version :max-rounds :tool-workflow-strategy)
  "The initial explicit configuration dimensions that may be mutated offline.")

(defclass candidate-generator ()
  ()
  (:documentation "Protocol root for generators of explicit configuration candidates."))

(defgeneric generate-configuration-candidates (generator experiment parent-candidate mutation-space)
  (:documentation "Generate deterministic candidate configurations from MUTATION-SPACE."))

(defclass deterministic-configuration-generator (candidate-generator)
  ()
  (:documentation "A scripted generator for reproducible offline configuration comparisons."))

(defun configuration-key-name (key)
  (string-downcase (string key)))

(defun canonical-configuration (configuration)
  "Return a deterministic plist ordering for a flat explicit configuration."
  (unless (and (listp configuration) (evenp (length configuration)))
    (error "Configuration must be an even-length plist."))
  (loop for (key value) on configuration by #'cddr
        unless (keywordp key)
          do (error "Configuration key ~S must be a keyword." key))
  (loop for (key value) in
        (sort (loop for (key value) on configuration by #'cddr collect (list key value))
              #'string< :key (lambda (entry) (configuration-key-name (first entry))))
        append (list key value)))

(defun stable-configuration-hash (configuration)
  "Return a portable stable FNV-1a hash of canonical explicit configuration data."
  (let ((hash 14695981039346656037)
        (modulus 18446744073709551616))
    (with-standard-io-syntax
      (loop for character across (prin1-to-string (canonical-configuration configuration))
            do (setf hash (mod (* (logxor hash (char-code character)) 1099511628211)
                               modulus))))
    (format nil "~16,'0X" hash)))

(defun validate-mutation-space (mutation-space)
  (unless (and (listp mutation-space) (evenp (length mutation-space)))
    (error "Mutation space must be an even-length plist."))
  (loop for (dimension values) on mutation-space by #'cddr
        do (unless (member dimension +configuration-candidate-dimensions+)
             (error "Unsupported configuration mutation dimension ~S." dimension))
           (unless (and (listp values) values)
             (error "Mutation dimension ~S requires a non-empty explicit value list." dimension)))
  mutation-space)

(defun mutation-configurations (baseline-configuration mutation-space)
  "Enumerate the declared Cartesian mutation space in stable dimension/value order."
  (let ((dimensions
          (loop for dimension in +configuration-candidate-dimensions+
                for values = (getf mutation-space dimension)
                when values collect (list dimension values))))
    (labels ((extend (partial remaining)
               (if (null remaining)
                   (list partial)
                   (destructuring-bind (dimension values) (first remaining)
                     (loop for value in values append
                           (extend (append partial (list dimension value)) (rest remaining)))))))
      (mapcar (lambda (changes)
                (canonical-configuration
                 (loop for (key value) on baseline-configuration by #'cddr
                       append (list key (or (getf changes key) value)))) )
              (extend '() dimensions)))))

(defmethod generate-configuration-candidates ((generator deterministic-configuration-generator)
                                                experiment parent-candidate mutation-space)
  (declare (ignore generator))
  (validate-experiment experiment)
  (unless (and parent-candidate
               (string= (candidate-experiment-id parent-candidate) (experiment-id experiment)))
    (error "Configuration candidates require a parent candidate from the experiment."))
  (validate-mutation-space mutation-space)
  (let ((seen (make-hash-table :test #'equal)))
    (loop for configuration in
          (mutation-configurations (candidate-configuration parent-candidate) mutation-space)
          for hash = (stable-configuration-hash configuration)
          unless (gethash hash seen)
            do (setf (gethash hash seen) t)
            and collect (materialize-candidate
                         experiment
                         :id (format nil "~A/config-~A" (experiment-id experiment) hash)
                         :parent-candidate parent-candidate
                         :configuration configuration))))
