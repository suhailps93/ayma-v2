Look at this image and answer only one question: does it contain at least one
real, photographed human face?

Answer true only for an actual photograph of a real person's face — any angle,
any number of people, any image quality, as long as at least one real face is
visible.

Answer false for anything that is not a photographed human face, including:
- a solid color, gradient, or geometric/abstract pattern (e.g. a default
  profile-picture placeholder or "identicon" with no person in it)
- a cartoon, illustration, drawing, or CGI/AI-generated character
- a logo, icon, screenshot of text, or graphic design
- an object, animal, or scenery with no person in it
- a photo where a face is fully obscured, blank, or not actually present

Return JSON matching the schema exactly:
- has_face: true only if a real, photographed human face is clearly visible
  somewhere in the image; false otherwise.
