import json,sys
doc=json.load(open(sys.argv[1]))
for x in (doc.get("summary") or {}).get("selectedDebtOutstanding") or []:
    print(x)
