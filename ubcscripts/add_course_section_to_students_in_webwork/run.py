from canvasapi import Canvas
import json
import pprint
import time
import os
from sqlalchemy import create_engine, text

CANVAS_URL = "https://ubc.instructure.com"
CANVAS_KEY = "0000000~REPLACEME"
CANVAS_COURSE_ID = 122117
WEBWORK_COURSE_NAME = "2023W1_APSC_279_1xx_2023W1"
WEBWORK_DB_HOST = os.environ['WEBWORK_DB_HOST']
WEBWORK_DB_NAME = os.environ['WEBWORK_DB_NAME']
WEBWORK_DB_USER = os.environ['WEBWORK_DB_USER']
WEBWORK_DB_PASS = os.environ['WEBWORK_DB_PASSWORD']

canvas = Canvas(CANVAS_URL, CANVAS_KEY)
course = canvas.get_course(CANVAS_COURSE_ID)
print(f'Canvas Course Name: {course.name}')
print("Please cancel script if the course is wrong, sleeping 10 seconds")
time.sleep(10)
print("Continuing")

sections = course.get_sections()

sectionsBySectionId = dict()
for section in sections:
    sectionsBySectionId[section.id] = section.name

print('Number of sections: ' + str(len(sectionsBySectionId)))

students = course.get_enrollments()

sectionsByPuid = dict()
#i = 0
for student in students:
    #pprint.pprint(student)
    #exit(1)
    if student.enrollment_state != 'active':
        print('skipping inactive user: ' + student.user['name'])
        continue
    if student.type != 'StudentEnrollment':
        print('skipping non-student: ' + student.user['name'])
        continue

    userInfo = student.user
    sectionName = sectionsBySectionId[student.course_section_id]
    # sectionName looks like "APSC 279 106 2023W1", we only want the "106" part
    sectionNumber = sectionName[11:14]
    sectionsByPuid[userInfo['integration_id']] = sectionNumber
    #i += 1
    #if i == 10:
    #    break

#pprint.pp(sectionsByPuid)
print("Number of students: " + str(len(sectionsByPuid)))
print("Sleeping 10 seconds before actual webwork modification")
time.sleep(10)
print("Continuing")


dbStr = f"mysql+pymysql://{WEBWORK_DB_USER}:{WEBWORK_DB_PASS}@{WEBWORK_DB_HOST}/{WEBWORK_DB_NAME}"
engine = create_engine(dbStr, echo=True)
with engine.begin() as conn:
    usersTable = WEBWORK_COURSE_NAME + "_user"
    stmt = text(f"UPDATE {usersTable} SET section=:section WHERE user_id=:puid")
    for puid, section in sectionsByPuid.items():
        conn.execute(stmt, {'section': section, 'puid': puid})
print("Done!")
