import xmlrpclib
import json
import pprint

# Create an object to represent our server.
server = xmlrpclib.ServerProxy('http://webworkdev.elearning.ubc.ca:8080/mod_xmlrpc');

# Call the server and get our result.
params = {'userID': 'admin', 'password': 'admin', 'courseID':'MATH101-201_2012W2', 'session_key': ''}

print "Retriving list of sets"
result = server.WebworkXMLRPC.listSets(params)
# make sure to reuse the session we've been assigned
params['session_key'] = result['session_key']

pp = pprint.PrettyPrinter()

for set in result['ra_out']:
	params['set_id'] = set
	print
	print "Retriving grades for set " + set
	grades = server.WebworkXMLRPC.getDetailedSetGrades(params)
	print 
	pp.pprint(grades)

#result = server.WebworkXMLRPC.hello2()
#print result
