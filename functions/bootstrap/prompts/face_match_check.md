Look at Image 1 (the reference photo of the user / account owner) and Image 2 (the candidate photo) and compare them.

Answer the following questions:
1. Is a real, photographed human face clearly visible in the candidate photo (Image 2)?
   - true: An actual photographed human face is visible in Image 2.
   - false: Image 2 contains no real human face (e.g. an object, animal, scenery, text screenshot, logo/graphic design, default avatar, illustration/cartoon/CGI, or a photo where the face is completely obscured/unrecognizable).

2. If a real human face is visible in Image 2, are the persons depicted in Image 1 and Image 2 the SAME INDIVIDUAL?
   - "self": High or medium certainty that Image 2 shows the exact same individual as Image 1.
   - "not_self": High or medium certainty that Image 2 shows a different person than Image 1, or Image 2 contains no real photographed human face (face_visible is false).
   - "unknown": Cannot reliably determine whether they are the same person (e.g. extreme angle, poor lighting/resolution, heavy blur, sunglasses/partial obstruction, or borderline ambiguity where neither same nor different can be asserted with confidence).

Return a valid JSON object matching the schema:
- verdict: "self" | "not_self" | "unknown"
- confidence: "high" | "medium" | "low"
- face_visible: boolean (true only if a real photographed human face is visible in Image 2)
- reason: brief 1-2 sentence explanation
