"""Shared JUnit XML parsing for the value benchmark.

Standard library only. Load this file with importlib (spec_from_file_location);
do not add the corpus directory to sys.path, because select.py lives there and
would shadow the standard library module of the same name.

Test identifier format: "<classname>::<name>". Classification uses these
outcomes: "pass", "fail", "skip". A duplicated id collapses to its worst
outcome (fail > skip > pass).
"""

import xml.etree.ElementTree as ET

_RANK = {"pass": 0, "skip": 1, "fail": 2}


def _outcome_of(case):
    outcome = "pass"
    for child in case:
        tag = child.tag.rsplit("}", 1)[-1].lower()
        if tag in ("failure", "error"):
            return "fail"
        if tag == "skipped":
            outcome = "skip"
    return outcome


def parse_junit(path):
    """Return {test_id: outcome} for a JUnit XML file."""
    results = {}
    root = ET.parse(path).getroot()
    for case in root.iter():
        if case.tag.rsplit("}", 1)[-1] != "testcase":
            continue
        classname = case.attrib.get("classname", "")
        name = case.attrib.get("name", "")
        test_id = "%s::%s" % (classname, name)
        outcome = _outcome_of(case)
        previous = results.get(test_id)
        if previous is None or _RANK[outcome] > _RANK[previous]:
            results[test_id] = outcome
    return results
