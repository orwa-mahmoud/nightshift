# Changelog

Installs pin to the `version` in `plugins/nightshift/.claude-plugin/plugin.json`, so every entry here is a
version users receive. Dates are release dates; the tags carry the exact trees.

## [1.0.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.21.0...v1.0.0) (2026-09-09)


### ⚠ BREAKING CHANGES

* replace the shift report with per-item receipts and a runtime index

### Features

* **archive:** link live review records to their filed history ([f0544dc](https://github.com/orwa-mahmoud/nightshift/commit/f0544dcb0b49f4fec955b443fe35963829f6d363))
* **evidence:** define baseline and checkpoint evidence guidance ([c94585d](https://github.com/orwa-mahmoud/nightshift/commit/c94585d3f7289f493179826c7b1b99d4d99f287b))
* **receipts:** inject the receipt duty at item start, cadence, tick, resume, and clock-out ([52bac79](https://github.com/orwa-mahmoud/nightshift/commit/52bac79d16ff5fce3512272e2047f15d815d2e7f))
* replace the shift report with per-item receipts and a runtime index ([11eb48e](https://github.com/orwa-mahmoud/nightshift/commit/11eb48e2ab9159e0e5bbc2db1b49a2d670418804))


### Bug Fixes

* **archive:** file receipts by their item's state and keep their links whole ([4e47489](https://github.com/orwa-mahmoud/nightshift/commit/4e474892a2d5f7946207b009fba841cfa3174d48))
* **archive:** report a broken Filed pointer and file leftover reports ([bb529e5](https://github.com/orwa-mahmoud/nightshift/commit/bb529e5ff20acdcc161b5d54887d60268e8020c9))
* **doctor:** count receipt files, not report sections, when judging artifact completion ([475268f](https://github.com/orwa-mahmoud/nightshift/commit/475268f088a642d19c6e843f0e20139a41ed16e2))
* **doctor:** point the unusable-path act at receipts ([d8890c7](https://github.com/orwa-mahmoud/nightshift/commit/d8890c70c7874b91c434090f2f5dd3457ba64c0e))
* **hardhat:** allow a parking-lot entry to name the rules file it is about ([62b1793](https://github.com/orwa-mahmoud/nightshift/commit/62b1793d2a2be9ef5dc9ac423961afb701a5458b))
* **hardhat:** quote a backslash without tripping shellcheck ([1039e7f](https://github.com/orwa-mahmoud/nightshift/commit/1039e7fc291be0aa2b19463392ba378acdf2982c))
* **hardhat:** refuse a parking-lot write that reaches the rules file ([b83c5b0](https://github.com/orwa-mahmoud/nightshift/commit/b83c5b01601558d13cd3cc9c6695af8222a20797))
* **labels:** keep hyphenated item titles whole ([394f990](https://github.com/orwa-mahmoud/nightshift/commit/394f990488fad8bb35a124fcdd53b93bdb40600e))
* **manifests:** describe the plugin as coding shifts ([b82f3b2](https://github.com/orwa-mahmoud/nightshift/commit/b82f3b27b78c160730f9ae60190fcf0a289dcf00))
* **preflight-needs:** print one report layout on every host ([cfeae3a](https://github.com/orwa-mahmoud/nightshift/commit/cfeae3ad93fd4093badadd350010cd64f1e4db2d))
* **receipts:** freeze tonight's receipts block and keep titles on the index ([30e3f9b](https://github.com/orwa-mahmoud/nightshift/commit/30e3f9b8348e963d9f704a3d89fce0c736ad2642))
* **receipts:** inject pulse notices only for the owning session ([2804790](https://github.com/orwa-mahmoud/nightshift/commit/28047901cfbfc5dc02d6b0c250413c8b3fed4115))
* **receipts:** keep empty Windows label lists empty ([e0f7585](https://github.com/orwa-mahmoud/nightshift/commit/e0f75859a597a6101e442963c82938a6a6dce3d5))
* **receipts:** print missing item numbers from the Windows list ([9dd2425](https://github.com/orwa-mahmoud/nightshift/commit/9dd24254bc22ced9864c673edc6cfa8733e150fd))
* **receipts:** render the morning receipt from an accepted policy and link the index ([c37c646](https://github.com/orwa-mahmoud/nightshift/commit/c37c646a50c753fedc69c67e2308309d3d263451))
* **runtime:** name the exact path in a purge confirmation refusal ([67f122f](https://github.com/orwa-mahmoud/nightshift/commit/67f122f5d8832bf9e88bba8fcf4d901e4526168c))
* **runtime:** refuse an unknown link-workspace flag with usage ([acdbcbb](https://github.com/orwa-mahmoud/nightshift/commit/acdbcbb52fb254df729c571f12f13c7254d07394))
* **runtime:** render the continuity fence as readable JSON ([361d474](https://github.com/orwa-mahmoud/nightshift/commit/361d474fea526e3db0a2f942d48bda11a36efd99))
* **runtime:** say watchman absent when nothing ran ([78acb95](https://github.com/orwa-mahmoud/nightshift/commit/78acb955577e65b0e0d35f703cc746c325811e08))

## [0.21.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.20.0...v0.21.0) (2026-09-07)


### Features

* **archive:** file every record through one configured destination ([2cceaed](https://github.com/orwa-mahmoud/nightshift/commit/2cceaedca3f602b114093d695481cc1caf907ee1))
* **archive:** give the model its turn to file before the session ends ([5704413](https://github.com/orwa-mahmoud/nightshift/commit/5704413a241ed691fc3521ce09b8478746743f02))
* **archive:** support configurable lossless shift filing ([fed1947](https://github.com/orwa-mahmoud/nightshift/commit/fed19477722abae1a418c2d0464b6d4405e753f1))
* **gate:** hold the punch-list contract and items by digest while a shift is armed ([1baa5c9](https://github.com/orwa-mahmoud/nightshift/commit/1baa5c930227666b15562c0829529c794d7e9009))
* **gate:** send the full clock-out message only when the shift state changed ([aaf9254](https://github.com/orwa-mahmoud/nightshift/commit/aaf92548c57a00fbdb4f78fbff239957eeb273e4))
* **policy:** define unified owner settings contract ([6f6560b](https://github.com/orwa-mahmoud/nightshift/commit/6f6560b07ba3e6c3f2af4b285a274a8b5271c6c7))
* **policy:** fix the owner's preferences for the shift that is running ([40bc092](https://github.com/orwa-mahmoud/nightshift/commit/40bc0924888f61c41035b1a2ab8ee346a2f66441))
* **policy:** migrate remembered choices into the owner rules file ([11e660b](https://github.com/orwa-mahmoud/nightshift/commit/11e660b6e276d1b5b8eac84eb23c4bd2f045a3bc))
* **policy:** resolve the owner's preference blocks into the one view ([753947b](https://github.com/orwa-mahmoud/nightshift/commit/753947bc1c3c6ace6ec8f109c253d04afb74182f))
* **receipts:** support owner-defined handoff presentation ([7f0107f](https://github.com/orwa-mahmoud/nightshift/commit/7f0107f9238a1bc98d8ed4703f52fe04ba583750))
* **report:** accumulate item results and rotate closed shift records ([ec41e02](https://github.com/orwa-mahmoud/nightshift/commit/ec41e025e12fe9ec47be6c91af022487940fbe07))
* **report:** evaluate the progress cadence and the shift clock in the runtime ([5cb22bb](https://github.com/orwa-mahmoud/nightshift/commit/5cb22bbd22e6ff48e1bb8e9a7e9b5dfc2fd0a76c))
* **report:** measure per-item usage from the host's own records at the tick ([61c459e](https://github.com/orwa-mahmoud/nightshift/commit/61c459e5cadb43fcc28425bf2183fe5360d514c6))
* **runtime:** add the ns dispatcher — one verb per helper, host and workspace resolved by the runtime ([1352562](https://github.com/orwa-mahmoud/nightshift/commit/1352562e7979b8f34c034fc34fdffc748b5f9c87))
* **runtime:** print the next punch-list item and the gates on request ([803bfb4](https://github.com/orwa-mahmoud/nightshift/commit/803bfb4ff4bb01a723adc1a6825004ae27e79ca2))
* **setup:** scaffold the state directory with a helper ([f3bd83e](https://github.com/orwa-mahmoud/nightshift/commit/f3bd83e4ee279dee80bb05b974c05b301669137d))
* **start:** print the explanation and repair for each preflight verdict ([7573143](https://github.com/orwa-mahmoud/nightshift/commit/7573143c4b74dcffd0fcd528e3e4a5da16a6b909))
* **status:** print every status fact from the helper ([5b1963f](https://github.com/orwa-mahmoud/nightshift/commit/5b1963f0347b4a1c226f3c87fb0c48f10292ae61))
* **usage:** account for a shift's cost on native Windows ([f9ddc8d](https://github.com/orwa-mahmoud/nightshift/commit/f9ddc8d613180a7e4668f990eb700bc1a6108680))


### Bug Fixes

* **archive:** contain the whole destination path, not just its last part ([d31db65](https://github.com/orwa-mahmoud/nightshift/commit/d31db658d943a0a9fa4e5398d6eccfe02f979dc3))
* **archive:** keep a finished shift's identity through its filing ([8fda33f](https://github.com/orwa-mahmoud/nightshift/commit/8fda33f356b2cf7f6226da46d01b74433ab4c9e0))
* **archive:** rebase every relative link when the report moves ([75b4a09](https://github.com/orwa-mahmoud/nightshift/commit/75b4a09d97027d1a0e4c9b10f0d226cef0d060c4))
* **archive:** retire only the records established as closed ([bb1664d](https://github.com/orwa-mahmoud/nightshift/commit/bb1664d3f32b558638d5c12e3808888bbfc5259b))
* **evidence:** reject unavailable sources without finding rows ([6258746](https://github.com/orwa-mahmoud/nightshift/commit/6258746f7a71c89750a8d70755238e36e9c2490f))
* **gate:** account for a stop only once the stopping session owns the shift ([a7734eb](https://github.com/orwa-mahmoud/nightshift/commit/a7734eb235d87e0afdcf0f6d9800352610a73ce2))
* **hardhat:** inspect here-documents that an interpreter runs ([4ed4c5c](https://github.com/orwa-mahmoud/nightshift/commit/4ed4c5c30f15cf586decf3fac02ae784957a8fe5))
* **hardhat:** read a quoted heredoc body as data, not as a command ([0599338](https://github.com/orwa-mahmoud/nightshift/commit/0599338e4ea36c6ae83dc21a6d72cc2e86596dc8))
* **hooks:** bound the read of a hook's stdin ([ca14662](https://github.com/orwa-mahmoud/nightshift/commit/ca1466206c3a6423d064a4dc3b1dcc5555f0a9c8))
* **hooks:** run the Claude pulse's block after the functions it calls ([a9e7adc](https://github.com/orwa-mahmoud/nightshift/commit/a9e7adcc29421f18f09d35366bd86cd236698d28))
* **hooks:** ship the Windows SessionStart hook the dispatch file calls ([27cef67](https://github.com/orwa-mahmoud/nightshift/commit/27cef672e6d22ffea5060585d8a9bdfb6b2ce660))
* **normalize:** reject incomplete JUnit reports ([3f9387b](https://github.com/orwa-mahmoud/nightshift/commit/3f9387b39ad389a95177718cfa6b15b429da57e1))
* **normalize:** retain TypeScript error counts or report unavailable ([6d4f46e](https://github.com/orwa-mahmoud/nightshift/commit/6d4f46e1f1ac0016f36729ea1f1ffde97072c7a5))
* **ns:** honour the bound workspace, and refuse a mismatch before writing ([c5a1912](https://github.com/orwa-mahmoud/nightshift/commit/c5a1912e96490c467459d336d051bf35d12e29ff))
* **profiles:** write remembered choices where they are read from ([5cc24ac](https://github.com/orwa-mahmoud/nightshift/commit/5cc24acb52476dde9f61358f8780f897b6b33dbe))
* **receipts:** preserve evidence in clock-out handoffs ([65518e7](https://github.com/orwa-mahmoud/nightshift/commit/65518e72ff8768962e5643962eef058a8ae3aaf3))
* **recovery:** preserve authorized host permissions ([b336057](https://github.com/orwa-mahmoud/nightshift/commit/b33605768b4d9825a80ddd8a6eae4431e8015bd1))
* **recovery:** refuse a revival that cannot be shown to inherit its scope ([67ad1e6](https://github.com/orwa-mahmoud/nightshift/commit/67ad1e6d8a9b6a8f4c4e7ba2c697cd52b1965d05))
* **recovery:** resolve the launch scope the same way on every host ([6f95ccc](https://github.com/orwa-mahmoud/nightshift/commit/6f95ccc1adc0fe2ae4e8471aeefcfc3900c89bb8))
* **recovery:** revive with the permissions the shift was started under ([16d2d56](https://github.com/orwa-mahmoud/nightshift/commit/16d2d564d9503e42788c2180f0dbca9b85a038a9))
* **references:** give the GitHub issue hunt one spelling per command ([dea9a6f](https://github.com/orwa-mahmoud/nightshift/commit/dea9a6f37bbb3d687f47cceced3ba85a62684a30))
* **references:** point the catalog recipe at the cited-research page ([5f1428e](https://github.com/orwa-mahmoud/nightshift/commit/5f1428e6de5ec6b2eb1f4c04798dc0b1c5f2d2e8))
* **references:** restore the names that are not commands to every receipt kind ([86b62dc](https://github.com/orwa-mahmoud/nightshift/commit/86b62dc06264b1c5a877e862dc67c5476a771ab9))
* **runtime:** let native Windows evidence-archive name the file it wrote ([3ac5b0a](https://github.com/orwa-mahmoud/nightshift/commit/3ac5b0a520de341c31331db6a267c7f0b09960d7))
* **runtime:** make the morning-receipt renderer executable ([de83900](https://github.com/orwa-mahmoud/nightshift/commit/de83900a5a15eb605a90014d6362d4d5f05e95ff))
* **runtime:** make the native Windows morning page match the POSIX one ([bf3f97e](https://github.com/orwa-mahmoud/nightshift/commit/bf3f97eefd5fcb1341535178aaa9f0cbc15bcda5))
* **runtime:** preserve owner policy without optional parsers ([93597b0](https://github.com/orwa-mahmoud/nightshift/commit/93597b0854a8450cdc9902e4531b44094db05ad7))
* **schema:** apply a numeric bound to numbers, and restore the one on hours ([118efcb](https://github.com/orwa-mahmoud/nightshift/commit/118efcb96dc35d602f250fc7098c16a48cf46e49))
* **skills:** honor resolved owner choices across the shift ([8c4fd25](https://github.com/orwa-mahmoud/nightshift/commit/8c4fd25f3c619e5897aa9a6c4be036be515cf6da))
* **skills:** repair three fragments left by the command-spelling pass ([543d001](https://github.com/orwa-mahmoud/nightshift/commit/543d001b7a400b97ab20227dad64f0b7742124b0))
* **skills:** route the model to every receipt kind ([5c7a2cf](https://github.com/orwa-mahmoud/nightshift/commit/5c7a2cf2e37ad02176b140e50e7b7f0e9da9d470))
* **skills:** state each rule once, and point at it ([16675af](https://github.com/orwa-mahmoud/nightshift/commit/16675af3da30a4f5d48b14f5ba5faa2fa70e71cb))
* **start:** keep the fence inspection and the control decision on their verdicts ([ad17252](https://github.com/orwa-mahmoud/nightshift/commit/ad1725259a422cd2d291230345c6a7b44675b397))
* **start:** offer linking as well as relaunching on a binding mismatch ([f7253bf](https://github.com/orwa-mahmoud/nightshift/commit/f7253bfd1587734d8f084254845482d5023e3a50))
* **usage:** bill only an armed shift its owner is working, and keep CI green on every host ([eb1784c](https://github.com/orwa-mahmoud/nightshift/commit/eb1784c8f7b1aae52130c5acbc7321287fcc2015))
* **usage:** count a response once when its lines straddle two reads ([0b71bce](https://github.com/orwa-mahmoud/nightshift/commit/0b71bce76a46b6c796d308232f3fd92836b1492a))
* **usage:** mark an item when it is ticked, not when the session stops ([540e8e1](https://github.com/orwa-mahmoud/nightshift/commit/540e8e167cfee8a369bd6251b139c25ded2a489d))
* **usage:** retire a finished shift's accounting when the next one arms ([ee6e31e](https://github.com/orwa-mahmoud/nightshift/commit/ee6e31e8a96e3cab580b24f2e6fc2f706cbed7db))
* **usage:** start each transcript where it stood when the shift armed ([96e849f](https://github.com/orwa-mahmoud/nightshift/commit/96e849f64e7eaedaa4aa9c29728312dcbc2751e8))
* **watchman:** keep a claim that has changed hands ([311f64c](https://github.com/orwa-mahmoud/nightshift/commit/311f64c1e04bd0e4c19cf79828db0f64d6dc5f2f))

## [0.20.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.19.0...v0.20.0) (2026-09-05)


### Features

* **start:** one native preflight prints a verdict per line (`ok` / `warn` / `refuse`) and arms without asking, so a scheduled run behaves like an interactive one; it needs neither jq nor python3
* **hunt, quality:** the owner's sentence is the objective — no keyword router. A time budget plus an actionable goal composes and runs directly. Feature, product, or UI work given to Quality continues as Hunt; quality tools do not hijack that night
* **policy:** hooks read Nightshift's own `rules.json` with a bundled reader (POSIX awk + bash, Windows `ConvertFrom-Json`). A malformed file fails closed and does not arm
* **rules:** five elevation categories — `sudo`, `containers`, `global-packages`, `daemons`, `external-services` — are denied by default. Elevation gates creating system state (`docker run`, `brew install`, path-prefixed or `sh -c` `sudo`); `docker ps` and `brew list` stay ordinary work. Built-in patterns match the shipped template whether or not the file carries an `elevation` object and whether or not jq is on PATH
* **receipts:** the model writes the morning receipt from a template under `.nightshift/receipts/`. Status and Doctor show one resolved policy block and the source of every effective setting
* **runtime:** the plugin ships no Python. Skills read helper verdicts instead of runbooks. Auto-add is the model plus a bash/PowerShell seatbelt (`baseline` / `diff` / `rollback`); there is no install engine and no pinned recipe catalog
* **catalog:** 30 stand-alone shifts that use the project's own tools or report `unavailable`. Tooling hints name common tools; they pin no version and run no install
* **hosts:** Claude Code, Codex, and Cursor share the same contract. Cursor's question tool is denied during a shift, same as the other two hosts


### Bug Fixes

* **hardhat:** control-file denies compare canonical absolute paths, so `.nightshift//`, `/./`, `/../`, and `\\` forms cannot write `shift-policy.json` or the other control files
* **hardhat:** STOP means stop work now; the hook stays armed until clock-out writes `.ended`. Reset is the explicit escape
* **runtime:** the worker fence reads the on-disk lease / session / pid. A model-authored "I am not a duplicate" cannot take over; a missing fence refuses to arm
* **evidence:** finding ids stay inside `.nightshift`; temps that hold tool output use mode `700`. An unreadable punch list fails closed — clock-out does not release as "0 open"
* **policy:** verification defaults to `none` on POSIX and Windows unless the owner or a profile set one
* **support:** the default bundle is an allowlisted subset (version, markers, policy summary, counts). Raw `scheduled.log` and unrestricted evidence are omitted. There is no secret scanner and no "redacted / sanitized" claim
* **hooks:** a punch list that exists but cannot be counted keeps hardhat armed on both engines
* **windows:** PowerShell 5.1 no longer uses unguarded `ProcessStartInfo.ArgumentList`
* **docs:** drop "optional Python / honest skip", "hardhat is a sandbox", and planner/redaction claims that the runtime does not keep

## [0.19.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.18.1...v0.19.0) (2026-09-01)


### Features

* **codex:** stand watchman down on SessionEnd and pulse the bound session ([8dc70eb](https://github.com/orwa-mahmoud/nightshift/commit/8dc70eb087eef3dccc15ef27c04f10141f26841d))


### Bug Fixes

* **claude:** pulse the bound session so a quiet live tab is not guessed dead ([38ba175](https://github.com/orwa-mahmoud/nightshift/commit/38ba175704f046cf5e0077289dbf08fae1728dfa))
* **cursor:** keep a quiet IDE shift alive until the owner closes it ([3a91882](https://github.com/orwa-mahmoud/nightshift/commit/3a91882b84b6d25793306831664ba5ae475075fe))
* **windows:** accept SessionEnd stdin and age Codex recovery fixtures ([431a200](https://github.com/orwa-mahmoud/nightshift/commit/431a200f388e2708dc3a3fe1d333d63bf63bfa8a))

## [0.18.1](https://github.com/orwa-mahmoud/nightshift/compare/v0.18.0...v0.18.1) (2026-08-29)


### Bug Fixes

* **cursor:** keep Claude marketplace hooks off Cursor leases ([9991770](https://github.com/orwa-mahmoud/nightshift/commit/999177069386b804a3f85ef4e9a66cee3c4b8312))

## [0.18.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.17.0...v0.18.0) (2026-08-29)


### Features

* **cursor:** register the plugin in the repo-root marketplace file ([fe03d00](https://github.com/orwa-mahmoud/nightshift/commit/fe03d0092961bd15c101298d6f6c65c9c1f7dd86))


### Bug Fixes

* **cursor:** reuse the shipped Codex logo on the Cursor listing ([050747b](https://github.com/orwa-mahmoud/nightshift/commit/050747b6e5554dc480577ad3ebdc8faf47b863d0))

## [0.17.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.16.0...v0.17.0) (2026-08-29)


### Features

* **cursor:** ask before writing CLI file hooks ([51389c6](https://github.com/orwa-mahmoud/nightshift/commit/51389c6c4778c9a191d2d2bc91b0fb01c85274b0))
* **cursor:** revive dead shifts in a CLI worker ([3c1af44](https://github.com/orwa-mahmoud/nightshift/commit/3c1af448398e1183de7c39560510cd1e3df91a38))


### Bug Fixes

* **cursor:** tell the origin tab how to attach or stop ([d26a867](https://github.com/orwa-mahmoud/nightshift/commit/d26a8673ca489ef30c10982022759734f75956d1))

## [0.16.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.15.0...v0.16.0) (2026-08-28)


### Features

* **cursor:** first-class Cursor plugin ([a718ce6](https://github.com/orwa-mahmoud/nightshift/commit/a718ce6dc8aa4e90fd23ac1e19c490c0c0ffce79))
* expose remaining owner knobs in rules.json ([cac9368](https://github.com/orwa-mahmoud/nightshift/commit/cac936894788f92a5db8a8f8bc28cf301d771121))


### Bug Fixes

* **cursor:** pass hook argv through to cursor_read_input ([237f84f](https://github.com/orwa-mahmoud/nightshift/commit/237f84fccae9388dcfaf59ee8a717c4e26349486))
* **cursor:** pin Stop interrupt to the live aborted payload ([c4f3344](https://github.com/orwa-mahmoud/nightshift/commit/c4f33449bf10d67e6f942e5eaae934a72f7ce955))

## [0.15.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.14.5...v0.15.0) (2026-08-28)


### Features

* add a finite research-synthesis catalog shift ([c739695](https://github.com/orwa-mahmoud/nightshift/commit/c739695f2836d43bc0fc67ee9f7f126f15e743f6))
* add a finite SEO audit catalog shift ([ab17a81](https://github.com/orwa-mahmoud/nightshift/commit/ab17a81bc0ea495660a982f7bff2351adbaf5bb6))
* add a finite sourced documentation-writing shift ([b09850e](https://github.com/orwa-mahmoud/nightshift/commit/b09850e04be7f81f371c6da8a0ba8803586a38f3))
* add a reusable cited research-and-report contract ([53dfcd6](https://github.com/orwa-mahmoud/nightshift/commit/53dfcd65d9b98980667c1414162eeb80edc6445e))
* add an isolated-branch rule profile ([885f943](https://github.com/orwa-mahmoud/nightshift/commit/885f94380a9e681938742d5ebff1f0f34ae0126c))
* copy artifact receipts into the dated archive with a helper ([c34b9c8](https://github.com/orwa-mahmoud/nightshift/commit/c34b9c82ca55c3055ea3db5a1f855130663421ee))
* discover rule profiles from the shipped directory ([9bbebc4](https://github.com/orwa-mahmoud/nightshift/commit/9bbebc498f8c23f26bb6724a82507c9754327d2d))
* inspect the work target during automatic Hunt selection ([c1a0d47](https://github.com/orwa-mahmoud/nightshift/commit/c1a0d47c9374581c059763e21adbabb0a0185520))
* leave an Archive note when a campaign is fully filed ([5fa842f](https://github.com/orwa-mahmoud/nightshift/commit/5fa842fcc10863acb95ada02d2b907c07f6febca))
* name product-evolution branches for morning review ([d0dbb49](https://github.com/orwa-mahmoud/nightshift/commit/d0dbb49ce58fd7f5fa90fb3c516d3e72951e5a0e))
* name the latest artifact receipt in Doctor ([26fa7da](https://github.com/orwa-mahmoud/nightshift/commit/26fa7da9d9e0e6de0e9337152a97b21477e04b56))
* offer to restore a leftover punch-list contract in Setup ([cf6fb5b](https://github.com/orwa-mahmoud/nightshift/commit/cf6fb5b7595f23bceecd35f90762a2de9d41d824))
* persist repository and artifact work modes ([bb99a0b](https://github.com/orwa-mahmoud/nightshift/commit/bb99a0b9b54d61a147d2cea9b885e71dda6cc1ec))
* propose plugin and shell gates from Setup ([f901756](https://github.com/orwa-mahmoud/nightshift/commit/f90175642955c42eabc91d36c219ec46ae8388ba))
* surface leftover punch-list contracts after a finished shift ([e3bd09f](https://github.com/orwa-mahmoud/nightshift/commit/e3bd09f44cfd5d80efd8ea799b146eae018cbb8c))
* warn when artifact ticks have no receipts ([4fee9e9](https://github.com/orwa-mahmoud/nightshift/commit/4fee9e9f705d96dc836efeea11b06ce62aa6454f))
* write artifact completion receipts without a git commit ([19455ba](https://github.com/orwa-mahmoud/nightshift/commit/19455bad4318338fe6afe44bb0fe0e2beb4869c6))


### Bug Fixes

* bound terminal clock-out and restore the interactive lease ([f695e15](https://github.com/orwa-mahmoud/nightshift/commit/f695e1584b3d8562ad4ca6be1f517af91ad9218e))
* claim a real session record over a planted shift-session symlink ([20a0049](https://github.com/orwa-mahmoud/nightshift/commit/20a00496e42fed8eeddb206e070dfb6f293b1c49))
* close git -C and git -c holes in isolated-branch ([845e853](https://github.com/orwa-mahmoud/nightshift/commit/845e853269c31d49386cf989b53fd1ee2de5bf82))
* cut proposed imports through the promote helper on Schedule ([d0a75a2](https://github.com/orwa-mahmoud/nightshift/commit/d0a75a26598f5228872243cb50d87d5358e37bd0))
* cut proposed imports through the promote helper on Start ([ebcd07e](https://github.com/orwa-mahmoud/nightshift/commit/ebcd07e825e709d6e6485f1aa1cfea53e0acfe9b))
* cut the whole work-order section, not just the box ([b5fbc6a](https://github.com/orwa-mahmoud/nightshift/commit/b5fbc6a84d88981fb20ace4325956c908ac73780))
* detect plugin gates under plugins/&lt;name&gt; ([515d64c](https://github.com/orwa-mahmoud/nightshift/commit/515d64cf7cfbb9e0a3e3b7d5614a56889db93e13))
* diagnose empty watchman recovery keys in Doctor ([fbcd448](https://github.com/orwa-mahmoud/nightshift/commit/fbcd44853562084f5d256d905629f881c41f9e4d))
* disarm Stop immediately and add Reset and Purge helpers ([dd1b96a](https://github.com/orwa-mahmoud/nightshift/commit/dd1b96ab675da2d2edc82ed2fd48278d3eaf29c9))
* do not count the drafting-table example as staged work ([85da326](https://github.com/orwa-mahmoud/nightshift/commit/85da326940ce612be77fdc228c7d3140ef4b962b))
* do not follow dated archive symlinks when detecting known issues ([b203984](https://github.com/orwa-mahmoud/nightshift/commit/b203984eb5b067aa8b375b2ef3dbc0fdb551b7bb))
* Doctor offers Setup when unset mode would be artifact ([d1f7af7](https://github.com/orwa-mahmoud/nightshift/commit/d1f7af749399f029d6519562cdbafdbdc5393363))
* Doctor warns when unset mode would be artifact ([a8e77ed](https://github.com/orwa-mahmoud/nightshift/commit/a8e77ed17d23985a661505a165467a9ed9c43a56))
* export-support does not treat a symlink armed marker as armed ([fd191d6](https://github.com/orwa-mahmoud/nightshift/commit/fd191d6f503e52be07817ae4492cc2f030467454))
* export-support does not treat a symlink ended marker as clocked out ([962f2b6](https://github.com/orwa-mahmoud/nightshift/commit/962f2b637d29661f9cb6736eab105c7c5122ef2d))
* export-support does not treat a symlink session-end as a clean exit ([7935d4d](https://github.com/orwa-mahmoud/nightshift/commit/7935d4da30c90628ad32dab748e97975bb996f10))
* export-support does not treat a symlink shift-session as recorded ([ba922b6](https://github.com/orwa-mahmoud/nightshift/commit/ba922b6b8a4d843d3daa5bcddbc91a0b7256da02))
* export-support reads plugin name without jq ([b51c59d](https://github.com/orwa-mahmoud/nightshift/commit/b51c59db32cb86c35dab02369dfae6c28d33dbea))
* fail closed Windows protected-dir git-dir writes ([61da12b](https://github.com/orwa-mahmoud/nightshift/commit/61da12bc5bc6dcd9f3ca45f36b5eea7b12fd0d87))
* fail schedule preflight on empty watchman recovery keys ([baf03e2](https://github.com/orwa-mahmoud/nightshift/commit/baf03e2752ac6d24cb6ebfabe26b170566ffcb62))
* give Hunt and Quality the same four-file state map ([48f5c10](https://github.com/orwa-mahmoud/nightshift/commit/48f5c105437056e0ebcce057faa0b24d4bb512e2))
* give Status native Windows deadline and reason helpers ([4db762a](https://github.com/orwa-mahmoud/nightshift/commit/4db762a63f5561bf021b2f3880329da4312ffe53))
* Hunt refuses to compose on an unset notes folder ([81a8ac3](https://github.com/orwa-mahmoud/nightshift/commit/81a8ac3ad22a4b4841d13d4b4c8615d7d8623460))
* Hunt refuses to compose when the work target cannot be resolved ([9cc706e](https://github.com/orwa-mahmoud/nightshift/commit/9cc706e0db0eac5986127e92c371ccf95daadaa5))
* Hunt refuses to compose when work-mode is malformed ([410069b](https://github.com/orwa-mahmoud/nightshift/commit/410069b6d5c85b6a1541d4547148db71f50fc84c))
* ignore nested files under artifact receipts ([980c4f3](https://github.com/orwa-mahmoud/nightshift/commit/980c4f381af6d4f44bc5f9d3cf87717f57e9cd30))
* import the Windows module before Hunt identity check ([f47c5fb](https://github.com/orwa-mahmoud/nightshift/commit/f47c5fb945e4c544661289f155cd86e44bf257db))
* inspect artifact folders during automatic Hunt and Quality ([77730b3](https://github.com/orwa-mahmoud/nightshift/commit/77730b30cd834ceb7ecb73f08247d150cac26d8d))
* inspect the work target in open-ended catalog shifts ([60ed28b](https://github.com/orwa-mahmoud/nightshift/commit/60ed28b9be06f9c5626d29b33ecf9208681c8dfa))
* isolate open-ended catalog shifts without git-init ([d3890f3](https://github.com/orwa-mahmoud/nightshift/commit/d3890f361e4d9b2f7faab8b71a721736ab1ea52e))
* keep Hunt's one-shift contract mode-aware ([3fe25e9](https://github.com/orwa-mahmoud/nightshift/commit/3fe25e924421c7ab8b9dd64d90225134c82093d2))
* keep TrustedShiftControl array-safe under StrictMode ([8e5c4d3](https://github.com/orwa-mahmoud/nightshift/commit/8e5c4d37db77daad72d7ee9e7cb9a448e3a46534))
* let Quality detect nested plugin manifests ([1295dda](https://github.com/orwa-mahmoud/nightshift/commit/1295dda9de0f78fc0c7307d7bed0698f29b86c0b))
* match the Windows session-end marker to POSIX ([00eaf8e](https://github.com/orwa-mahmoud/nightshift/commit/00eaf8e4d5ea6c6cc9d4657bedaf5fe903ce2898))
* match Windows Doctor process start times ([a82a272](https://github.com/orwa-mahmoud/nightshift/commit/a82a272fe5509132065d1d3d054ee381e608c501))
* match Windows expected-email denials to POSIX ([bb7884c](https://github.com/orwa-mahmoud/nightshift/commit/bb7884c4eb4d1834a20af8d2e91e6e3f94a5ba99))
* match Windows forbidden-command denials to POSIX ([2b438cb](https://github.com/orwa-mahmoud/nightshift/commit/2b438cb8c6bcbb82853941a773818c6f76bc2650))
* match Windows never-commit denials to POSIX ([6dc0f40](https://github.com/orwa-mahmoud/nightshift/commit/6dc0f400e2d8cbbd7f5c3da4fa34a9217c7c6048))
* match Windows watchman pid to its start time ([218d7e1](https://github.com/orwa-mahmoud/nightshift/commit/218d7e115cbefdf236569dc363d33053a6560e80))
* match Windows watchman start before Start stand-down ([ed44002](https://github.com/orwa-mahmoud/nightshift/commit/ed440026108f756803bf5f07cb0d97ab406230ae))
* name artifact receipts in revival and Start work ([fe7a196](https://github.com/orwa-mahmoud/nightshift/commit/fe7a1965f3beb53d17d4e811291beac7389181d2))
* name Hunt and Quality watchman launchers ([c046d54](https://github.com/orwa-mahmoud/nightshift/commit/c046d549670e746b13878d5f99b3a9bef7bf2a17))
* name native flags in Windows helper errors ([14460b1](https://github.com/orwa-mahmoud/nightshift/commit/14460b1db882a659b60309e3bed8fbd228945877))
* name parked work when schedule preflight finds an empty list ([5605df6](https://github.com/orwa-mahmoud/nightshift/commit/5605df646aa0d3e5d82b39d165e486ff69dea8d4))
* name portable dates for archive folders ([daf6450](https://github.com/orwa-mahmoud/nightshift/commit/daf6450713ae87190ba4b70d9e3143818bf2355b))
* name Setup in the Windows unreadable-rules clock-out ([2be4ea3](https://github.com/orwa-mahmoud/nightshift/commit/2be4ea3c9af0baa22f430995bd14d50f59d6c882))
* name Setup in Windows toolDeny hardhat repairs ([6105c43](https://github.com/orwa-mahmoud/nightshift/commit/6105c433e274f13794ba9aa96831e04ebbd15645))
* name Setup when Windows schedule finds no state ([7586cbf](https://github.com/orwa-mahmoud/nightshift/commit/7586cbfce06f52eca75945e1ae8b3cdc54739bb9))
* name Setup when Windows watchman cannot read rules ([c962111](https://github.com/orwa-mahmoud/nightshift/commit/c96211100acd6ebcfc3d57a5b5ca3adbfb856b5e))
* name the env var when a Windows pattern is invalid ([64ff559](https://github.com/orwa-mahmoud/nightshift/commit/64ff559e52780c8c339880b805fb668e66a1ded1))
* name the headless receipts commit in Archive ([2615386](https://github.com/orwa-mahmoud/nightshift/commit/2615386341926d57f5dee3eec905d8769874b5e9))
* name Windows Codex agent flag in Schedule permissions ([4f1655b](https://github.com/orwa-mahmoud/nightshift/commit/4f1655b129ba08770cf6ff054d7366c754830875))
* name Windows JSON key listing in Setup and Start ([156e9a3](https://github.com/orwa-mahmoud/nightshift/commit/156e9a379dd46a7d61e545f98b252c40806d2046))
* name Windows lease helpers in Start preflight ([26a66a6](https://github.com/orwa-mahmoud/nightshift/commit/26a66a62b59fd605e3ecf1522e23e17cf9e7d3fe))
* name Windows schedule list and remove in the skill ([9353e95](https://github.com/orwa-mahmoud/nightshift/commit/9353e956d8557ce60f2a505579031c865b46eece))
* offer a replace action when receipts path is unusable ([2d732d8](https://github.com/orwa-mahmoud/nightshift/commit/2d732d8c9a1fa98afc6e81edb30bc0824ddb9fe6))
* pair Windows import-issues flags in the skill steps ([486b6c1](https://github.com/orwa-mahmoud/nightshift/commit/486b6c1b2509004866d4873b451d7da5aa7d130d))
* pick the latest artifact receipt by mtime ([8be7d04](https://github.com/orwa-mahmoud/nightshift/commit/8be7d0422041c3146341867a3e79345efe7457ab))
* rank Automatic Hunt by work-target evidence ([aa09eca](https://github.com/orwa-mahmoud/nightshift/commit/aa09eca04a4b90529fef04abfab0d75810816866))
* read Status process liveness from Doctor ([d2f4f7f](https://github.com/orwa-mahmoud/nightshift/commit/d2f4f7fe3662819ada54dc9b9515e44fa3d4c608))
* refuse a non-directory archive dest ([213970d](https://github.com/orwa-mahmoud/nightshift/commit/213970d6661d54e0260bd20bba9c0db469b7aad1))
* refuse a non-directory archive receipts source ([8251266](https://github.com/orwa-mahmoud/nightshift/commit/82512669c8991244bfb7149bf2cf0c7c44aa3af1))
* refuse a non-directory receipts path ([f20426f](https://github.com/orwa-mahmoud/nightshift/commit/f20426fe550b36b2ce32ed4ad82633d627ace134))
* refuse a symlink receipts directory ([71f1875](https://github.com/orwa-mahmoud/nightshift/commit/71f1875070548ddc89213c64fcb84eed6db284a1))
* refuse Hunt compose when artifact receipts path is unusable ([bc9bb04](https://github.com/orwa-mahmoud/nightshift/commit/bc9bb04ab7e223cd620c7be430a5c1937291a319))
* refuse symlink outputs in Windows check-report ([12b9ce0](https://github.com/orwa-mahmoud/nightshift/commit/12b9ce02434c9c2aef26c1fa6b7f7fade2cfb615))
* refuse symlink outputs in Windows write-receipt ([cbe941e](https://github.com/orwa-mahmoud/nightshift/commit/cbe941ea1fddab68c129075d98b7b8acf4f68e35))
* refuse to arm Start when watchman recovery keys are empty ([42a4f11](https://github.com/orwa-mahmoud/nightshift/commit/42a4f1160af6f7d13b5fef4a154f73688bfc0943))
* refuse to arm when artifact receipts path is unusable ([6673369](https://github.com/orwa-mahmoud/nightshift/commit/6673369d453b37208a389ae1ffaa9a85de503ef1))
* refuse to schedule when artifact receipts path is unusable ([e7df569](https://github.com/orwa-mahmoud/nightshift/commit/e7df569c9af7b37f0160d1aba102283e6fdc6405))
* refuse Windows profile apply while a shift is armed ([0a3abec](https://github.com/orwa-mahmoud/nightshift/commit/0a3abec5a9babc63521b78aa4a985a450108d284))
* report the deadline file from Doctor ([3429a13](https://github.com/orwa-mahmoud/nightshift/commit/3429a134516005a53d854404915fe9e7b9b038a9))
* restore punch-list history without git-init of notes folders ([f763f03](https://github.com/orwa-mahmoud/nightshift/commit/f763f0352d798e26b3af17d41a310235d41b0d7a))
* run Hunt Codex identity check before watchman ([2272694](https://github.com/orwa-mahmoud/nightshift/commit/2272694ed3a518fdf2538ada2d719aa4c55b0b3c))
* run the item gate before a commit or artifact receipt ([5f6e99c](https://github.com/orwa-mahmoud/nightshift/commit/5f6e99c4e2255e6247cd895f6d172a321694eefd))
* satisfy Ubuntu ShellCheck and Windows PowerShell parsing ([e754c6e](https://github.com/orwa-mahmoud/nightshift/commit/e754c6e77543a8d4386d908aa48620c043384042))
* Schedule refuses an unset notes folder ([fa3f6ed](https://github.com/orwa-mahmoud/nightshift/commit/fa3f6edd218ee0b3a4999645ebf9c56b9ecded48))
* Schedule refuses when the work target cannot be resolved ([5ff4971](https://github.com/orwa-mahmoud/nightshift/commit/5ff49712014248c7b842b1043cb6aad80fd173f2))
* send Quality cuts through the Hunt work-order file ([f267324](https://github.com/orwa-mahmoud/nightshift/commit/f267324564ae7c413d747f7360024147b409d1d4))
* skip a symlink child git repo when proposing work mode ([8035762](https://github.com/orwa-mahmoud/nightshift/commit/8035762399e0f4c34f18c0eff7e6b25ca9c55502))
* skip a symlink shift-session in watchmen and session-end ([f48af51](https://github.com/orwa-mahmoud/nightshift/commit/f48af511e8ce720e80140d029dc178f94c1c0125))
* skip Automatic Hunt entries the work target cannot support ([0d9445c](https://github.com/orwa-mahmoud/nightshift/commit/0d9445cced08d0a80a74ed6356b9df59185cc1b8))
* skip coverage hunt in artifact mode ([6f1d459](https://github.com/orwa-mahmoud/nightshift/commit/6f1d4595bde1502119cb930cbfd152159d199ac6))
* skip defect hunt in artifact mode ([238344c](https://github.com/orwa-mahmoud/nightshift/commit/238344c7fc578a00fa73264df074d36586871200))
* skip documentation drift in artifact mode ([a06a0ed](https://github.com/orwa-mahmoud/nightshift/commit/a06a0ed164f949dd87f14fc3552b37a3b0de8183))
* skip empty dated folders when nothing copies ([45cac1a](https://github.com/orwa-mahmoud/nightshift/commit/45cac1a3b37dc08a1c889fb41cf9e5602b3988e8))
* skip Quality entries the work target cannot support ([7b2d6eb](https://github.com/orwa-mahmoud/nightshift/commit/7b2d6eb1cff300058a066b00007dd1b54c283e2f))
* skip symlink dated archive dirs at retention listing ([b9adc46](https://github.com/orwa-mahmoud/nightshift/commit/b9adc4661f3252b5c46944a33abc8856cffe7a94))
* skip symlink files in Windows receipt count ([6781bdd](https://github.com/orwa-mahmoud/nightshift/commit/6781bdda90598993635fcdd1eca272c84e525da3))
* skip symlink punch-lists in Windows archive retention ([b21d577](https://github.com/orwa-mahmoud/nightshift/commit/b21d577a36b54d207b97f0e01e2f07c908b28ebd))
* skip the GitHub issue hunt in artifact mode ([5d6c085](https://github.com/orwa-mahmoud/nightshift/commit/5d6c0850bbc354fdc52d58a753a189fdd35cf211))
* skip TODO and FIXME debt in artifact mode ([09cbaff](https://github.com/orwa-mahmoud/nightshift/commit/09cbaff61b1fc8e29d6d34fbbf82a37214c0c4b1))
* skip tooling quality-debt catalog entries in artifact mode ([46fb925](https://github.com/orwa-mahmoud/nightshift/commit/46fb92539304b76e20dfca3db819cbce8c84c0fe))
* Start refuses to arm an unset notes folder ([2daff15](https://github.com/orwa-mahmoud/nightshift/commit/2daff1581e8424e6e4ab4461620d54b6dafadb5a))
* stop Windows import-issues from eating issue URLs as -Repo ([295689a](https://github.com/orwa-mahmoud/nightshift/commit/295689a9529739c715836d9304a4c3973fc228fa))
* treat a symlink deadline as not passed ([6851eeb](https://github.com/orwa-mahmoud/nightshift/commit/6851eebba0feba2842b790a473bf75751e656b39))
* treat a symlink ended marker as not a clock-out ([83cd676](https://github.com/orwa-mahmoud/nightshift/commit/83cd676045a8863657d394490e43c42eb3672e50))
* treat a symlink notified marker as not a prior whistle ([3ab26c2](https://github.com/orwa-mahmoud/nightshift/commit/3ab26c2a5da13a1834d040c0d63480913a08dcde))
* treat a symlink session-end as not a clean exit ([5bf1d79](https://github.com/orwa-mahmoud/nightshift/commit/5bf1d7966329ee8e0863e4423f6f1fc56baa1aa7))
* treat a symlink shift-session as not a recorded session ([5ab3e26](https://github.com/orwa-mahmoud/nightshift/commit/5ab3e26a0c1f11dfb59392019db753da7ac5f128))
* treat a symlink stall as not a stall count ([a613f8b](https://github.com/orwa-mahmoud/nightshift/commit/a613f8bdfb565b342446eebbb71b2b28a003e426))
* treat a symlink watchman pidfile as not a live owner ([66edf0d](https://github.com/orwa-mahmoud/nightshift/commit/66edf0d30e6be44803468640657c60ed4e7ee0d1))
* treat a symlink work-mode file as malformed ([5123fbb](https://github.com/orwa-mahmoud/nightshift/commit/5123fbbf87bbacc4b0f2e18d0acfa54f76bceb0b))
* treat a symlink work-target file as unreadable ([c43172e](https://github.com/orwa-mahmoud/nightshift/commit/c43172e7a16fdb15b27b441cd48f3759e8596143))
* unblock bats pins and Windows CI parse/bind failures ([aea6465](https://github.com/orwa-mahmoud/nightshift/commit/aea64656bc7b6d9320a21f988bc48861843a77d6))
* warn on empty punch list in Windows schedule generate ([3357fce](https://github.com/orwa-mahmoud/nightshift/commit/3357fce8e8d962a6efacc581ebe851195a4f3a76))
* warn when the artifact receipts path is unusable ([8d3b469](https://github.com/orwa-mahmoud/nightshift/commit/8d3b46943b10950131ccc42a2fa7c79dad387ba6))
* Windows setup refuses a notes folder before scaffolding ([bd7511f](https://github.com/orwa-mahmoud/nightshift/commit/bd7511f4d0850d02ca8e3a0164a0b93f3cf1171f))
* Windows setup refuses default repository on a notes folder ([519e0c3](https://github.com/orwa-mahmoud/nightshift/commit/519e0c3dbf7381d6da3dbd95076ee2539d7fefa3))
* write Hunt and Start deadlines as UNIX epochs ([f54643d](https://github.com/orwa-mahmoud/nightshift/commit/f54643d0371492e09ab928093eb0cdb9b06db4c9))

## [0.14.5](https://github.com/orwa-mahmoud/nightshift/compare/v0.14.4...v0.14.5) (2026-08-26)


### Bug Fixes

* **hooks:** classify the session host from its transcript path ([07f52e4](https://github.com/orwa-mahmoud/nightshift/commit/07f52e493a0c681952cc01511ac7653be655fe67))

## [0.14.4](https://github.com/orwa-mahmoud/nightshift/compare/v0.14.3...v0.14.4) (2026-08-23)


### Bug Fixes

* clarify persistent workspace guidance ([629e3b3](https://github.com/orwa-mahmoud/nightshift/commit/629e3b32d873322903de665079b5ee17d2eca0b9))

## [0.14.3](https://github.com/orwa-mahmoud/nightshift/compare/v0.14.2...v0.14.3) (2026-08-19)


### Bug Fixes

* stop treating the process-lease id as a secret ([6eb196d](https://github.com/orwa-mahmoud/nightshift/commit/6eb196df2d814ecff2da0b2333672158c5d68c15))

## [0.14.2](https://github.com/orwa-mahmoud/nightshift/compare/v0.14.1...v0.14.2) (2026-08-19)


### Bug Fixes

* qualify Nightshift paths and pair native Windows helpers ([7232b3d](https://github.com/orwa-mahmoud/nightshift/commit/7232b3db49987eef200bb40e4c1e9887c336ba66))

## [0.14.1](https://github.com/orwa-mahmoud/nightshift/compare/v0.14.0...v0.14.1) (2026-08-18)


### Bug Fixes

* **hardhat:** check Git paths for protectedDirs ([f1f3d26](https://github.com/orwa-mahmoud/nightshift/commit/f1f3d2675104aa896ac19693cdc40dfc6898c5df))
* **hardhat:** inspect the commit Git would write ([a84c225](https://github.com/orwa-mahmoud/nightshift/commit/a84c2257afb5ae0b02f52564dbf5258ccfdb8636))
* **hardhat:** protect armed-shift control files ([bc2e047](https://github.com/orwa-mahmoud/nightshift/commit/bc2e04712c536625d0dc17b20027f9e159a402e9))

## [0.14.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.13.1...v0.14.0) (2026-08-18)


### Features

* **compatibility:** verify remote development environments ([4051f7c](https://github.com/orwa-mahmoud/nightshift/commit/4051f7cd579f0ab25a1e645b8ab4432b6ed9b7f6))
* **recovery:** fence concurrent shift processes ([3efbac8](https://github.com/orwa-mahmoud/nightshift/commit/3efbac87f0f25a3d66e8339f405fb39f9b0eab65))
* **windows:** add native runtime support ([7d80a66](https://github.com/orwa-mahmoud/nightshift/commit/7d80a664ece3592910699b28b233968d9c1f829e))


### Bug Fixes

* share shift ownership and close review gaps ([e3643e9](https://github.com/orwa-mahmoud/nightshift/commit/e3643e9730013dd4dfc026cd53adf1c1885c0290))
* **skills:** align host roots and shift lifecycle ([46287d1](https://github.com/orwa-mahmoud/nightshift/commit/46287d1ccc3b1ebfb337440c362d82ce5ab3978c))

## [0.13.1](https://github.com/orwa-mahmoud/nightshift/compare/v0.13.0...v0.13.1) (2026-08-15)


### Bug Fixes

* preserve the directory subtitle in uploads ([c230e7d](https://github.com/orwa-mahmoud/nightshift/commit/c230e7d9c0eacb98041bca47ddd551363e158f7e))

## [0.13.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.12.0...v0.13.0) (2026-08-15)


### Features

* **shifts:** add custom timed owner walkthroughs ([4e484ed](https://github.com/orwa-mahmoud/nightshift/commit/4e484edc8ac5e4bdc88aaa7a04baa25cae1ffcf8))

## [0.12.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.11.0...v0.12.0) (2026-08-14)


### Features

* **archive:** add explicit history retention ([1e4cc4f](https://github.com/orwa-mahmoud/nightshift/commit/1e4cc4fa2c6647a1cc56935e49cef2fbb7b6f92b))
* **catalog:** add GitHub issue hunts ([c2257d7](https://github.com/orwa-mahmoud/nightshift/commit/c2257d72a94c330673cc8ab3472e1f5e3c35784a))
* **doctor:** export redacted support bundles ([f63deb8](https://github.com/orwa-mahmoud/nightshift/commit/f63deb84eb144a8fc5ea4378ef236f65bc4a3539))
* **github:** stage selected issues for shifts ([c182ef2](https://github.com/orwa-mahmoud/nightshift/commit/c182ef2cb8d9b2f07d12d6193e3266876c5d29b0))
* **rules:** add opt-in local profiles ([d2ddbe7](https://github.com/orwa-mahmoud/nightshift/commit/d2ddbe7ba9edd6cb57fec4e52c9777b9f1a222aa))
* **schedule:** generate systemd user timers ([7c6a010](https://github.com/orwa-mahmoud/nightshift/commit/7c6a010f74d2d522bad1e93006e4c24519c45def))
* **state:** version Nightshift workspaces ([45cfeb9](https://github.com/orwa-mahmoud/nightshift/commit/45cfeb98a4dab19ca0054e65c6ea7f55d1c8e316))


### Bug Fixes

* **ci:** align Linux portability checks ([9162265](https://github.com/orwa-mahmoud/nightshift/commit/9162265736f3117e0fa0381b433a33122fb4de22))
* **ci:** harden Linux runtime portability ([2c47003](https://github.com/orwa-mahmoud/nightshift/commit/2c470031c03c1c73a8039e802aefbc72d592db18))
* **github:** roll back partial queue promotion ([f090099](https://github.com/orwa-mahmoud/nightshift/commit/f090099425a10b87dbafe391a9c1f0fb60fc71b1))
* **recovery:** support minimal process environments ([4391c1f](https://github.com/orwa-mahmoud/nightshift/commit/4391c1f773ba35769ade9d89c131651aa5cda4e2))

## [0.11.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.10.0...v0.11.0) (2026-08-14)


### Features

* **catalog:** add accessibility repair shift ([aa1c0e4](https://github.com/orwa-mahmoud/nightshift/commit/aa1c0e454339cddf0e620e978087e4112a39900a))
* **catalog:** add API contract drift shift ([8c12b05](https://github.com/orwa-mahmoud/nightshift/commit/8c12b0545bbb3491b9e66ffc2965d62dda212fd4))
* **catalog:** add dead-code cleanup shift ([410bd66](https://github.com/orwa-mahmoud/nightshift/commit/410bd66e6dce250e93ff04012b9c37d9a9326c34))
* **catalog:** add flaky-test repair shift ([f289d53](https://github.com/orwa-mahmoud/nightshift/commit/f289d5332b0999e2c1b11a05dc1c08fd5735296e))
* **catalog:** add localization parity shift ([323d21f](https://github.com/orwa-mahmoud/nightshift/commit/323d21fff370902a838425e7c9ed8968bf6fc79c))
* **catalog:** add TODO debt shift ([593ea7b](https://github.com/orwa-mahmoud/nightshift/commit/593ea7bd380ffafeb5ef03b8a8f508147cf70049))
* **shifts:** add guided and automatic execution modes ([52946d1](https://github.com/orwa-mahmoud/nightshift/commit/52946d1d946774cf149294cca173c0ffea4584c5))

## [0.10.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.9.4...v0.10.0) (2026-08-14)


### Features

* **catalog:** add a CI warning cleanup shift ([c26b6b0](https://github.com/orwa-mahmoud/nightshift/commit/c26b6b0821fadaf8c4c1371d34a37cef389192b8))
* **catalog:** add a documentation drift shift ([3ae803b](https://github.com/orwa-mahmoud/nightshift/commit/3ae803b4e79ff95ff6b608ba15bd26268abbb4a6))
* **community:** add a catalog shift proposal form ([ce24c61](https://github.com/orwa-mahmoud/nightshift/commit/ce24c61e03491fc6459388a09da89601167ccc24))
* **community:** add a safe failed-shift report form ([20681e1](https://github.com/orwa-mahmoud/nightshift/commit/20681e12596355a78f524e70c8218a4018e3d529))
* **config:** add a schema for Nightshift rules ([0b22de5](https://github.com/orwa-mahmoud/nightshift/commit/0b22de58d636a54cd78c190a7289486f2e4cb81a))
* **diagnostics:** add a read-only Nightshift Doctor ([28c22eb](https://github.com/orwa-mahmoud/nightshift/commit/28c22eb075aea62e2dcc1b63fb4ea7f00ae1f66a))
* harden Nightshift diagnostics and cross-host reliability ([#92](https://github.com/orwa-mahmoud/nightshift/issues/92)) ([08e3263](https://github.com/orwa-mahmoud/nightshift/commit/08e32636f3843ee6116f37f668837ea4f20a2fa1))
* **recovery:** expose reason-coded watchman outcomes ([16bc18d](https://github.com/orwa-mahmoud/nightshift/commit/16bc18d5f36567aa2b47e4e4b79220df4505f71a))
* **schedule:** add a no-install preflight check ([e0f3b83](https://github.com/orwa-mahmoud/nightshift/commit/e0f3b8300d53f6500b53b5dc27b57e00171a1fb8))


### Bug Fixes

* **codex:** reject non-resumable session identities ([1227a01](https://github.com/orwa-mahmoud/nightshift/commit/1227a01b6f6275f8ef72dc1016637a296510ead3))
* **runtime:** close shift review gaps ([e530363](https://github.com/orwa-mahmoud/nightshift/commit/e530363e0d5e1bf39224ae4fb37288998190222b))

## [0.9.4](https://github.com/orwa-mahmoud/nightshift/compare/v0.9.3...v0.9.4) (2026-08-13)


### Bug Fixes

* **codex:** park native user questions during shifts ([a058e36](https://github.com/orwa-mahmoud/nightshift/commit/a058e369f849fef7f23223646ded38cdfdea0f1c))
* **codex:** park native user questions during shifts ([#58](https://github.com/orwa-mahmoud/nightshift/issues/58)) ([a39626e](https://github.com/orwa-mahmoud/nightshift/commit/a39626e1eee5433749492f9b7e64fa4c8086e32d))

## [0.9.3](https://github.com/orwa-mahmoud/nightshift/compare/v0.9.2...v0.9.3) (2026-08-12)


### Bug Fixes

* **state:** align remaining active-shift checks ([7108184](https://github.com/orwa-mahmoud/nightshift/commit/7108184233697097c4f70eabfbfc3999e0dcc593))
* **workspace:** link tasks to authoritative shift state ([a3a1992](https://github.com/orwa-mahmoud/nightshift/commit/a3a19927bd7fd53371a653df8594d670d31e5423))
* **workspace:** reject ambiguous link files ([13235d6](https://github.com/orwa-mahmoud/nightshift/commit/13235d6a219ea1b4d373f9b43277c02a070d0b04))

## [0.9.2](https://github.com/orwa-mahmoud/nightshift/compare/v0.9.1...v0.9.2) (2026-08-12)


### Bug Fixes

* harden Nightshift across Claude Code and Codex ([#53](https://github.com/orwa-mahmoud/nightshift/issues/53)) ([2ebfce5](https://github.com/orwa-mahmoud/nightshift/commit/2ebfce5ceaa2b3daf7f803e2c49a9887b4762ebb))
* **hardhat:** align active-shift detection across hosts ([0374ac8](https://github.com/orwa-mahmoud/nightshift/commit/0374ac876fb66706da67fa33cd1622ce76f9f67c))
* **schedule:** safely encode generated cron and launchd paths ([e713d3c](https://github.com/orwa-mahmoud/nightshift/commit/e713d3c1ee8a696d4a7b8ebfaba46410ec433e55))
* **session:** always record the Claude host in shift identity ([bdfb0aa](https://github.com/orwa-mahmoud/nightshift/commit/bdfb0aaad57369e9f2eceb9be17efef31da0f0af))
* **setup:** resolve a single repository inside parent workspaces ([20424b1](https://github.com/orwa-mahmoud/nightshift/commit/20424b1432bc55f2e06be75d2c4a4cfbedacb031))
* **skills:** clarify state-file roles across model workflows ([6ef7014](https://github.com/orwa-mahmoud/nightshift/commit/6ef701409774d2dc4eff5c3186fa6f785b875f55))
* **test:** measure coverage from current plugin paths ([0a3e6f7](https://github.com/orwa-mahmoud/nightshift/commit/0a3e6f7742ebf1a1342b75e47a1b9b5063a891e1))

## [0.9.1](https://github.com/orwa-mahmoud/nightshift/compare/v0.9.0...v0.9.1) (2026-08-12)


### Bug Fixes

* redirect temporary ChatGPT workspaces ([809c906](https://github.com/orwa-mahmoud/nightshift/commit/809c9066288a5f2d5c397d05d88e27c3fce20970))

## [0.9.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.8.1...v0.9.0) (2026-08-12)


### Features

* add evidence-backed product evolution to the ready-made hunt catalog
* preserve active opportunity progress across compaction and resumed sessions
* integrate product research and opportunity tracking with setup, status, and archive
* make Codex a first-class host alongside Claude Code ([7f62a2d](https://github.com/orwa-mahmoud/nightshift/commit/7f62a2dd1e59f1653b363191c1d9d7d3afad3a12))

## [0.8.1](https://github.com/orwa-mahmoud/nightshift/compare/v0.8.0...v0.8.1) (2026-08-05)


### Bug Fixes

* Codex packaging and host wording catch up to the release ([a1ab3a1](https://github.com/orwa-mahmoud/nightshift/commit/a1ab3a1fb5063c86051f13641d2d5ac9ab1afa93))

## [0.8.0](https://github.com/orwa-mahmoud/nightshift/compare/v0.7.4...v0.8.0) (2026-08-05)

nightshift runs on OpenAI Codex. One package, a manifest per host, and the same night either
way — the gate, the guards, the skills, the scheduler, and the watchman.

### Features

* the Codex clock-out gate and hardhat enforce the same shift — Claude's decisions behind Codex's own hook wiring, verified in a live session ([2bac060](https://github.com/orwa-mahmoud/nightshift/commit/2bac06066a4a72b2a6ce13e7ab1e89935ab77450))
* the night watchman works Codex shifts — a killed session is revived into its own conversation and the list is finished with nobody attached, verified with a live SIGKILL mid-shift ([fc3510f](https://github.com/orwa-mahmoud/nightshift/commit/fc3510f2b0ae6437763bb70467f327237b9852cb))
* the shift record names its host, so each watchman minds only its own shifts ([19d619f](https://github.com/orwa-mahmoud/nightshift/commit/19d619f18f451cd57e90b39d2ef9c9ee637d7f47))
* the skills speak both hosts — permissions, liveness and the watchman step fork per host, and the schedule generator takes `--agent` so one entry serves either runner ([349bfed](https://github.com/orwa-mahmoud/nightshift/commit/349bfedc775aab94364f92136de75f357428f7e6))
* Codex install is advertised: the `.agents` marketplace entry and the README's `codex plugin` commands ([e52c18a](https://github.com/orwa-mahmoud/nightshift/commit/e52c18a29b1238f4562eda3ea121bd8cdc2ce598))

Unattended Codex runs that commit use the `danger-full-access` sandbox — `workspace-write`
blocks `git commit`. nightshift's guards hold in every mode. A Codex session alive at an API
error is stood by, not revived.

## v0.7.4 — the plugin is a subdirectory

The plugin ships from `plugin/`. Tests, CI workflows and the README's screenshots no longer
install with it: an install is 216 KB, down from 876 KB.

## v0.7.3 — a shift is a file

Catalog entries live one per file in `skills/nightshift/references/shifts/`, and
`/nightshift:hunt` lists that directory rather than reading a single page. Adding a shift is two
new files — the entry and its test — with no edit to anything shared, so two people can contribute
one the same week without meeting in a diff. The structural rules glob the directory, so a new
entry is checked the moment it lands: its title declares its ending, and it carries a pasteable
item, a Verify line and a stated ending condition.

Two entries join the catalog, both finite, both working from a list the project's own tooling
produces:

- **Dependency upgrade sweep** — direct dependencies brought current one at a time, patches before
  majors, each behind the item gate and its own commit. The release notes are the work: a version
  bump that compiles is not an upgrade. A major that sprawls past a bounded attempt is reverted
  clean and parked, because a half-migrated major leaves the tree worse than the old version did.
  Prereleases are refused, and the lockfile, the package manager and the runtime version are the
  owner's.
- **Vulnerability sweep** — advisories cleared critical-first, so an interrupted night cleared what
  mattered. It never downgrades to satisfy an advisory and never adds a suppression: where the only
  offered fix is an older version, or the advisory sits in a transitive dependency, it parks the
  decision with the link and the severity.

## v0.7.2 — a shift starts when you start it

`/nightshift:start` is what puts a session on shift. It writes `.nightshift/.shift-armed`, and
until that marker exists the punch list is an ordinary to-do file — the clock-out gate holds
nobody, hardhat's guards apply to no one, and a session that writes items while planning still
stops freely. Every way in already runs start: interactively, from the scheduler's
`claude -p '/nightshift:start'`, and through a revival that re-claims the record it left behind.

- **The gate binds the session start hands it.** The hooks read the shift record; they no longer
  create one, so the shift is never inherited by whichever session happens to trip a hook first.
  Ending a shift disarms the site, so the guards leave with the night that needed them.
- **Boxes count under the `## Items` heading only.** A checkbox anywhere above it is contract
  prose — an owner's note, an example — and holds nothing. The watchman counts the same range as
  the gate, so the two can't disagree about whether work remains.
- **The contract names the Items list without repeating its heading**, leaving one `## Items` in
  the file for anything that splits on it.
- **Every path that starts a shift arms it** — `/nightshift:hunt` answering *now* and
  `/nightshift:quality` answering *fix now* both begin the shift where they stand, so both write
  the marker. A stop-work order disarms the site whether or not a list survived to summarise.
- **`/nightshift:status` says whether a shift is running**, rather than leaving open boxes to imply
  it, and counts the same range the gate does.
- Fifteen tests cover the arming boundary from both sides.

## v0.7.1 — the site is where the owner put it

Every skill resolves `.nightshift/` and `.claude/` against `$CLAUDE_PROJECT_DIR`, so the site stays
the site no matter where a shell has wandered. The working directory persists between commands and
follows gates, builds, and stack detection into the code repo; on the recommended layout — the code
repo a level below the project root — anything written relative to it lands in the repo instead of
the site.

- **Permissions reach the project.** `/nightshift:setup` writes
  `$CLAUDE_PROJECT_DIR/.claude/settings.local.json`, the file a headless revival inherits. A copy
  anywhere else grants the project nothing, and the night finds out at its first prompt.
- **Scaffolding, rules, gates, and the receipts repo are placed by path, not by proximity.** The
  receipts repo is created with `git -C`, since `git init` follows the working directory too.
- Six tests hold the rule across every skill, including ones not written yet.

## v0.7.0 — one place composes work, one place starts it

`/nightshift:start` asks nothing. Everything it needs was decided when the work was composed, so
the same command serves an interactive start, a headless revival, and a scheduled one. That single
property is what makes an unattended night schedulable at all, and it is why the ready shifts
moved: a command that prompts cannot run while its owner sleeps.

- **`/nightshift:hunt` composes the shift.** It offers the whole catalog rather than three fixed
  presets, takes more than one entry per night, asks for hours only where the ending needs them,
  and takes one free-text answer for scope — *"only `packages/api/`"*, *"use the in-memory test
  harness"* — added as its own bullet beneath the entry's contract, never in place of it. The
  assembled shift is shown exactly as it will be written before anything is armed, and answering
  *now* starts it there — no second command to type.
- **`/nightshift:quality` closes the same way.** After the read-only scan it offers three answers:
  **fix now**, which writes the items and starts the shift; **draft for later**, which stages them
  on the drafting table and arms nothing; or **ignore**. The punch list is written on nothing but
  an explicit *fix now* — an open box arms the gate for the current session, so the box and the
  start belong together or neither happens.
- **`/nightshift:start` executes what it finds.** With open items in the punch list it asks
  nothing and promotes nothing — parked orders and drafts stay where the owner left them, and the
  list is the shift exactly as written. Only when the punch list is empty does it speak: it shows
  what is parked and asks which to work. A cut is a move, never a copy, so an item never exists in
  two files. The deadline is read rather than requested, a spent one is swept as a leftover while
  one still in the future survives as tonight's plan, and an open-ended walkthrough with no clock
  is refused rather than started.
- **The shift catalog is the contribution surface.** `shift-catalog.md` gains a finite entry,
  *clear quality debt*, beside the three open-ended hunts, and `catalog-recipe.md` states what a
  new entry must declare: its ending, how it discovers work, its definition of done, what it will
  never do, its verification, and the stacks it supports. Entries are markdown; they touch no
  hooks, so the catalog can grow without the product growing.
- **`/nightshift:schedule` — the scheduler nightshift will not become.** It checks what an owner
  would otherwise discover at 4am — that work is actually queued in the punch list, that headless
  permissions will not stall the run, that nothing is registered twice — then prints the launchd
  plist or crontab line for the project and the single command that installs it. It registers
  nothing itself, because waiting for a clock stays the operating system's job: a process that
  sleeps for hours dies to a closed lid.
  Underneath it, `adapters/schedule.sh` is plain shell that spends no model tokens and needs no
  session. That is not an implementation detail — the moment an owner most wants to schedule a run
  is the moment their quota is gone, and a slash command is read by the model. The README documents
  the script directly for exactly that day. It refuses a second entry where one exists (two
  scheduled starts on one punch list is two agents on one shift), identifies a project by path
  rather than folder name so two checkouts named `api` never collide, and says plainly that a
  sleeping machine runs nothing.
- **foreman is removed.** It existed because Claude Code was once the only agent with hooks; Cursor,
  Codex and Kimi now ship lifecycle hooks of their own, so a generic outer loop is the weakest
  possible way to serve any of them. nightshift extends Claude Code through Claude Code's own
  extension points, and the README and CONTRIBUTING now say so as a scope rule: no schedulers, no
  dashboards, no second install channel.

## v0.6.1 — one copy

The rules file is the config, and it lives with everything else nightshift owns:
`.nightshift/rules.json`, copied as-is from the shipped template by setup, read by the hooks
directly on every tool call — an owner's edit applies from the very next action, nothing is
synced into settings, nothing needs a restart, and deleting `.nightshift/` removes all of
nightshift, rules included. Env vars of the matching names remain session-start overrides —
the test suite's lever and the one-off exception, never a copy to maintain.

- **The night never touches its own leash.** During a shift, the working session is denied
  the rules file — file tools and shell commands alike, the same pattern-match honesty as
  every guard here. A rule that must change mid-shift changes by the owner's hand and reads
  from the next tool call.
- **Setup migrates and cleans.** A pre-0.6.1 `.claude/nightshift-rules.json` is moved into
  `.nightshift/` (the hooks read the old home as a fallback until then), and setup offers to
  strip the `NIGHTSHIFT_*` env keys an earlier version synced. The receipts-repo question is
  asked neutrally: its default is no, and it is never presented as recommended.
- **The watchman reads its own cadence** (`watchMinutes`, `watchRetrySeconds`,
  `notifyCommand`, both revival orders) from the rules file at arm time; start no longer
  passes an interval.
- **No hidden defaults.** Every shipped value — both revival orders, the clock-out
  reinjection, the park message, the cadences — lives visibly in the template setup copies;
  the hooks carry no fallback copies. A missing or unreadable rules file fails loudly and
  closed: the gate still blocks, questions stay parked, the watchman refuses to arm — each
  naming the repair.

## v0.6.0 — the 500 night, start to finish

Start a shift, watch the very first call come back `API Error: 500`, and go to sleep anyway:
the watchman now carries that night from the first error to the morning receipts, and the
whole story — the 500, the revival, the finished work — is one conversation you open with
one click.

- **The wedge is the transcript's last word, read structurally.** Claude Code records an API
  failure as its own synthetic event, flagged `isApiErrorMessage:true`; the watchman requires
  that flag on the last conversation event before calling a live-but-quiet session wedged. An
  owner pasting an error report as a prompt, or an error the session already retried past, no
  longer reads as a wedge — if anything followed the error, somebody was there, and that
  session is not the watchman's to touch. The owner's Esc is read by the same rule: an
  interrupt is a pause only as the last conversation event — one the owner already resumed
  past is history, and a real death after that resume reads as death.
- **A 500 before first work is still the wedge.** The shift records its identity at the first
  tool call — but an outage can land before any tool runs, leaving no record. A project whose
  newest conversation ends in the host's error event now revives via `--continue`, which
  resumes that very conversation, instead of standing by all night behind "a live claude
  session in the project".
- **Session-first, and only the session.** The verdict reads the session's own signals in
  order — the owner's Esc above all, the shift's transcript, the recorded process, then the
  host's registry: `claude agents --json` listing the recorded id is the host saying alive
  (it even rescues a stale pid), and a clean roster without it is death evidence no folder
  churn can drown out. Project files never vote — a detached loop, a build, or a sync can
  neither mute the owner's Esc nor mask a dead session as alive.
- **Revival orders match what the session knows.** A resumed conversation carries its own
  context, so its order is one line: cut off, continue — the contract already lives in the
  thread, and the gate enforces the ending. The fresh-session fallback starts empty and gets
  the full pointer at the punch list. Both texts are the owner's (`revivalPrompt`,
  `freshRevivalPrompt`).
- **The morning is one click away.** A successful revival leaves a notice in
  `parking-lot.md` — the file the owner reads — with the thread's handles: `claude --resume
  <id>` for the terminal, the `cursor://` and `vscode://` deep links for the IDE panel. The
  first thing you open is the exact conversation: the error, the revival, and everything it
  finished. The one night event that needs the owner — a dead session no attempt could bring
  back — rings the morning whistle instead, once per outage.
- **Tighter cadence.** The watch interval defaults to 10 minutes (`NIGHTSHIFT_WATCH=N` still
  sets it), and a dead API never stretches the rhythm: three tries per wake, every wake,
  until the API answers.
- **The night cannot click Allow.** Setup now asks to enable `bypassPermissions` in the
  project's settings (recommended; written to `.claude/settings.local.json` so revivals
  inherit it), start warns once when no frictionless grant exists, and the README says the
  trade plainly. nightshift's guards are hooks and stay armed in every permission mode.
- **One rules file, every decision the owner's.** Setup copies a ready template to
  `.claude/nightshift-rules.json` and syncs it into the env block — clean JSON to edit, the
  escaping machine-written. It carries the per-tool denial map (`toolDeny`: your message
  per tool, an empty message lifts a rule, absent keys keep the defaults), every guard
  pattern, the stall cap and warning cadence, the watch cadence, the morning whistle, the
  watchman's revival orders, and the gate's clock-out reinjection. The env stays the enforcement surface, fixed at session start — the file is the
  owner's editor, never the agent's lever — and start warns when the file drifts from the
  running session's rules. Re-running setup after an update offers what the new template added
  — missing keys, a changed contract — and never touches the owner's words.
- **The receipts repo is opt-in.** A git repo living inside the project is not everyone's
  taste: setup now asks before `git init`-ing `.nightshift/`, and the default is no — the
  receipts remain as plain files, and the gate's snapshot commit is a no-op without the repo.
- **`/nightshift:archive` — the finished part becomes a dated record.** Ticked items move into
  `archive/<date>/shipped.md`, the journal rotates whole, snags and parked questions move only
  once they carry the owner's answer. The live files stay lean; what shipped stays on disk as
  plain dated facts. Start auto-rotates a journal past ~500 KB into the same archive.
- **The shift binds one session.** The gate holds, and the site rules govern, the recorded
  shift session alone — a second conversation in the same project chats, stops, and asks
  freely; the night is not its business unless the owner brings it. A watchman revival stays
  bound under whatever id the fallback chain gave it and re-claims the record, so the watchman
  follows the living thread. Start refuses to start a second agent beside a living one — it
  hands the owner the running thread's `claude --resume` and IDE deep link instead.
- **One writer per site.** Two sessions stopping at once could tear the stall counter, double
  the morning whistle, or collide in the receipts repo. The gate's decision tail now runs
  under a per-site lock (mkdir-based — every platform has it; a dead holder's lock is broken
  on sight, a live one is waited on, bounded), and the whistle marker is claimed with an
  exclusive create. The wait can never hang a session: an unlockable site is decided unlocked.

## v0.5.2 — strong evidence of death

The one truly harmful watchman failure is spawning a second agent beside a living one: a resumed
id APPENDS to the same session, so two writers interleave into one conversation while sharing a
working tree. v0.5.0 read liveness from project files alone — long reasoning, research, or a
25-minute test run writes none and looked dead. Revival now requires strong positive evidence of
death, never "looks stuck".

- **Liveness is a ladder.** The shift's transcript is the primary pulse — a live session streams
  every turn into it, project files or not. Project activity stays as the second rung. Then the
  process witness: the hooks record the claude ancestor's pid and start time alongside the
  session id, and the watchman checks that exact process — `kill -0` plus the start time, a pair
  no pid reuse can counterfeit. Alive with a quiet, unerrored transcript is long silent work:
  stand by. Dead is dead even while other tabs live in the project: revive. No pid recorded
  degrades to the conservative reading — any claude process working in the project stands the
  watchman by.
- **The 500 wedge is recognized, not guessed.** Claude Code writes API failures verbatim into
  the transcript ("API Error: 500 …", "529 Overloaded"). A live shift process whose quiet
  transcript ends in one is a session sitting at an errored prompt with nobody there to press
  retry — the night the watchman exists for. That combination revives; prose merely mentioning
  API errors does not match.
- **Every retry re-checks the whole ladder first.** A site that comes back to life mid-wake — or
  an owner who acts — cancels the remaining attempts. Each failed attempt re-baselines the
  sentinel, so the watchman's own error events in the transcript never read as site life.
- **The revival chain is real and logged per rung**: the recorded conversation first, `claude
  --continue` next, a fresh `claude -p` last — the morning log says exactly which recovery level
  carried the night.
- **The identity claim is atomic.** `.shift-session` is taken with an exclusive create — two
  racing first sessions cannot interleave; one record lands whole.
- **A revival's own exit is not the owner's hand on the door.** Spawned sessions carry a mark,
  and the `SessionEnd` hook stays inert for them — without it, the worker finishing (or dying on
  the API again) would write the clean-end marker under the recorded id and stand the watchman
  down mid-outage after the first revival.

## v0.5.1 — the shift knows its own session

Live dogfooding with two tabs in one project exposed the guess in v0.5.0: the watchman read "the
newest transcript" for the Esc tell and revived with `--continue`, and with a second session in
the project both could point at the wrong conversation.

- **The shift records its own identity.** Every hook receives the session id and transcript path;
  the first session to work under an active shift writes them to `.nightshift/.shift-session`,
  once. A second tab never overwrites the record.
- **The Esc tell reads the shift's own transcript** — a helper tab's interrupt proves nothing and
  is ignored. No record yet falls back to the newest transcript in the project.
- **The revival is `claude --resume <that id> -p`** — the shift's exact conversation, with
  everything it knew before the crash: hours of context, decisions, where it stood mid-item. No
  record yet means `--continue`, and the last retry of a wake still falls back to a fresh
  session.
- **The clean-exit marker is the shift's alone** — `SessionEnd` writes it only when the ending
  session matches the record, so closing an unrelated tab in the same project no longer stands
  the watchman down.
- `start` and the hunt cut clear the record with the other markers; setup gitignores it in the
  receipts repo.

## v0.5.0 — the night watchman

A Stop hook can only act inside a living session. A session killed by an API outage, a crash, or
a closed terminal fires no hooks — the punch list survived on disk, but nothing re-invoked the
agent, and the night was lost. The watchman is the outside half.

### The watchman

- `adapters/watchman.sh`, armed in the background by `/nightshift:start` and the hunt cut. It
  wakes every 20 minutes (`NIGHTSHIFT_WATCH=N` minutes; `0` disarms) and, only when boxes are
  open **and** nothing in the project has changed since the last wake, sends the conversation
  back to work.
- It stands down at every honest ending: a stop-work order, an ended shift, every box ticked, a
  spent deadline, or a clean session exit. A crash at the finish line still gets its clock-out —
  all-ticked-but-never-released and dead-past-deadline each spawn one closing run, so receipts
  and the morning whistle happen even when the session died first.
- An API outage costs a handful of logged attempts, not one per tick: 2–3 spawn tries per wake
  spaced ~30s/2m, then the interval backs off, doubling per failed wake up to 8×.
- One watchman per site (a pid file; a stale one is taken over). **Esc still means stop**:
  Claude Code records a user interrupt in the session transcript and a 500 or a crash never
  does — that is the tell. At a quiet wake the watchman reads the transcript tail: interrupt
  there, it stands by; none, it revives. Unreadable defaults to reviving — waking a paused
  session costs an apology, a lost night costs the night.
- The revival is `claude --continue -p` by default — it chains onto the **same conversation**,
  so the morning transcript is one unbroken thread in the terminal and the IDE extension alike.
  On the default agent, the last retry of a wake falls back to a fresh `claude -p`: if the
  transcript itself is what broke, `--continue` would fail every wake forever, and the punch
  list on disk is enough for a fresh session to carry on. `NIGHTSHIFT_WATCH_AGENT` overrides
  the command entirely.

### Hooks

- A `SessionEnd` hook writes `.nightshift/.session-end` when a session ends **cleanly** during an
  active shift. Crashes and kills never reach the hook — which is the tell: marker means the
  owner's hand closed the session and the watchman stands down; no marker means it died and the
  watchman revives it. `start` and the hunt cut clear the marker, re-arming the night.

## v0.4.2 — overrides the guards can't read are denied

### Guards

- A commit that relocates itself with `--git-dir` or `--work-tree` is denied whenever a commit
  guard is configured. The guards resolve `git -C <dir>` and `cd <dir> &&`, but those two flags
  point the commit past that resolution — the guard would inspect one repository while the commit
  lands in another. Unverifiable means denied, exactly like the ambiguous-repo case.
- With an expected identity configured, a commit that overrides identity on the command line —
  `-c user.email=`, `--author`, or a `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL` prefix — is denied.
  The guard reads the repository's configuration, and with an override present that read
  describes nothing.
- The no-push recipe is now `git .*push`, so config injection (`git -c k=v push`) cannot slip
  between the words. Commit messages remain scrubbed first: a message *mentioning* a flag is not
  a use of it.

### Docs

- The fine print states what the gate re-injects: the full working standard, at every stop
  attempt, so it never decays out of context — alongside what it cannot prove.

## v0.4.1 — a page of its own

- `homepage` in both manifests points at <https://orwamahmoud.com/nightshift/>, which explains what
  the plugin does and what it deliberately does not. `repository` still points at the source, so the
  two fields no longer say the same thing.

## v0.4.0 — guards look where the commit lands

### Guards

- Commit guards inspect the repository a command names — `git -C <dir>`, `cd <dir> &&` — instead
  of the session's working directory, so a commit aimed at a sibling repo is checked where it
  lands. Where the target is genuinely ambiguous they deny rather than guess.
- The never-commit sweep widens from the index to the working tree against `HEAD` whenever a
  command stages implicitly. `git commit -a` and pathspec commits stage as they run, so the index
  alone never described them.
- Guards resolve correctly for projects under a dotted path. The child-skipping rule matched any
  hidden component anywhere in the path, which denied every commit in such a project.
- A stop-work order keeps the site rules armed. The agent works on until its next stop attempt,
  and the gate now writes `.nightshift/.ended` when it truly releases — that alone stands the
  rules down.
- An unparseable `NIGHTSHIFT_FORBIDDEN_COMMANDS` or `NIGHTSHIFT_NEVER_COMMIT_PATTERNS` is refused
  with a message instead of reading as "no match".
- `NIGHTSHIFT_PROTECTED_DIRS` matches whole path components, so `ai_docs` no longer condemns
  `ai_docs_public`, and only a commit message is blanked before matching — a forbidden command
  inside quotes is still seen.

### Shifts

- `/nightshift:start` and `/nightshift:hunt` clear the same five stale markers before anything
  writes a new deadline. A spent deadline used to end the next shift at its first stop attempt
  with nothing done; a leftover stop-work order made a hunt a no-op.
- `/nightshift:quality` puts accepted proposals on the drafting table. Writing them straight into
  the punch list armed the clock-out gate for every session in the project, including the one
  that ran the command.
- A commit in the repo below the project dir counts as progress, in the clock-out gate and in
  foreman alike — the recommended layout puts it there.
- Receipts commit with signing disabled, so a global `commit.gpgsign` cannot silently discard the
  night's record, and a failed receipts commit is logged rather than swallowed.
- `foreman.sh` rejects an option with no value instead of spinning forever on a `shift` that
  cannot move.

### Packaging and docs

- Slash commands live in `skills/`, the layout the plugin docs recommend. Invocation names are
  unchanged.
- Every guard is documented as shift-scoped, the stop-work order as landing at the next stop
  attempt, and the deadline as a whistle rather than an axe.
- Releases are tagged from the manifest version by CI, and a pull request that changes shipped
  files without bumping it fails.

## v0.3.0 — a stalled shift is held, never sent home

- A stalled shift is held and red-flagged by default instead of being clocked out; `NIGHTSHIFT_STALL_MAX=N`
  restores auto-clock-out, in the gate and the foreman loop alike.
- `/nightshift:hunt` stages the ready-made overnight jobs as work orders — the item and its hours
  park together, and the cut starts the clock.
- Hook and foreman hardening from a review pass, each finding with a test.

## v0.2.0 — nothing is blocked out of the box

- Nothing is blocked out of the box. Every safety rule became the owner's opt-in, replacing the
  built-in denials.
- `/nightshift:quality` added; the spot-check hook retired.
- CI validates the plugin and marketplace manifests on every push.

## v0.1.0 — the clock-out gate

- First release: the clock-out gate (Stop hook), hardhat (PreToolUse guard), park-don't-ask, the
  morning whistle, the nightshift skill, the punch-list/parking-lot/snag-log templates,
  stack-aware gates, `/nightshift:setup|start|status|stop`, and `adapters/foreman.sh` for other
  agent CLIs.
