import pytest

from fixtures.helpers import job
from lineage import CURRENT_CALL, CURRENT_LINEAGE, call, operation
from protocol import BoundaryError


def test_prompt_and_transitive_values_are_observed_without_manufacturing_authority():
    selected = job()
    with operation(selected) as lineage:
        summary = lineage.observe("summary", "entity:synthetic", "Prior summary")
        attribute = lineage.observe("attribute", "entity:synthetic", {"owner": "Synthetic owner"})
        prompt = lineage.observe("prompt", "extract_nodes.extract_text", {"summary": "Prior summary"})
        assert len({summary, attribute, prompt}) == 3
        assert lineage.manifest() == (selected.closure_ref, selected.closure_digest)
        assert lineage.manifest()[1] not in {summary, attribute, prompt}
    with pytest.raises(LookupError):
        CURRENT_LINEAGE.get()


def test_logical_call_context_is_restored_and_receipts_cannot_double_settle():
    with operation(job()) as lineage:
        with call("stage:synthetic", "extract_nodes.extract_text") as parent:
            with call("stage:synthetic", "embedder.create") as child:
                assert parent.logical_call_id != child.logical_call_id
            assert CURRENT_CALL.get() is parent
        lineage.receipt("receipt:once")
        with pytest.raises(BoundaryError, match="reconcile_required"):
            lineage.receipt("receipt:once")


def test_missing_manifest_or_outside_operation_denies_call():
    with pytest.raises(BoundaryError, match="closure_incomplete"):
        with call("stage:synthetic", "prompt"):
            pass
    invalid = job().model_copy(update={"closure_ref": ""})
    with operation(invalid), pytest.raises(BoundaryError, match="closure_incomplete"):
        with call("stage:synthetic", "prompt"):
            pass
