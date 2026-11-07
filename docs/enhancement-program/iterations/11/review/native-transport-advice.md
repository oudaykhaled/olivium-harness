# Native button transport correction — bounded source advice

No critical unresolved finding in the reviewed correction. Current three files match their retained after copies. This is source review; root reports red reproduction and12 focused passes, which were not executed or independently verified here. Canonical02 status is not assessed.

`CompanyAssessmentState.envelope/3:104–143` validates current generation, target, JSON and total size before removing only empty outer value on the exact known button event/action/stage allowlist. Nonempty/null/number/list/map values survive to strict shapes; arbitrary extra fields are not dropped. Ordinary goal/rubric/results forms are not allowlisted. A mixed rubric+action payload can match button normalization, but retains action and fails capture_rubric's exact outer [rubric] shape; normalization therefore creates no mixed-form acceptance bypass.

`PortalLive:69–73` supplies the event at ingress, before the direct departure handler and dirty replacement capture. Consequently departure_resolve reaches its exactly-one-action handler, and pending replacement destinations retain normalized attrs instead of later failing on browser value. Generation/auth checks remain upstream; no session/token authority is taken from value. Existing state/domain validation still governs actions and persistence.

The Flow test change explicitly carries native empty value on29 existing clicks. The added test exercises nonempty/null/number/list/map refusal, empty value plus an extra field, a valid empty-value continuation and refusal of empty outer value on the scope form, with no rubric/assessment insertion. Existing dirty keep/discard/save and successor/history/attempt paths now use native-shaped clicks. This does not claim exhaustive action/mixed-form or native browser coverage; no additional correction is indicated by the inspected source.

Only this report and its compact JSON audit were written. Earlier advice, retained failures/copies and product sources remain untouched.
