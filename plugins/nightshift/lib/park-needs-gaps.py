import json, sys

for gap in json.load(open(sys.argv[1]))["gaps"]:
    sys.stdout.write("%s\t%s\n" % (gap["category"], gap["title"]))
