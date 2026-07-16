(in-package #:self-improving-agent-harness)

(defvar *experiment-registry* (make-hash-table :test #'equal)
  "Registry of validated experiment specifications keyed by stable experiment ID.")

(defstruct (experiment
            (:constructor make-experiment
                (&key id task-fixture acceptance-criteria agent-configuration evaluator budget)))
  "A declarative, provider-independent experiment specification."
  id
  task-fixture
  acceptance-criteria
  agent-configuration
  evaluator
  budget)

(defun experiment-complete-p (experiment)
  (and (stringp (experiment-id experiment))
       (plusp (length (experiment-id experiment)))
       (experiment-task-fixture experiment)
       (experiment-acceptance-criteria experiment)
       (experiment-agent-configuration experiment)
       (experiment-evaluator experiment)
       (experiment-budget experiment)))

(defun validate-experiment (experiment)
  "Signal an error unless EXPERIMENT has every required declarative field."
  (unless (experiment-complete-p experiment)
    (error "Experiment specifications require id, task fixture, acceptance criteria, agent configuration, evaluator, and budget."))
  experiment)

(defun register-experiment (experiment)
  "Validate and register EXPERIMENT without executing an agent or provider."
  (validate-experiment experiment)
  (setf (gethash (experiment-id experiment) *experiment-registry*) experiment))

(defun find-experiment (id)
  "Return the registered experiment with stable ID, or NIL."
  (gethash id *experiment-registry*))

(defmacro defexperiment (name &rest initargs)
  "Declare, validate, and register an experiment without invoking a provider.

NAME is bound to the registered EXPERIMENT object.  INITARGS are the keyword
arguments accepted by MAKE-EXPERIMENT."
  `(defparameter ,name
     (register-experiment (make-experiment ,@initargs))))

(defparameter +experiment-schema-version+ "1"
  "Version of the stable plist serialization boundary for experiment data.")

(defstruct (candidate
            (:constructor make-candidate
                (&key id experiment-id parent-id configuration configuration-hash)))
  "A named change/configuration considered by an EXPERIMENT.

IDs are caller-supplied stable identifiers.  PARENT-ID records lineage without
coupling candidate creation to evaluation or promotion policy."
  id
  experiment-id
  parent-id
  configuration
  configuration-hash)

(defstruct (run-record
            (:constructor make-run-record
                (&key id experiment-id candidate-id started-at finished-at outcome
                      trace-reference usage cost)))
  "Execution facts for a candidate; evaluator conclusions belong in EVALUATION."
  id experiment-id candidate-id started-at finished-at outcome trace-reference usage cost)

(defstruct (evaluation
            (:constructor make-evaluation
                (&key candidate-id evaluator-id verdict evidence outcome accounting)))
  "Evaluator-owned conclusion and evidence for a candidate."
  candidate-id evaluator-id verdict evidence outcome accounting)

(defstruct (decision
            (:constructor make-decision
                (&key candidate-id action rationale evaluation-reference)))
  "Retention or queueing decision kept independent from evaluator implementation."
  candidate-id action rationale evaluation-reference)

(defun materialize-candidate (experiment &key id parent-candidate configuration)
  "Create a candidate with explicit stable ID and optional parent lineage."
  (validate-experiment experiment)
  (unless (and (stringp id) (plusp (length id)))
    (error "Candidate materialization requires a non-empty stable id."))
  (when (and parent-candidate
             (not (string= (candidate-experiment-id parent-candidate)
                            (experiment-id experiment))))
    (error "Candidate parent must belong to the same experiment."))
  (make-candidate :id id
                  :experiment-id (experiment-id experiment)
                  :parent-id (and parent-candidate (candidate-id parent-candidate))
                  :configuration configuration
                  :configuration-hash (stable-configuration-hash configuration)))

(defun serialize-domain-object (object)
  "Serialize a domain object to a versioned, provider-neutral plist.

This is the stable boundary for future trace/report encoders.  Values supplied
inside fixtures, configurations, and evidence remain application-owned data."
  (let ((header (list :schema-version +experiment-schema-version+)))
    (append header
            (typecase object
              (experiment
               (list :type "experiment" :id (experiment-id object)
                     :task-fixture (experiment-task-fixture object)
                     :acceptance-criteria (experiment-acceptance-criteria object)
                     :agent-configuration (experiment-agent-configuration object)
                     :evaluator (experiment-evaluator object) :budget (experiment-budget object)))
              (candidate
               (list :type "candidate" :id (candidate-id object)
                     :experiment-id (candidate-experiment-id object)
                     :parent-id (candidate-parent-id object)
                     :configuration (candidate-configuration object)
                     :configuration-hash (candidate-configuration-hash object)))
              (run-record
               (list :type "run-record" :id (run-record-id object)
                     :experiment-id (run-record-experiment-id object)
                     :candidate-id (run-record-candidate-id object)
                     :started-at (run-record-started-at object) :finished-at (run-record-finished-at object)
                     :outcome (run-record-outcome object) :trace-reference (run-record-trace-reference object)
                     :usage (run-record-usage object) :cost (run-record-cost object)))
              (evaluation
               (list :type "evaluation" :candidate-id (evaluation-candidate-id object)
                      :evaluator-id (evaluation-evaluator-id object) :verdict (evaluation-verdict object)
                      :evidence (evaluation-evidence object)
                      :outcome (evaluation-outcome object)
                      :accounting (evaluation-accounting object)))
              (decision
               (list :type "decision" :candidate-id (decision-candidate-id object)
                     :action (decision-action object) :rationale (decision-rationale object)
                     :evaluation-reference (decision-evaluation-reference object)))
              (t (error "Cannot serialize unknown experiment domain object ~S." object))))))
