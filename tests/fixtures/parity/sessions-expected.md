# 6. Runtime only.

<!-- usage -->
| Tokens | Amount |
| --- | ---: |
| input | 1.0M (partial) |
| cache write | unavailable |
| cache read | unavailable |
| output | 1.2k (partial) |
| reasoning | unavailable |

<!-- tokens 1012345 0 0 1244 0 -->
unknown · 5 sessions. Overlap between the dimensions is unknown for this host.

| Time | |
| --- | --- |
| working | 2h 9m |
| wall | 2h 45m |
| span | 2026-09-24T00:33Z → 2026-09-25T07:11Z |

**Sessions**

| # | Shift | Host · model | Start | End | Working | Paused | Input | Output | Cache write | Cache read | Reasoning | Ended |
| --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 11112222 | — | 2026-09-24T00:33Z | 2026-09-24T01:03Z | 29m 0s | — | 12.3k | 1.2k | — | — | — | switched away |
| 2 | — | — | 2026-09-24T22:46Z | 2026-09-24T22:47Z | 45s | — | unavailable | unavailable | — | — | — | blocked |
| 3 | aaaabbbb | — | 2026-09-25T01:33Z | 2026-09-25T03:33Z | 1h 30m | — | 1.0M | 7 | — | — | — | paused |
| 4 | aaaabbbb | — | 2026-09-25T04:20Z | 2026-09-25T04:30Z | 10m 0s | — | 50 | 3 | — | — | — | ticked |
| 5 | aaaabbbb | — | 2026-09-25T07:06Z | 2026-09-25T07:11Z | off | — | off | off | — | — | — | ticked |
| **Total** | 5 sessions | — |  |  | **2h 9m** | **unavailable** | **1.0M (partial)** | **1.2k (partial)** | **unavailable** | **unavailable** | **unavailable** |  |

<!-- session-data
1111222233334444 1790210000 1790211800 1740 12345 1234 switched-away
- 1790290000 1790290045 45 - - blocked
aaaabbbbccccdddd 1790300000 1790307200 5400 999950 7 paused
aaaabbbbccccdddd 1790310000 1790310600 600 50 3 ticked
aaaabbbbccccdddd 1790320000 1790320300 off off off ticked
-->
<!-- /usage -->
