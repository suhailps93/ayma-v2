"""Media-carrying tool results.

The chat tool loops hand a tool's return value back to the model as text —
the one shape every registered skill returns (``skills/_base.py``). A tool
whose whole point is to show the model an image (``open_replied_photo`` —
the photo the user replied to, pulled by reference) cannot do that with a
string, so it returns this marker instead: ``text`` is the ordinary string
result (what the tool reports, and what any loop that does not know the
marker will hand the model via ``str()``), and ``image`` is the
``(bytes, mime)`` the knowing loops (``gemini.py``'s inference loop, the
LiveKit brains in ``llm_provider.py``) attach to the follow-up call as a
real image part, exactly like a photo the user attached to their message.

Kept dependency-free so skills and both model loops can import it without
cycles.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ImageToolResult:
    """A tool result that also hands the model one image.

    ``text`` — the string the model reads as the tool's result.
    ``image`` — ``(bytes, mime_type)`` of the image the tool opened.
    ``note`` — the caption line attached alongside the image part when the
    loop presents it, so the model knows which photo it is looking at.
    """

    text: str
    image: tuple[bytes, str]
    note: str = ""

    def __str__(self) -> str:
        # Loops that do not know the marker stringify the result — they
        # must get the text, never a repr (which would embed the bytes).
        return self.text
