This script uses the Canvas API to grab each student's section number and then
write the section number directly to the Webwork database.

LTI class sync does not include section numbers, so students in Webwork don't
have section numbers. Hence using the Canvas API to retrieve section numbers.
And since Webwork doesn't have an API, getting the section number into Webwork
requires connecting directly to the Webwork database.

Note that this script may get the wrong section if the course has multiple
section types, e.g.: if there are Lectures and Labs, then students might end up
with the Lab section. APSC 279 only has lectures, so it hasn't been an issue so
far.

## Required Variables

* CANVAS_KEY - Your Canvas API key
* CANVAS_COURSE_ID - The numbers at the end of a Canvas course URL, e.g.:
  123456 in https://canvas.ubc.ca/courses/123456
* WEBWORK_COURSE_NAME - The section after /webwork2/ in a Webwork course URL,
  e.g.: 2023W1_APSC_279_1xx_2023W1 in
  https://webwork.elearning.ubc.ca/webwork2/2023W1_APSC_279_1xx_2023W1/

Database configuration should be read from env vars, so you don't have to
explicitly configure them.

## To run

Working directory `ubcscripts/add_course_section_to_students_in_webwork/`

1. Edit `run.py` and update all the required variables
2. Install dependencies `uv sync`
4. Run script `uv run run.py`

## Misc

Confluence doc: https://confluence.it.ubc.ca/display/LTHub/How+to+add+course+section+number+to+students+in+Webwork

Relevant tickets:
* INC2651704
* INC2975341
* INC3208647
* INC3551783
* INC3741520
* INC4139276
* INC4821041
* INC4984400
* INC5268470
