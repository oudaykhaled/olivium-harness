import asyncio
import json
import struct

import pytest

from fixtures.helpers import job
from protocol import BoundaryError, decode, encode, read_frame


def frame():
    return dict(v=1, kind="job", session_id="session:synthetic", seq=1,
                request_id="request:synthetic", payload=job().model_dump())


def test_packet_round_trip_and_byte_length_with_unicode():
    value = frame()
    value["payload"]["args"]["query"] = "Café review"
    packet = encode(value)
    length = struct.unpack(">I", packet[:4])[0]
    assert length == len(packet[4:])
    assert decode(packet[4:]).payload["args"]["query"] == "Café review"


@pytest.mark.parametrize("mutate", [
    lambda f: f.update(permission="allow"),
    lambda f: f.update(seq=True),
    lambda f: f["payload"].update(scope_ref=""),
    lambda f: f["payload"].update(semantic_generation=True),
    lambda f: f["payload"]["args"].update(group_ids=["foreign"]),
    lambda f: f["payload"]["args"].update(limit=101),
    lambda f: f["payload"]["args"].update(query="é" * 4097),
])
def test_forged_authority_unknown_fields_and_wrong_types_fail(mutate):
    value = frame()
    mutate(value)
    with pytest.raises(BoundaryError):
        decode(json.dumps(value).encode())


@pytest.mark.parametrize("raw", [b'{"v":1,"v":1}', b'{"v":NaN}', b'\xff', b'{}', b'x' * 131073])
def test_invalid_frames_are_safe_errors(raw):
    with pytest.raises(BoundaryError, match="invalid_frame"):
        decode(raw)


async def test_oversized_prefix_rejected_without_waiting_for_body():
    reader = asyncio.StreamReader()
    reader.feed_data(struct.pack(">I", 131073))
    with pytest.raises(BoundaryError, match="invalid_frame"):
        await read_frame(reader, timeout=0.01)


async def test_partial_frame_and_closed_peer_are_not_complete_messages():
    reader = asyncio.StreamReader()
    reader.feed_data(struct.pack(">I", 20) + b'{}')
    reader.feed_eof()
    with pytest.raises(asyncio.IncompleteReadError):
        await read_frame(reader)


def test_depth_and_array_caps_apply_before_payload_admission():
    value = frame()
    value["payload"]["args"]["extra"] = [0] * 101
    with pytest.raises(BoundaryError):
        decode(json.dumps(value).encode())
